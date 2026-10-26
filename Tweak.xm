//
//  Tweak.xm
//  BokeCam
//
//  System wide virtual camera.
//
//  Strategy
//  --------
//  1. The real camera sensor is never touched. Instead the frames that leave
//     AVCaptureVideoDataOutput are intercepted and the CMSampleBuffer is
//     swapped for a synthetic one that carries the picture / video the user
//     selected in the floating panel.
//
//  2. `captureOutput:didOutputSampleBuffer:fromConnection:` is implemented by
//     the *host application*, not by AVFoundation, so a Logos %hook is not
//     possible. We therefore swizzle the delegate class right after the
//     application hands its delegate over to AVCaptureVideoDataOutput.
//
//  3. On iOS 17+ the block based API
//     `-setSampleBufferDelegate:queue:sampleBufferCallback:` is used by most
//     applications. The callback block is wrapped so the very same
//     substitution happens there.
//
//  4. Still photos are handled as well: the photo delegate is swizzled and
//     `-fileDataRepresentation` returns our generated JPEG.
//
//  5. Settings (enabled / media path / media type) are shared between every
//     injected process through
//        - an NSUserDefaults suite (fast, per process cache)
//        - a mirrored plist inside a globally readable directory
//     The mirrored plist is the cross process channel because a sandboxed
//     application cannot read another application's preference domain.
//
//  6. The synthetic buffer keeps the *exact* pixel format of the original
//     camera buffer (YUV bi-planar 420f/420v or BGRA), so the consuming
//     application never notices the difference.
//

#import "Tweak.h"
#import "roothide.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdlib.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

#pragma mark - Constants

NSString *const kBokeCamSettingsChangedNotification = @"kBokeCamSettingsChangedNotification";

static NSString *const kBokeCamSettingsFileName = @"settings.plist";
static NSString *const kBokeCamDefaultsSuite = kBokeCamPrefsSuite;

#pragma mark - Global state

static NSMutableDictionary *gSwizzledIMPs = nil;   // key -> original IMP
static NSMutableArray   *gSwizzleBlocks = nil;     // keeps the blocks alive
static NSMutableArray   *gWrappedCallbacks = nil;  // keeps wrapped blocks alive

@class BokeCamFrameSource;

static BokeCamFrameSource *gBokeCamFrameSource = nil;
static NSString          *gBokeCamFrameSourcePath = nil;

#pragma mark - Forward declarations

static CMSampleBufferRef BokeCamCreateSampleBuffer(CMSampleBufferRef originalBuffer);
static void BokeCamPreparePhoto(AVCapturePhoto *photo);
static void BokeCamSwizzleSampleBufferDelegate(Class delegateClass, SEL selector);
static void BokeCamSwizzlePhotoDelegate(Class delegateClass, SEL selector);

#pragma mark - Small utilities

static BokeCamMediaType BokeCamMediaTypeFromValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return (BokeCamMediaType)[(NSNumber *)value integerValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        if ([lower isEqualToString:@"video"] || [lower isEqualToString:@"movie"]) {
            return BokeCamMediaTypeVideo;
        }
    }
    return BokeCamMediaTypeImage;
}

static NSString *BokeCamStringValue(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }
    return nil;
}

static BOOL BokeCamFileExists(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

#pragma mark - Shared directories

// Directories that are usable from a jailbroken, sandboxed application.
// Ordered by preference; the first writable one is used for storing data.
//
// RootHide does not install the jailbreak to a fixed path. The directory
// (named jbroot) gets a random name on every jailbreak, therefore every path
// has to be resolved through the `jbroot()` API of roothide.h. The API is a
// no-op stub when the tweak is compiled for rootful / rootless.
//
// The paths below are therefore "jbroot based" paths, exactly what the
// roothide API expects as its input.
//
// /var/mobile/Containers/Shared/App is the container that every app on a
// jailbroken device can read, which makes it the most reliable place to
// exchange data between two different applications.
static NSArray<NSString *> *BokeCamCandidateDirectories(void) {
    static NSArray<NSString *> *dirs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *home = NSHomeDirectory();
        dirs = @[
            // Shared container, readable by every app.
            @"/var/mobile/Containers/Shared/App/BokeCam",
            // Media / library directories.
            @"/var/mobile/Media/BokeCam",
            @"/var/mobile/Library/BokeCam",
            @"/var/tmp/BokeCam",
            // Sandboxed fall backs, only usable inside the own app.
            [home stringByAppendingPathComponent:@"Documents/BokeCam"],
            [home stringByAppendingPathComponent:@"Library/BokeCam"],
        ];
    });
    return dirs;
}

// Resolves a jbroot based path into the real path on this device. Falls back
// to the unmodified path when the jailbreak API is not available (for
// example when the tweak runs outside of a jailbroken environment).
NSString *BokeCamJBRootPath(NSString *path) {
    if (path.length == 0) {
        return path;
    }
    return jbroot(path);
}

// The candidate directories with the jailbreak root resolved. All file
// system access has to use these, the raw list is only jbroot based.
static NSArray<NSString *> *BokeCamResolvedDirectories(void) {
    static NSArray<NSString *> *dirs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *resolved = [NSMutableArray array];
        for (NSString *candidate in BokeCamCandidateDirectories()) {
            NSString *real = BokeCamJBRootPath(candidate);
            if (real.length > 0 && ![resolved containsObject:real]) {
                [resolved addObject:real];
            }
        }
        dirs = [resolved copy];
    });
    return dirs;
}

// Creates the directory when needed and returns it when it is really writable.
// A probe file is used because the sandbox may allow listing but not writing.
static NSString *BokeCamWritableDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *candidate in BokeCamCandidateDirectories()) {
            if (![fm fileExistsAtPath:candidate]) {
                if (![fm createDirectoryAtPath:candidate
                    withIntermediateDirectories:YES
                                     attributes:@{NSFilePosixPermissions: @(0777)}
                                          error:NULL]) {
                    continue;
                }
            }
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:candidate isDirectory:&isDir] || !isDir) {
                continue;
            }
            NSString *probe = [candidate stringByAppendingPathComponent:
                               [NSString stringWithFormat:@".probe.%d", (int)getpid()]];
            NSError *writeError = nil;
            BOOL ok = [@"1" writeToFile:probe
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:&writeError];
            if (ok) {
                [fm removeItemAtPath:probe error:NULL];
                dir = candidate;
                break;
            }
        }
        if (dir == nil) {
            NSString *home = NSHomeDirectory();
            dir = [home stringByAppendingPathComponent:@"Documents/BokeCam"];
            [fm createDirectoryAtPath:dir
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL];
        }
    });
    return dir;
}

// Directory that is readable by every process. Used to look up the media file
// that was written by a different application.
NSString *BokeCamSharedMediaDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *candidate in BokeCamCandidateDirectories()) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
                dir = candidate;
                break;
            }
        }
        if (dir == nil) {
            dir = BokeCamWritableDirectory();
        }
    });
    return dir;
}

// The directory the current process writes to.
NSString *BokeCamMediaDirectory(void) {
    return BokeCamWritableDirectory();
}

// Finds `fileName` in every known directory. Needed because the absolute path
// stored in the preferences may have been produced by another (sandboxed)
// process with a different container path.
NSString *BokeCamResolveMediaPath(NSString *storedPath, NSString *fileName) {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (storedPath.length > 0 && [fm fileExistsAtPath:storedPath]) {
        return storedPath;
    }

    if (fileName.length > 0) {
        for (NSString *dir in BokeCamCandidateDirectories()) {
            NSString *candidate = [dir stringByAppendingPathComponent:fileName];
            if ([fm fileExistsAtPath:candidate]) {
                return candidate;
            }
        }
    }

    if (storedPath.length > 0) {
        NSString *name = storedPath.lastPathComponent;
        if (name.length > 0) {
            for (NSString *dir in BokeCamCandidateDirectories()) {
                NSString *candidate = [dir stringByAppendingPathComponent:name];
                if ([fm fileExistsAtPath:candidate]) {
                    return candidate;
                }
            }
        }
    }

    return storedPath.length > 0 ? storedPath : nil;
}

// Writes a copy of `sourcePath` into every shared directory that accepts a
// write. The first successful copy defines the canonical path.
NSString *BokeCamStoreMediaFile(NSString *sourcePath, NSString *fileName) {
    if (sourcePath.length == 0 || fileName.length == 0) {
        return nil;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *canonicalPath = nil;

    for (NSString *dir in BokeCamCandidateDirectories()) {
        if (![fm fileExistsAtPath:dir]) {
            continue;
        }
        NSString *destinationPath = [dir stringByAppendingPathComponent:fileName];

        if ([fm fileExistsAtPath:destinationPath]) {
            [fm removeItemAtPath:destinationPath error:NULL];
        }

        NSError *error = nil;
        BOOL copied = [fm copyItemAtPath:sourcePath toPath:destinationPath error:&error];
        if (!copied) {
            continue;
        }

        [fm setAttributes:@{NSFilePosixPermissions: @(0666)}
             ofItemAtPath:destinationPath
                    error:NULL];

        if (canonicalPath == nil) {
            canonicalPath = destinationPath;
        }
    }

    return canonicalPath;
}

// Writes raw data into every shared directory that accepts a write.
NSString *BokeCamStoreMediaData(NSData *data, NSString *fileName) {
    if (data.length == 0 || fileName.length == 0) {
        return nil;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *canonicalPath = nil;

    for (NSString *dir in BokeCamCandidateDirectories()) {
        if (![fm fileExistsAtPath:dir]) {
            continue;
        }
        NSString *destinationPath = [dir stringByAppendingPathComponent:fileName];

        NSError *error = nil;
        if (![data writeToFile:destinationPath options:NSDataWritingAtomic error:&error]) {
            continue;
        }

        [fm setAttributes:@{NSFilePosixPermissions: @(0666)}
             ofItemAtPath:destinationPath
                    error:NULL];

        if (canonicalPath == nil) {
            canonicalPath = destinationPath;
        }
    }

    return canonicalPath;
}

#pragma mark - Settings store

@implementation BokeCamSettings

+ (instancetype)shared {
    static BokeCamSettings *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[BokeCamSettings alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self reloadFromDisk];
    }
    return self;
}

- (NSUserDefaults *)defaults {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kBokeCamDefaultsSuite];
    if (defaults == nil) {
        defaults = [NSUserDefaults standardUserDefaults];
    }
    return defaults;
}

- (void)reloadFromDisk {
    NSUserDefaults *defaults = [self defaults];

    BOOL enabled = [defaults boolForKey:kBokeCamEnabledKey];
    NSString *path = BokeCamStringValue([defaults objectForKey:kBokeCamMediaPathKey]);
    NSString *fileName = BokeCamStringValue([defaults objectForKey:kBokeCamMediaFileNameKey]);
    BokeCamMediaType type = BokeCamMediaTypeFromValue([defaults objectForKey:kBokeCamMediaTypeKey]);

    // The mirrored plist is authoritative because it is the only storage that
    // is visible from every sandbox.
    NSDictionary *mirror = [self readMirror];
    if (mirror != nil) {
        id mirrorEnabled = mirror[@"enabled"];
        if ([mirrorEnabled isKindOfClass:[NSNumber class]]) {
            enabled = [(NSNumber *)mirrorEnabled boolValue];
        }
        NSString *mirrorPath = BokeCamStringValue(mirror[@"mediaPath"]);
        NSString *mirrorFileName = BokeCamStringValue(mirror[@"mediaFileName"]);
        id mirrorType = mirror[@"mediaType"];
        if (mirrorPath.length > 0) {
            path = mirrorPath;
        }
        if (mirrorFileName.length > 0) {
            fileName = mirrorFileName;
        }
        if (mirrorType != nil) {
            type = BokeCamMediaTypeFromValue(mirrorType);
        }
    }

    _vcamEnabled = enabled;
    _mediaPath = [path copy];
    _mediaFileName = [fileName copy];
    _mediaType = type;
}

// Reads the first readable settings.plist found in the known directories.
- (NSDictionary *)readMirror {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in BokeCamCandidateDirectories()) {
        NSString *path = [dir stringByAppendingPathComponent:kBokeCamSettingsFileName];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length == 0) {
            continue;
        }
        id object = [NSPropertyListSerialization propertyListWithData:data
                                                              options:NSPropertyListImmutable
                                                               format:NULL
                                                                error:NULL];
        if ([object isKindOfClass:[NSDictionary class]]) {
            return (NSDictionary *)object;
        }
    }
    return nil;
}

// Writes the settings into every directory that accepts a write, so that all
// processes find a copy no matter which one they can read.
- (void)writeMirror:(NSDictionary *)dictionary {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (data == nil) {
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in BokeCamCandidateDirectories()) {
        if (![fm fileExistsAtPath:dir]) {
            continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:kBokeCamSettingsFileName];
        [data writeToFile:path options:NSDataWritingAtomic error:NULL];
        [fm setAttributes:@{NSFilePosixPermissions: @(0666)}
             ofItemAtPath:path
                    error:NULL];
    }
}

- (void)commitEnabled:(BOOL)enabled {
    _vcamEnabled = enabled;

    NSUserDefaults *defaults = [self defaults];
    [defaults setBool:enabled forKey:kBokeCamEnabledKey];
    [defaults synchronize];

    [self writeMirror:[self currentMirrorDictionary]];

    [[NSNotificationCenter defaultCenter] postNotificationName:kBokeCamSettingsChangedNotification
                                                        object:nil];
}

- (void)commitMediaPath:(NSString *)path
               fileName:(NSString *)fileName
                   type:(BokeCamMediaType)type {
    _mediaPath = [path copy];
    _mediaFileName = [fileName copy];
    _mediaType = type;

    NSUserDefaults *defaults = [self defaults];
    if (_mediaPath.length > 0) {
        [defaults setObject:_mediaPath forKey:kBokeCamMediaPathKey];
    } else {
        [defaults removeObjectForKey:kBokeCamMediaPathKey];
    }
    if (_mediaFileName.length > 0) {
        [defaults setObject:_mediaFileName forKey:kBokeCamMediaFileNameKey];
    } else {
        [defaults removeObjectForKey:kBokeCamMediaFileNameKey];
    }
    [defaults setInteger:(NSInteger)type forKey:kBokeCamMediaTypeKey];
    [defaults synchronize];

    [self writeMirror:[self currentMirrorDictionary]];

    BokeCamInvalidateFrameSource();

    [[NSNotificationCenter defaultCenter] postNotificationName:kBokeCamSettingsChangedNotification
                                                        object:nil];
}

- (NSDictionary *)currentMirrorDictionary {
    return @{
        @"enabled": @(_vcamEnabled),
        @"mediaPath": _mediaPath ?: @"",
        @"mediaFileName": _mediaFileName ?: @"",
        @"mediaType": @((NSInteger)_mediaType),
        @"updatedAt": @([[NSDate date] timeIntervalSince1970]),
    };
}

- (BOOL)hasUsableMedia {
    if (_mediaPath.length == 0 && _mediaFileName.length == 0) {
        return NO;
    }
    NSString *resolved = BokeCamResolveMediaPath(_mediaPath, _mediaFileName);
    return BokeCamFileExists(resolved);
}

@end

#pragma mark - Frame source

// Produces frames out of the user supplied image / video.
@interface BokeCamFrameSource : NSObject

@property (nonatomic, copy,   readonly) NSString *mediaPath;
@property (nonatomic, assign, readonly) BokeCamMediaType mediaType;

- (instancetype)initWithMediaPath:(NSString *)path mediaType:(BokeCamMediaType)type;
- (BOOL)isUsable;
- (CGSize)naturalSize;
// Returns the current frame. For videos the reader is advanced, for still
// images the decoded image is returned.
- (CIImage *)sourceImage;
// Scales an image so that it fills the given size while keeping the aspect
// ratio of the source.
- (CIImage *)image:(CIImage *)image scaledToFill:(CGSize)size;
// Creates a pixel buffer that matches the pixel format / size of `template`.
- (CVPixelBufferRef)createPixelBufferMatching:(CVPixelBufferRef)templateBuffer;
// Creates a BGRA pixel buffer of an explicit size.
- (CVPixelBufferRef)createBGRABufferWithWidth:(size_t)width height:(size_t)height;
// Creates a BGRA pixel buffer that contains the current source frame,
// scaled to fill the requested size.
- (CVPixelBufferRef)createRenderedBufferWithWidth:(size_t)width height:(size_t)height;
// Renders the current source frame into a CGImage. The caller owns the
// returned image and must release it with CGImageRelease.
- (CGImageRef)createCGImageFromSource;

@end

@implementation BokeCamFrameSource {
    CIContext *_ciContext;
    CIImage *_stillImage;          // still images
    CGSize _stillSize;
    AVAssetReader *_reader;        // videos
    AVAssetReaderTrackOutput *_readerOutput;
}

- (instancetype)initWithMediaPath:(NSString *)path mediaType:(BokeCamMediaType)type {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _mediaPath = [path copy];
    _mediaType = type;
    _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    [self prepareSource];
    return self;
}

- (void)prepareSource {
    if (self.mediaPath.length == 0) {
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:self.mediaPath];
    if (self.mediaType == BokeCamMediaTypeVideo) {
        [self prepareVideoReaderForURL:url];
    } else {
        [self prepareStillImageForURL:url];
    }
}

- (void)prepareStillImageForURL:(NSURL *)url {
    if (url == nil) {
        return;
    }
    CIImage *image = [CIImage imageWithContentsOfURL:url
                                           options:@{ kCIImageApplyingOrientationProperty: @YES }
                                             error:NULL];
    if (image == nil) {
        // Fall back to UIImage, handles JPEG and PNG.
        UIImage *uiImage = [UIImage imageWithContentsOfFile:url.path];
        if (uiImage == nil) {
            return;
        }
        image = [[CIImage alloc] initWithImage:uiImage];
    }
    _stillImage = image;
    _stillSize = image.extent.size;
}

- (void)prepareVideoReaderForURL:(NSURL *)url {
    if (url == nil) {
        return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *track = tracks.firstObject;
    if (track == nil) {
        return;
    }

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey: @NO,
    };

    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:NULL];
    if (reader == nil) {
        return;
    }
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                                                 outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        return;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        return;
    }
    _reader = reader;
    _readerOutput = output;
}

- (BOOL)isUsable {
    if (self.mediaType == BokeCamMediaTypeVideo) {
        if (_reader != nil) {
            return YES;
        }
        [self prepareVideoReaderForURL:[NSURL fileURLWithPath:self.mediaPath]];
        return _reader != nil;
    }
    return _stillImage != nil;
}

- (CGSize)naturalSize {
    if (self.mediaType == BokeCamMediaTypeVideo) {
        if (_readerOutput != nil) {
            CGSize size = _readerOutput.track.naturalSize;
            if (size.width > 0 && size.height > 0) {
                return size;
            }
        }
        return CGSizeMake(1280, 720);
    }
    return _stillSize;
}

#pragma mark Frame extraction

// Returns the next image of the video. When the clip ends the reader is
// restarted so that the video loops forever.
- (CIImage *)nextVideoFrameImage {
    if (_reader == nil) {
        [self prepareVideoReaderForURL:[NSURL fileURLWithPath:self.mediaPath]];
        if (_reader == nil) {
            return nil;
        }
    }

    for (int attempt = 0; attempt < 3; attempt++) {
        CMSampleBufferRef sample = [_readerOutput copyNextSampleBuffer];
        if (sample != NULL) {
            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sample);
            CIImage *image = imageBuffer ? [CIImage imageWithCVPixelBuffer:imageBuffer] : nil;
            CFRelease(sample);
            if (image != nil) {
                return image;
            }
            continue;
        }

        if (_reader.status == AVAssetReaderStatusFailed) {
            return nil;
        }

        // End of the clip, restart it.
        [_reader cancelReading];
        _reader = nil;
        _readerOutput = nil;
        [self prepareVideoReaderForURL:[NSURL fileURLWithPath:self.mediaPath]];
        if (_reader == nil) {
            return nil;
        }
    }
    return nil;
}

- (CIImage *)sourceImage {
    if (self.mediaType == BokeCamMediaTypeVideo) {
        return [self nextVideoFrameImage];
    }
    return _stillImage;
}

// Scales the image so that it covers the requested size (aspect fill) and
// centers it in the middle.
- (CIImage *)image:(CIImage *)image scaledToFill:(CGSize)size {
    if (image == nil || size.width <= 0 || size.height <= 0) {
        return image;
    }
    CGRect extent = image.extent;
    if (extent.width <= 0 || extent.height <= 0) {
        return image;
    }
    CGFloat scale = MAX(size.width / extent.width, size.height / extent.height);
    CGFloat scaledWidth = extent.width * scale;
    CGFloat scaledHeight = extent.height * scale;

    CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGFloat dx = (size.width - scaledWidth) * 0.5;
    CGFloat dy = (size.height - scaledHeight) * 0.5;
    scaled = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
    return scaled;
}

- (CVPixelBufferRef)createBGRABufferWithWidth:(size_t)width height:(size_t)height {
    if (width == 0 || height == 0) {
        return NULL;
    }
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
    };
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess) {
        return NULL;
    }
    return buffer;
}

- (CGImageRef)createCGImageFromSource {
    CIImage *source = [self sourceImage];
    if (source == nil) {
        return NULL;
    }

    CGRect extent = source.extent;
    if (extent.width <= 0 || extent.height <= 0) {
        return NULL;
    }

    return [_ciContext createCGImage:source fromRect:extent];
}

- (CVPixelBufferRef)createRenderedBufferWithWidth:(size_t)width height:(size_t)height {
    if (width == 0 || height == 0) {
        return NULL;
    }

    CIImage *source = [self sourceImage];
    if (source == nil) {
        return NULL;
    }

    CVPixelBufferRef buffer = [self createBGRABufferWithWidth:width height:height];
    if (buffer == NULL) {
        return NULL;
    }

    CIImage *prepared = [self image:source scaledToFill:CGSizeMake(width, height)];
    prepared = [prepared imageByCroppingToRect:CGRectMake(0, 0, width, height)];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_ciContext render:prepared
        toCVPixelBuffer:buffer
                 bounds:CGRectMake(0, 0, width, height)
             colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    return buffer;
}

- (CVPixelBufferRef)createPixelBufferMatching:(CVPixelBufferRef)templateBuffer {
    if (templateBuffer == NULL) {
        return NULL;
    }

    const size_t width = CVPixelBufferGetWidth(templateBuffer);
    const size_t height = CVPixelBufferGetHeight(templateBuffer);
    if (width == 0 || height == 0) {
        return NULL;
    }

    OSType pixelFormat = CVPixelBufferGetPixelFormatType(templateBuffer);
    BOOL isBiPlanar = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                       pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

    CIImage *source = [self sourceImage];
    if (source == nil) {
        return NULL;
    }

    CIImage *prepared = [self image:source scaledToFill:CGSizeMake(width, height)];
    prepared = [prepared imageByCroppingToRect:CGRectMake(0, 0, width, height)];

    CVPixelBufferRef result = NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    if (isBiPlanar) {
        // Render into BGRA and convert manually, CoreImage cannot write
        // bi-planar YUV directly.
        CVPixelBufferRef bgra = [self createBGRABufferWithWidth:width height:height];
        if (bgra == NULL) {
            CGColorSpaceRelease(colorSpace);
            return NULL;
        }

        [_ciContext render:prepared
            toCVPixelBuffer:bgra
                     bounds:CGRectMake(0, 0, width, height)
                 colorSpace:colorSpace];

        NSDictionary *yuvAttrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
        };
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                (__bridge CFDictionaryRef)yuvAttrs, &result) != kCVReturnSuccess ||
            result == NULL) {
            CVPixelBufferRelease(bgra);
            CGColorSpaceRelease(colorSpace);
            return NULL;
        }

        [self convertBGRAtoBiPlanar:bgra into:result width:width height:height];
        CVPixelBufferRelease(bgra);
    } else {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
        };
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                (__bridge CFDictionaryRef)attrs, &result) != kCVReturnSuccess ||
            result == NULL) {
            CGColorSpaceRelease(colorSpace);
            return NULL;
        }
        [_ciContext render:prepared
            toCVPixelBuffer:result
                     bounds:CGRectMake(0, 0, width, height)
                 colorSpace:colorSpace];
    }

    CGColorSpaceRelease(colorSpace);
    return result;
}

// Straightforward BT.601 conversion BGRA -> YUV 4:2:0 bi-planar.
- (void)convertBGRAtoBiPlanar:(CVPixelBufferRef)bgra
                         into:(CVPixelBufferRef)yuv
                        width:(size_t)width
                       height:(size_t)height {
    CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(yuv, 0);

    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(bgra);
    size_t srcStride = CVPixelBufferGetBytesPerRow(bgra);

    uint8_t *yPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(yuv, 0);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(yuv, 0);
    uint8_t *uvPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(yuv, 1);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(yuv, 1);

    if (src != NULL && yPlane != NULL && uvPlane != NULL) {
        for (size_t row = 0; row < height; row++) {
            const uint8_t *srcRow = src + row * srcStride;
            uint8_t *yRow = yPlane + row * yStride;
            uint8_t *uvRow = uvPlane + (row / 2) * uvStride;

            for (size_t col = 0; col < width; col++) {
                size_t offset = col * 4;
                uint8_t b = srcRow[offset + 0];
                uint8_t g = srcRow[offset + 1];
                uint8_t r = srcRow[offset + 2];

                int yv = (int)(0.299 * r + 0.587 * g + 0.114 * b);
                int cb = (int)(-0.168736 * r - 0.331264 * g + 0.5 * b + 128.0);
                int cr = (int)(0.5 * r - 0.418688 * g - 0.081312 * b + 128.0);

                yRow[col] = (uint8_t)MIN(MAX(yv, 0), 255);

                if ((row % 2) == 0 && (col % 2) == 0) {
                    size_t uvOffset = (col / 2) * 2;
                    uvRow[uvOffset + 0] = (uint8_t)MIN(MAX(cb, 0), 255);
                    uvRow[uvOffset + 1] = (uint8_t)MIN(MAX(cr, 0), 255);
                }
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(yuv, 0);
    CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
}

@end

#pragma mark - Frame source cache

void BokeCamInvalidateFrameSource(void) {
    @synchronized ([BokeCamFrameSource class]) {
        gBokeCamFrameSource = nil;
        gBokeCamFrameSourcePath = nil;
    }
}

static BokeCamFrameSource *BokeCamCurrentFrameSource(void) {
    BokeCamSettings *settings = [BokeCamSettings shared];
    if (!settings.vcamEnabled) {
        return nil;
    }

    NSString *resolved = BokeCamResolveMediaPath(settings.mediaPath, settings.mediaFileName);
    if (!BokeCamFileExists(resolved)) {
        return nil;
    }

    @synchronized ([BokeCamFrameSource class]) {
        if (gBokeCamFrameSource != nil && [gBokeCamFrameSourcePath isEqualToString:resolved]) {
            return gBokeCamFrameSource;
        }
        BokeCamFrameSource *source = [[BokeCamFrameSource alloc] initWithMediaPath:resolved
                                                                         mediaType:settings.mediaType];
        if (![source isUsable]) {
            return nil;
        }
        gBokeCamFrameSource = source;
        gBokeCamFrameSourcePath = resolved;
        return gBokeCamFrameSource;
    }
}

#pragma mark - Sample buffer creation

// Builds a new CMSampleBuffer that carries the fake picture but keeps the
// timing information and the pixel format of the original camera buffer.
static CMSampleBufferRef BokeCamCreateSampleBuffer(CMSampleBufferRef originalBuffer) {
    if (originalBuffer == NULL) {
        return NULL;
    }

    CVImageBufferRef originalImage = CMSampleBufferGetImageBuffer(originalBuffer);
    if (originalImage == NULL) {
        return NULL;
    }

    BokeCamFrameSource *source = BokeCamCurrentFrameSource();
    if (source == nil) {
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = [source createPixelBufferMatching:originalImage];
    if (pixelBuffer == NULL) {
        return NULL;
    }

    // The format description of the original buffer describes the camera
    // pixel format. It must be re-created for the new buffer, otherwise the
    // consumer would read the old (unchanged) image.
    CMFormatDescriptionRef originalFormat = CMSampleBufferGetFormatDescription(originalBuffer);
    CMVideoFormatDescriptionRef videoFormat = NULL;
    if (originalFormat != NULL &&
        CMFormatDescriptionGetMediaType(originalFormat) == kCMMediaType_Video) {
        videoFormat = (CMVideoFormatDescriptionRef)originalFormat;
    }

    CMFormatDescriptionRef formatDescription = NULL;
    if (videoFormat != NULL) {
        CMVideoFormatDescriptionRef created = NULL;
        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                         videoFormat,
                                                         pixelBuffer,
                                                         &created) == noErr &&
            created != NULL) {
            formatDescription = created;
        }
    }

    if (formatDescription == NULL) {
        // Fall back to a plain description for the pixel buffer.
        CMFormatDescriptionRef fallback = NULL;
        if (CMFormatDescriptionCreate(kCFAllocatorDefault,
                                      kCMMediaType_Video,
                                      0,
                                      pixelBuffer,
                                      &fallback) == noErr &&
            fallback != NULL) {
            formatDescription = fallback;
        }
    }

    if (formatDescription == NULL) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    CMSampleTimingInfo timing;
    CMSampleTimingInfo *timingArray = NULL;
    size_t timingCount = 0;
    OSStatus timingStatus = CMSampleBufferGetSampleTimingInfoArray(originalBuffer,
                                                                     &timingArray,
                                                                     &timingCount);
    if (timingStatus == noErr && timingArray != NULL && timingCount > 0) {
        timing = timingArray[0];
        free(timingArray);
    } else {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMTimeMake(0, 1);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef newBuffer = NULL;
    OSStatus createStatus = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                                       NULL,
                                                                       pixelBuffer,
                                                                       formatDescription,
                                                                       &timing,
                                                                       CMSampleBufferGetDataLength(originalBuffer),
                                                                       &newBuffer);
    CFRelease(formatDescription);
    CVPixelBufferRelease(pixelBuffer);

    if (createStatus != noErr || newBuffer == NULL) {
        return NULL;
    }

    return newBuffer;
}

#pragma mark - Delegate swizzling

static void BokeCamSwizzleSampleBufferDelegate(Class delegateClass, SEL selector) {
    if (delegateClass == Nil || selector == NULL) {
        return;
    }
    if (![delegateClass respondsToSelector:selector]) {
        return;
    }

    @synchronized (gSwizzledIMPs) {
        NSString *key = [NSStringFromClass(delegateClass)
                         stringByAppendingString:NSStringFromSelector(selector)];
        if (gSwizzledIMPs[key] != nil) {
            return;
        }

        Method method = class_getInstanceMethod(delegateClass, selector);
        if (method == NULL) {
            return;
        }

        IMP originalIMP = method_getImplementation(method);
        gSwizzledIMPs[key] = [NSValue valueWithPointer:originalIMP];

        void (^block)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) =
        ^void(id obj, SEL cmd, AVCaptureOutput *out, CMSampleBufferRef buffer, AVCaptureConnection *conn) {
            CMSampleBufferRef replacement = BokeCamCreateSampleBuffer(buffer);
            if (replacement != NULL) {
                ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))originalIMP)(obj,
                                                                                                          cmd,
                                                                                                          out,
                                                                                                          replacement,
                                                                                                          conn);
                CFRelease(replacement);
                return;
            }
            ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))originalIMP)(obj,
                                                                                                          cmd,
                                                                                                          out,
                                                                                                          buffer,
                                                                                                          conn);
        };

        [gSwizzleBlocks addObject:block];
        IMP replacement = imp_implementationWithBlock(block);
        if (!class_addMethod(delegateClass, selector, replacement, method_getTypeEncoding(method))) {
            method_setImplementation(method, replacement);
        }
    }
}

static void BokeCamSwizzlePhotoDelegate(Class delegateClass, SEL selector) {
    if (delegateClass == Nil || selector == NULL) {
        return;
    }
    if (![delegateClass respondsToSelector:selector]) {
        return;
    }

    @synchronized (gSwizzledIMPs) {
        NSString *key = [NSStringFromClass(delegateClass)
                         stringByAppendingString:NSStringFromSelector(selector)];
        if (gSwizzledIMPs[key] != nil) {
            return;
        }

        Method method = class_getInstanceMethod(delegateClass, selector);
        if (method == NULL) {
            return;
        }

        IMP originalIMP = method_getImplementation(method);
        gSwizzledIMPs[key] = [NSValue valueWithPointer:originalIMP];

        void (^block)(id, SEL, AVCaptureOutput *, AVCapturePhoto *, NSError *) =
        ^void(id obj, SEL cmd, AVCaptureOutput *out, AVCapturePhoto *photo, NSError *error) {
            BokeCamPreparePhoto(photo);
            ((void (*)(id, SEL, AVCaptureOutput *, AVCapturePhoto *, NSError *))originalIMP)(obj,
                                                                                            cmd,
                                                                                            out,
                                                                                            photo,
                                                                                            error);
        };

        [gSwizzleBlocks addObject:block];
        IMP replacement = imp_implementationWithBlock(block);
        if (!class_addMethod(delegateClass, selector, replacement, method_getTypeEncoding(method))) {
            method_setImplementation(method, replacement);
        }
    }
}

#pragma mark - Photo output support

static const void *kBokeCamPhotoDataKey = &kBokeCamPhotoDataKey;

// Creates a JPEG representation of the fake scene and stores it on the photo
// object. The swizzled -[AVCapturePhoto fileDataRepresentation] returns it.
static void BokeCamPreparePhoto(AVCapturePhoto *photo) {
    if (photo == nil) {
        return;
    }
    BokeCamFrameSource *source = BokeCamCurrentFrameSource();
    if (source == nil) {
        return;
    }

    CGImageRef cgImage = [source createCGImageFromSource];
    if (cgImage == NULL) {
        return;
    }

    UIImage *uiImage = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);

    NSData *jpeg = UIImageJPEGRepresentation(uiImage, 0.9);
    if (jpeg.length == 0) {
        return;
    }

    objc_setAssociatedObject(photo, kBokeCamPhotoDataKey, jpeg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Hooks

// iOS 17+ replaced the delegate based API with a block based one. The
// selector does not exist on older systems, therefore it is swizzled at
// runtime instead of using a %hook (a %hook would install %orig on a
// method that does not exist and recurse infinitely).
static void BokeCamInstallSampleBufferCallbackSwizzle(void);

%hook AVCaptureVideoDataOutput

// iOS 7 - iOS 16
- (void)setSampleBufferDelegate:(id <AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (delegate != nil) {
        BokeCamSwizzleSampleBufferDelegate((Class)[delegate class],
                                           @selector(captureOutput:didOutputSampleBuffer:fromConnection:));
    }
    %orig;
}

%end

static void BokeCamInstallSampleBufferCallbackSwizzle(void) {
    Class outputClass = [AVCaptureVideoDataOutput class];
    SEL selector = @selector(setSampleBufferDelegate:queue:sampleBufferCallback:);

    Method method = class_getInstanceMethod(outputClass, selector);
    if (method == NULL) {
        // iOS 7 - iOS 16, the delegate based API is used.
        return;
    }

    @synchronized (gSwizzledIMPs) {
        NSString *key = @"BokeCamSampleBufferCallbackSetter";
        if (gSwizzledIMPs[key] != nil) {
            return;
        }

        IMP originalIMP = method_getImplementation(method);
        gSwizzledIMPs[key] = [NSValue valueWithPointer:originalIMP];

        void (^block)(id, SEL, id, dispatch_queue_t, void (^)(AVCaptureOutput *, CMSampleBufferRef)) =
        ^void(id obj,
               SEL cmd,
               id delegate,
               dispatch_queue_t queue,
               void (^sampleBufferCallback)(AVCaptureOutput *, CMSampleBufferRef)) {
            if (delegate != nil) {
                BokeCamSwizzleSampleBufferDelegate((Class)[delegate class],
                                                   @selector(captureOutput:didOutputSampleBuffer:fromConnection:));
            }

            if (sampleBufferCallback != nil) {
                void (^wrapper)(AVCaptureOutput *, CMSampleBufferRef) =
                ^(AVCaptureOutput *output, CMSampleBufferRef sampleBuffer) {
                    CMSampleBufferRef replacement = BokeCamCreateSampleBuffer(sampleBuffer);
                    if (replacement != NULL) {
                        sampleBufferCallback(output, replacement);
                        CFRelease(replacement);
                        return;
                    }
                    sampleBufferCallback(output, sampleBuffer);
                };

                @synchronized (gWrappedCallbacks) {
                    [gWrappedCallbacks addObject:wrapper];
                }
                sampleBufferCallback = wrapper;
            }

            ((void (*)(id, SEL, id, dispatch_queue_t, void (^)(AVCaptureOutput *, CMSampleBufferRef)))originalIMP)(obj,
                                                                                                               cmd,
                                                                                                               delegate,
                                                                                                               queue,
                                                                                                               sampleBufferCallback);
        };

        [gSwizzleBlocks addObject:block];
        method_setImplementation(method, imp_implementationWithBlock(block));
    }
}

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id <AVCapturePhotoCaptureDelegate>)delegate {
    if (delegate != nil) {
        BokeCamSwizzlePhotoDelegate((Class)[delegate class],
                                    @selector(captureOutput:didFinishProcessingPhoto:error:));
    }
    %orig;
}

%end

%hook AVCapturePhoto

- (NSData *)fileDataRepresentation {
    NSData *replacement = objc_getAssociatedObject(self, kBokeCamPhotoDataKey);
    if (replacement.length > 0) {
        return replacement;
    }
    %orig;
}

%end

#pragma mark - Settings watcher

// Cross process synchronisation: the NSUserDefaults suite is only visible in
// the process that wrote it, therefore the mirrored plist is polled.
static void BokeCamStartSettingsWatcher(void) {
    static dispatch_source_t timer = nil;
    if (timer != nil) {
        return;
    }

    __block NSString *lastMediaPath = nil;
    __block BOOL lastEnabled = NO;
    __block BOOL first = YES;

    dispatch_queue_t queue = dispatch_queue_create("com.bokecam.tweak.settings",
                                                   DISPATCH_QUEUE_SERIAL);

    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.75 * NSEC_PER_SEC),
                              (uint64_t)(0.2 * NSEC_PER_SEC));

    dispatch_source_set_event_handler(timer, ^{
        BokeCamSettings *settings = [BokeCamSettings shared];
        [settings reloadFromDisk];

        if (first) {
            lastMediaPath = settings.mediaPath;
            lastEnabled = settings.vcamEnabled;
            first = NO;
            return;
        }

        if (![lastMediaPath isEqualToString:settings.mediaPath] ||
            lastEnabled != settings.vcamEnabled) {
            lastMediaPath = settings.mediaPath;
            lastEnabled = settings.vcamEnabled;
            BokeCamInvalidateFrameSource();
        }
    });

    dispatch_resume(timer);
}

#pragma mark - Bootstrap

%ctor {
    @autoreleasepool {
        gSwizzledIMPs = [NSMutableDictionary dictionary];
        gSwizzleBlocks = [NSMutableArray array];
        gWrappedCallbacks = [NSMutableArray array];

        // iOS 17+ block based sample buffer API.
        BokeCamInstallSampleBufferCallbackSwizzle();

        BokeCamStartSettingsWatcher();

        // System processes get the camera hooks but no floating button.
        NSString *processName = [NSProcessInfo processInfo].processName ?: @"";
        NSArray<NSString *> *denyList = @[
            @"mediaserverd", @"locationd", @"installd", @"mobilesubstrate",
            @"backboardd", @"cfprefsd", @"rtcreportingd", @"routined",
            @"homed", @"lsd", @"fseventsd", @"mDNSResponder", @"assertiond",
            @"configd", @"thermalmonitord", @"kernel_task", @"logd", @"syslogd",
            @"duetexpertd", @"UserEventAgent", @"CoreAudioService", @"dasd",
            @"darkservicesd", @"mobileassetd", @"SpringBoard", @"runningboardd",
            @"sbd", @"siriassistantd", @"nsurlsessiond",
        ];

        BOOL isUIProcess = YES;
        for (NSString *deny in denyList) {
            if ([processName isEqualToString:deny]) {
                isUIProcess = NO;
                break;
            }
        }

        if (isUIProcess) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[BokeCamManager sharedInstance] showFloatingButton];
            });
        }
    }
}
