//
//  UIController.h
//  BokeCam
//
//  Floating control panel that is injected into every user facing application.
//  It shows a small always on top button. Tapping it opens an alert with the
//  current VCam state, a switch to enable / disable the virtual camera and a
//  button that opens the system media picker so the user can choose a JPEG /
//  PNG picture or an MP4 video.
//

#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIController : NSObject <UIImagePickerControllerDelegate,
                                    UINavigationControllerDelegate,
                                    PHPickerViewControllerDelegate>

+ (instancetype)sharedInstance;

// Creates and shows the floating button. Safe to call multiple times.
- (void)showFloatingButton;

// Removes the floating button from the screen.
- (void)hideFloatingButton;

// Opens the control panel directly.
- (void)openPanel;

@end

NS_ASSUME_NONNULL_END
