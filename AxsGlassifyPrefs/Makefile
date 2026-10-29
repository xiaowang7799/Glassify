include ../AxsGlassifyBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsGlassifyPrefs
AxsGlassifyPrefs_FILES = $(wildcard *.m)
AxsGlassifyPrefs_CFLAGS = -fobjc-arc -I../Sources
AxsGlassifyPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsGlassifyPrefs_PRIVATE_FRAMEWORKS = Preferences
AxsGlassifyPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
