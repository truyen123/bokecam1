//
//  Tweak.h
//  BokeCam
//
//  Shared interface between the injected tweak logic (Tweak.xm) and the
//  floating control panel (UIController.mm). Both are compiled into the SAME
//  dylib and therefore run inside the SAME host process.
//
//  Cross process behaviour:
//    * The enable flag, the media file name and the media type are stored in a
//      shared NSUserDefaults suite (kBokeCamPrefsSuite). Every injected
//      process reads the very same preferences, so toggling VCam in one app
//      immediately affects every other app.
//    * The media payload itself is stored as a file inside a shared directory
//      (see BokeCamMediaDirectory / BokeCamSharedMediaDirectory) so that all
//      processes point at the same bytes.
//

#ifndef BOKECAM_TWEAK_H
#define BOKECAM_TWEAK_H

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#pragma mark - Shared preference keys

#define kBokeCamPrefsSuite        @"com.bokecam.tweak.preferences"
#define kBokeCamEnabledKey        @"vcamEnabled"
#define kBokeCamMediaPathKey      @"mediaPath"
#define kBokeCamMediaTypeKey      @"mediaType"
#define kBokeCamMediaFileNameKey  @"mediaFileName"

#pragma mark - Shared file names

// Stable file names, so that every process looks for the same file inside the
// shared media directory even when the absolute path differs per process.
#define kBokeCamStillFileName     @"bokecam_frame.jpg"
#define kBokeCamMovieFileName     @"bokecam_clip.mp4"

#pragma mark - Notifications

// Posted inside the process right after a preference value changed, so the
// sample-buffer hook can invalidate its cached frame source immediately.
extern NSString *const kBokeCamSettingsChangedNotification;

typedef NS_ENUM(NSInteger, BokeCamMediaType) {
    BokeCamMediaTypeImage = 0,
    BokeCamMediaTypeVideo = 1
};

#pragma mark - Shared helpers

// Directory where picked media is stored. Tries the shared jailbreak path
// first (/var/mobile/Media/BokeCam and the rootless equivalents) and
// transparently falls back to the host application sandbox
// (Documents/BokeCam) when the shared location is not writable.
FOUNDATION_EXPORT NSString *BokeCamMediaDirectory(void);

// Shared, cross application media directory (may be nil when unavailable).
FOUNDATION_EXPORT NSString *BokeCamSharedMediaDirectory(void);

// Resolves the real, readable path of the selected media. Falls back to
// scanning the shared directories when the stored absolute path does not
// exist in the current process (different sandbox / different root prefix).
FOUNDATION_EXPORT NSString *BokeCamResolveMediaPath(NSString *storedPath, NSString *fileName);

// Drops the cached image/video frame source (call after media change).
FOUNDATION_EXPORT void BokeCamInvalidateFrameSource(void);

// Best effort copy of a file into every shared directory, so that all
// processes find the same payload. Returns the canonical path of the first
// successfully written copy, or nil on failure.
FOUNDATION_EXPORT NSString *BokeCamStoreMediaFile(NSString *sourcePath, NSString *fileName);

// Writes raw data (a JPEG) into every shared directory. Returns the
// canonical path of the first successfully written copy, or nil on failure.
FOUNDATION_EXPORT NSString *BokeCamStoreMediaData(NSData *data, NSString *fileName);

#pragma mark - Settings store

@interface BokeCamSettings : NSObject

+ (instancetype)shared;

@property (nonatomic, assign, readonly) BOOL vcamEnabled;
@property (nonatomic, copy,   readonly) NSString *mediaPath;
@property (nonatomic, assign, readonly) BokeCamMediaType mediaType;
@property (nonatomic, copy,   readonly) NSString *mediaFileName;

- (void)reloadFromDisk;
- (void)commitEnabled:(BOOL)enabled;
- (void)commitMediaPath:(NSString *)path
               fileName:(NSString *)fileName
                   type:(BokeCamMediaType)type;
- (BOOL)hasUsableMedia;

@end

#pragma mark - Legacy entry point kept for compatibility

@interface BokeCamManager : NSObject
+ (instancetype)sharedInstance;
- (void)showFloatingButton;
@end

#endif /* BOKECAM_TWEAK_H */
