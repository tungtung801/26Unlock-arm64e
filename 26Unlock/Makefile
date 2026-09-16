export TARGET = iphone:clang:latest:15.0
# arm64e  -> A12+ (PAC), the slice SpringBoard uses on the target device
# arm64   -> A11 and below, so the same .deb still works on the older phone
#            (dyld picks the matching slice automatically)
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 26Unlock

26Unlock_FILES = Tweak.xm WaveEngine.m WaveTable.m WaveIcon.m
26Unlock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
26Unlock_FRAMEWORKS = UIKit QuartzCore CoreGraphics
26Unlock_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

include $(THEOS_MAKE_PATH)/aggregate.mk
