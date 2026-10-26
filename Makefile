# Minimum deployment target is iOS 14.0, the tweak was verified on
# iOS 16.7.12. The "latest" SDK is used to compile against, the deployment
# target below decides which APIs are actually available at runtime.
TARGET := iphone:clang:latest:14.0

# Both slices are built so the same package works on arm64 only devices
# (iPhone 5s - iPhone X) and on arm64e devices (iPhone Xs and newer, which
# use the arm64e ABI on iOS 14+).
ARCHS = arm64 arm64e

# RootHide package layout. RootHide mounts the jailbreak tree at /var/jb and
# additionally uses /var/jb/var/jb as the "real" jailbreak root, so that
# rootless paths keep working on top of it.
#
# Theos ships the `roothide` scheme for this. It installs the dylib into
# /var/jb/usr/lib/TweakInject and the plist into
# /var/jb/Library/MobileSubstrate/DynamicLibraries.
THEOS_PACKAGE_SCHEME = roothide

# Restart the Camera app after installation so the injected dylib is loaded
# right away. Add more processes (FaceTime, Photos, ...) if needed.
INSTALL_TARGET_PROCESSES = Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BokeCam

BokeCam_FILES = Tweak.xm UIController.mm
BokeCam_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage \
                     QuartzCore PhotosUI ImageIO CoreGraphics

BokeCam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function \
                 -Wno-unused-variable -Wno-nullability-completeness

BokeCam_CXXFLAGS = -fobjc-arc -std=c++14

include $(THEOS_MAKE_PATH)/tweak.mk
