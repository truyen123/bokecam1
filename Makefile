TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# Rootless package layout (/var/jb). Required for Dopamine, palera1n rootless,
# XinaA15 and other rootless jailbreaks. Theos places the files under /var/jb
# automatically. Switch to `rootless` -> `roothide` for RootHide setups.
THEOS_PACKAGE_SCHEME = rootless

# Restart the Camera app after installation so the injected dylib is loaded
# right away. Add more processes (FaceTime, Photos, ...) if needed.
INSTALL_TARGET_PROCESSES = Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BokeCam

BokeCam_FILES = Tweak.xm UIController.mm
BokeCam_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage \
                     QuartzCore PhotosUI ImageIO CoreGraphics

BokeCam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function \
                 -Wno-unused-variable -Wno-nullability-completeness -Wno-deprecated-declarations

BokeCam_CXXFLAGS = -fobjc-arc -std=c++14

include $(THEOS_MAKE_PATH)/tweak.mk
