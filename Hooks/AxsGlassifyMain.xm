#import <UIKit/UIKit.h>
#import <math.h>
#import "AxsGlassifyConfig.h"
#import "AxsGlassifyGlass.h"
#import "AxsGlassifyPreferences.h"
#import "AxsGlassifyPrivate.h"

static double axs_glassify_strengthValue(void) {
    id value = [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_valueForKey:@"strength" defaultValue:@(0.35)];
    double strength = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.35;
    if (!isfinite(strength)) strength = 0.35;
    return fmax(0.0, fmin(1.0, strength));
}

static BOOL axs_glassify_darkValue(void) {
    id value = [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_valueForKey:@"dark" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

// SpringBoard's control center / notification center / folder / dock backgrounds
// are rendered by the private _UIBackdropView, which reads these settings. Tuning
// them here is what actually changes those surfaces.
%hook _UIBackdropViewSettings

- (void)setDefaultValues {
    %orig;
    if (![[AxsGlassifyConfig axs_glassify_shared] axs_glassify_isEnabled]) {
        return;
    }
    double strength = axs_glassify_strengthValue();
    BOOL dark = axs_glassify_darkValue();

    // Stronger frost with a milky tint; guarded because signatures vary by iOS.
    // Reference recipe: moderate blur + strong vibrancy (saturation) + light tint.
    if ([self respondsToSelector:@selector(setBlurRadius:)]) {
        [self setBlurRadius:14.0 + strength * 36.0];
    }
    if ([self respondsToSelector:@selector(setSaturationDeltaFactor:)]) {
        [self setSaturationDeltaFactor:1.4 + strength * 0.8];
    }
    if ([self respondsToSelector:@selector(setGrayscaleTintAlpha:)]) {
        [self setGrayscaleTintAlpha:0.05 + strength * 0.10];
    }
    if ([self respondsToSelector:@selector(setGrayscaleTintLevel:)]) {
        [self setGrayscaleTintLevel:dark ? 0.10 : 0.90];
    }
}

%end

// Add the 45-degree specular rim to each backdrop surface as it lays out.
%hook _UIBackdropView

- (void)layoutSubviews {
    %orig;
    [AxsGlassifyGlass axs_glassify_decorateBackdropView:self];
}

%end

// Some system surfaces still use the public effect view; restyle those too.
%hook UIVisualEffectView

- (instancetype)initWithEffect:(UIVisualEffect *)effect {
    effect = [AxsGlassifyGlass axs_glassify_transformIncoming:effect forView:self];
    return %orig(effect);
}

%end

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [AxsGlassifyConfig axs_glassify_shared];

        // Re-apply / restore live whenever the settings panel saves a new snapshot.
        [[NSNotificationCenter defaultCenter] addObserverForName:AxsGlassifyPreferencesChanged
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            [AxsGlassifyGlass axs_glassify_refreshAllWindows];
        }];
    }
}
