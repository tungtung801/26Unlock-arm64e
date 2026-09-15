export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64e
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
