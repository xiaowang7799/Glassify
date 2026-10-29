DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsGlassifyBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsGlassify
AxsGlassify_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsGlassify_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsGlassify_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsGlassify_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += AxsGlassifyPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
