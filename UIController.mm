//
//  UIController.mm
//  BokeCam
//
//  Implementation of the floating control panel.
//
//  Notes
//  -----
//  * The floating UI lives in its own UIWindow with a very high windowLevel
//    so it stays above the host application's UI.
//
//  * A UIWindow always covers the whole screen, therefore it would swallow
//    every touch of the host application. BokeCamOverlayWindow overrides
//    -hitTest:withEvent: so that only the floating button (and the panel
//    that is presented from our own window) receives touches, everything
//    else is passed through to the application underneath.
//
//  * PHPickerViewController is preferred over UIImagePickerController because
//    it needs no NSPhotoLibraryUsageDescription key and does not request full
//    library access. UIImagePickerController is kept as a fallback for older
//    systems.
//

#import "UIController.h"
#import "Tweak.h"

#import <objc/runtime.h>

static const CGFloat kBokeCamButtonSize = 56.0;
static const CGFloat kBokeCamButtonMargin = 16.0;

#pragma mark - Pass through window

// A window that only reacts to touches on its own content.
@interface BokeCamOverlayWindow : UIWindow
@property (nonatomic, strong, nullable) UIView *interactiveContentView;
@end

@implementation BokeCamOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];

    if (hit == nil) {
        return nil;
    }

    // Touches on the empty background must reach the host application.
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }

    // The floating button is always interactive.
    if (self.interactiveContentView != nil &&
        [hit isDescendantOfView:self.interactiveContentView]) {
        return hit;
    }

    // The panel (alert / picker) that is presented from our window stays
    // interactive as well.
    UIViewController *presented = self.rootViewController.presentedViewController;
    if (presented != nil && presented.view != nil &&
        [hit isDescendantOfView:presented.view]) {
        return hit;
    }

    return nil;
}

@end

#pragma mark - Controller

@implementation UIController {
    BokeCamOverlayWindow *_floatingWindow;
    UIButton *_floatingButton;
    UILongPressGestureRecognizer *_dragGesture;
    BOOL _isDragging;
    CGPoint _dragStartPoint;
}

#pragma mark - Singleton

+ (instancetype)sharedInstance {
    static UIController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[UIController alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(settingsChanged:)
                                                     name:kBokeCamSettingsChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Floating button

- (void)showFloatingButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_floatingWindow != nil) {
            // Already installed. Do not call -makeKeyAndVisible, that would
            // steal the key window from the host application.
            self->_floatingWindow.hidden = NO;
            return;
        }

        UIWindowScene *scene = [self activeWindowScene];
        if (scene != nil) {
            self->_floatingWindow = [[BokeCamOverlayWindow alloc] initWithWindowScene:scene];
        } else {
            self->_floatingWindow = [[BokeCamOverlayWindow alloc]
                                     initWithFrame:[UIScreen mainScreen].bounds];
        }

        self->_floatingWindow.windowLevel = UIWindowLevelAlert + 100.0;
        self->_floatingWindow.backgroundColor = [UIColor clearColor];
        self->_floatingWindow.userInteractionEnabled = YES;
        self->_floatingWindow.hidden = NO;

        UIViewController *rootController = [[UIViewController alloc] init];
        rootController.view.backgroundColor = [UIColor clearColor];
        self->_floatingWindow.rootViewController = rootController;

        [self buildFloatingButton];

        [self repositionFloatingButton];

        // Follow the screen when the device is rotated.
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(orientationChanged:)
                                                   name:UIDeviceOrientationDidChangeNotification
                                                 object:nil];
    });
}

- (void)hideFloatingButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_floatingWindow.hidden = YES;
        self->_floatingWindow = nil;
        self->_floatingButton = nil;
    });
}

- (void)buildFloatingButton {
    if (_floatingButton != nil) {
        return;
    }

    _floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _floatingButton.frame = CGRectMake(0, 0, kBokeCamButtonSize, kBokeCamButtonSize);
    _floatingButton.backgroundColor = [UIColor colorWithRed:0.11 green:0.62 blue:0.94 alpha:0.90];
    _floatingButton.layer.cornerRadius = kBokeCamButtonSize / 2.0;
    _floatingButton.layer.borderWidth = 2.0;
    _floatingButton.layer.borderColor = [UIColor whiteColor].CGColor;
    _floatingButton.layer.shadowColor = [UIColor blackColor].CGColor;
    _floatingButton.layer.shadowOpacity = 0.35;
    _floatingButton.layer.shadowRadius = 6.0;
    _floatingButton.layer.shadowOffset = CGSizeMake(0, 3);
    _floatingButton.clipsToBounds = NO;
    _floatingButton.accessibilityLabel = @"BokeCam";

    [_floatingButton setTitle:@"VC" forState:UIControlStateNormal];
    [_floatingButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _floatingButton.titleLabel.font = [UIFont boldSystemFontOfSize:20.0];

    [_floatingButton addTarget:self
                         action:@selector(openPanel)
               forControlEvents:UIControlEventTouchUpInside];

    // Drag support.
    _dragGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                   action:@selector(handleDrag:)];
    _dragGesture.minimumPressDuration = 0.35;
    [_floatingButton addGestureRecognizer:_dragGesture];

    [_floatingWindow addSubview:_floatingButton];
    _floatingWindow.interactiveContentView = _floatingButton;
}

- (void)repositionFloatingButton {
    if (_floatingButton == nil || _floatingWindow == nil) {
        return;
    }
    UIScreen *screen = _floatingWindow.screen ?: [UIScreen mainScreen];
    CGRect bounds = screen.bounds;

    CGFloat x = bounds.size.width - kBokeCamButtonSize - kBokeCamButtonMargin;
    CGFloat y = bounds.size.height * 0.35;

    _floatingButton.frame = CGRectMake(x, y, kBokeCamButtonSize, kBokeCamButtonSize);
}

- (void)orientationChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self repositionFloatingButton];
    });
}

#pragma mark - Dragging

- (void)handleDrag:(UILongPressGestureRecognizer *)gesture {
    if (_floatingButton == nil || _floatingWindow == nil) {
        return;
    }

    UIView *container = _floatingWindow;
    CGPoint point = [gesture locationInView:container];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            _isDragging = YES;
            _dragStartPoint = point;
            _floatingButton.transform = CGAffineTransformMakeScale(1.1, 1.1);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!_isDragging) {
                break;
            }
            CGPoint translation = CGPointMake(point.x - _dragStartPoint.x,
                                               point.y - _dragStartPoint.y);
            _floatingButton.center = CGPointMake(_floatingButton.center.x + translation.x,
                                                 _floatingButton.center.y + translation.y);
            _dragStartPoint = point;
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            _isDragging = NO;
            _floatingButton.transform = CGAffineTransformIdentity;
            [self clampFloatingButtonToScreen];
            break;
        }
        default:
            break;
    }
}

- (void)clampFloatingButtonToScreen {
    if (_floatingButton == nil || _floatingWindow == nil) {
        return;
    }
    UIScreen *screen = _floatingWindow.screen ?: [UIScreen mainScreen];
    CGRect bounds = screen.bounds;

    CGRect frame = _floatingButton.frame;
    frame.origin.x = MAX(kBokeCamButtonMargin,
                         MIN(frame.origin.x,
                             bounds.size.width - frame.size.width - kBokeCamButtonMargin));
    frame.origin.y = MAX(kBokeCamButtonMargin,
                         MIN(frame.origin.y,
                             bounds.size.height - frame.size.height - kBokeCamButtonMargin));
    _floatingButton.frame = frame;
}

#pragma mark - Panel

// The controller the panel is presented from. Our own window is preferred
// because it sits above the host application, so the panel is guaranteed to
// be visible.
- (UIViewController *)topViewController {
    if (_floatingWindow != nil && !_floatingWindow.hidden) {
        UIViewController *controller = _floatingWindow.rootViewController;
        while (controller.presentedViewController != nil) {
            controller = controller.presentedViewController;
        }
        return controller;
    }

    UIWindow *keyWindow = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }

    if (keyWindow == nil) {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window.windowLevel == UIWindowLevelNormal && !window.hidden) {
                keyWindow = window;
                break;
            }
        }
    }

    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

- (UIWindowScene *)activeWindowScene {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return windowScene;
            }
        }
        if (fallback == nil &&
            windowScene.activationState == UISceneActivationStateForegroundActive) {
            fallback = windowScene;
        }
    }
    return fallback;
}

- (void)openPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        BokeCamSettings *settings = [BokeCamSettings shared];
        [settings reloadFromDisk];

        UIViewController *presenter = [self topViewController];
        if (presenter == nil) {
            return;
        }

        NSString *statusText = settings.vcamEnabled ? @"ĐANG BẬT" : @"ĐANG TẮT";
        NSString *mediaText = @"Chưa chọn media";
        if ([settings hasUsableMedia]) {
            mediaText = (settings.mediaType == BokeCamMediaTypeVideo)
                ? [NSString stringWithFormat:@"Video: %@", settings.mediaFileName]
                : [NSString stringWithFormat:@"Ảnh: %@", settings.mediaFileName];
        }

        NSString *message = [NSString stringWithFormat:
                             @"Trạng thái: %@\n%@\n\nVCam hoạt động trên toàn hệ thống, "
                             @"mọi ứng dụng dùng camera đều bị thay thế.",
                             statusText, mediaText];

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"BokeCam — Virtual Camera"
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];

        // Toggle.
        NSString *toggleTitle = settings.vcamEnabled ? @"Tắt VCam" : @"Bật VCam";
        [alert addAction:[UIAlertAction actionWithTitle:toggleTitle
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            BokeCamSettings *current = [BokeCamSettings shared];
            [current reloadFromDisk];
            [current commitEnabled:!current.vcamEnabled];
            BokeCamInvalidateFrameSource();
        }]];

        // Pick an image.
        [alert addAction:[UIAlertAction actionWithTitle:@"Chọn ảnh (JPEG/PNG)"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [self presentMediaPickerWithType:@"public.image" allowsVideo:NO];
        }]];

        // Pick a video.
        [alert addAction:[UIAlertAction actionWithTitle:@"Chọn video (MP4)"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [self presentMediaPickerWithType:@"public.movie" allowsVideo:YES];
        }]];

        // Clear the current media.
        if ([settings hasUsableMedia]) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Xoá media đã chọn"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
                BokeCamSettings *current = [BokeCamSettings shared];
                [current commitMediaPath:nil fileName:nil type:BokeCamMediaTypeImage];
                BokeCamInvalidateFrameSource();
            }]];
        }

        [alert addAction:[UIAlertAction actionWithTitle:@"Đóng"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Media picker

- (void)presentMediaPickerWithType:(NSString *)typeIdentifier allowsVideo:(BOOL)allowsVideo {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = [self topViewController];
        if (presenter == nil) {
            return;
        }

        // PHPickerViewController is the modern, privacy friendly picker.
        if ([PHPickerViewController class] != nil) {
            PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
            config.selectionLimit = 1;
            config.filter = allowsVideo
                ? [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter videosFilter]]]
                : [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter imagesFilter]]];

            PHPickerViewController *picker =
                [[PHPickerViewController alloc] initWithConfiguration:config];
            picker.delegate = self;
            picker.modalPresentationStyle = UIModalPresentationFullScreen;
            [presenter presentViewController:picker animated:YES completion:nil];
            return;
        }

        // Fallback for older systems.
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.delegate = self;
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[typeIdentifier];
        picker.modalPresentationStyle = UIModalPresentationFullScreen;
        [presenter presentViewController:picker animated:YES completion:nil];
    });
}

#pragma mark - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];

    PHPickerResult *result = results.firstObject;
    if (result == nil) {
        return;
    }

    NSItemProvider *provider = result.itemProvider;

    // Movie?
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [self loadFileFromProvider:provider
                         extension:@"mp4"
                             type:BokeCamMediaTypeVideo];
        return;
    }

    // Image.
    [self loadImageFromProvider:provider];
}

#pragma mark - UIImagePickerControllerDelegate (fallback path)

- (void)imagePickerController:(UIImagePickerController *)picker
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSURL *mediaURL = info[UIImagePickerControllerMediaURL];
    UIImage *image = info[UIImagePickerControllerOriginalImage];

    if (mediaURL != nil) {
        [self storeFileAtURL:mediaURL
                    fileName:kBokeCamMovieFileName
                        type:BokeCamMediaTypeVideo];
    } else if (image != nil) {
        [self storeImage:image];
    } else {
        [self showErrorMessage:@"Media không hợp lệ."];
    }

    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Loading picked media

- (void)loadImageFromProvider:(NSItemProvider *)provider {
    if (![provider canLoadObjectOfClass:[UIImage class]]) {
        [self showErrorMessage:@"Không thể tải ảnh đã chọn."];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:[UIImage class]
              completionHandler:^(__unused id<NSItemProviderReading> object, NSError *error) {
        UIImage *image = [object isKindOfClass:[UIImage class]] ? (UIImage *)object : nil;
        if (image == nil) {
            [weakSelf showErrorMessage:error.localizedDescription ?: @"Ảnh không hợp lệ."];
            return;
        }
        [weakSelf storeImage:image];
    }];
}

- (void)loadFileFromProvider:(NSItemProvider *)provider
                   extension:(NSString *)extension
                       type:(BokeCamMediaType)type {
    NSString *identifier = @"public.movie";
    if (![provider hasItemConformingToTypeIdentifier:identifier]) {
        [self showErrorMessage:@"Tệp video không hợp lệ."];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [provider loadFileRepresentationForTypeIdentifier:identifier
                                    completionHandler:^(NSURL *url, NSError *error) {
        if (url == nil) {
            [weakSelf showErrorMessage:error.localizedDescription ?: @"Không thể tải video."];
            return;
        }

        // The URL is only valid inside this block, the copy happens
        // synchronously in -storeFileAtURL:fileName:type:.
        NSString *fileName = kBokeCamMovieFileName;
        [weakSelf storeFileAtURL:url fileName:fileName type:type];
    }];
}

#pragma mark - Storing media

// Writes the picked file into every shared media directory and remembers the
// path in the shared preferences.
- (void)storeFileAtURL:(NSURL *)url fileName:(NSString *)fileName type:(BokeCamMediaType)type {
    if (url == nil) {
        [self showErrorMessage:@"Không thể đọc tệp media."];
        return;
    }

    NSString *storedPath = BokeCamStoreMediaFile(url.path, fileName);
    if (storedPath == nil) {
        [self showErrorMessage:@"Không lưu được tệp media. Kiểm tra quyền ghi."];
        return;
    }

    BokeCamSettings *settings = [BokeCamSettings shared];
    [settings commitMediaPath:storedPath fileName:fileName type:type];
    BokeCamInvalidateFrameSource();
}

// Converts the picked image to JPEG and stores it.
- (void)storeImage:(UIImage *)image {
    NSData *jpegData = UIImageJPEGRepresentation(image, 0.95);
    if (jpegData.length == 0) {
        [self showErrorMessage:@"Không mã hoá được ảnh."];
        return;
    }

    NSString *fileName = kBokeCamStillFileName;
    NSString *storedPath = BokeCamStoreMediaData(jpegData, fileName);
    if (storedPath == nil) {
        [self showErrorMessage:@"Không lưu được ảnh. Kiểm tra quyền ghi."];
        return;
    }

    BokeCamSettings *settings = [BokeCamSettings shared];
    [settings commitMediaPath:storedPath fileName:fileName type:BokeCamMediaTypeImage];
    BokeCamInvalidateFrameSource();
}

#pragma mark - Errors

- (void)showErrorMessage:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = [self topViewController];
        if (presenter == nil) {
            return;
        }
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"BokeCam"
                                                message:message ?: @"Đã xảy ra lỗi."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Đóng"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Notifications

- (void)settingsChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        BokeCamSettings *settings = [BokeCamSettings shared];
        [settings reloadFromDisk];

        UIColor *background = settings.vcamEnabled
            ? [UIColor colorWithRed:0.15 green:0.75 blue:0.42 alpha:0.90]
            : [UIColor colorWithRed:0.11 green:0.62 blue:0.94 alpha:0.90];

        self->_floatingButton.backgroundColor = background;
    });
}

@end

#pragma mark - Legacy manager

@implementation BokeCamManager

+ (instancetype)sharedInstance {
    static BokeCamManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[BokeCamManager alloc] init];
    });
    return shared;
}

- (void)showFloatingButton {
    [[UIController sharedInstance] showFloatingButton];
}

@end
