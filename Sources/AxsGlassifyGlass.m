#import "AxsGlassifyGlass.h"
#import <math.h>

// Tag identifies our overlay view and its tint subview so re-applying updates
// instead of stacking duplicate layers.
static const NSInteger kAxsGlassifyOverlayTag = 0x47534C59; // "GSLY"
static const NSInteger kAxsGlassifyTintTag = 0x47534C5A;    // "GSLZ"

@implementation AxsGlassifyGlass

+ (UIBlurEffectStyle)axs_glassify_styleForStrength:(double)strength dark:(BOOL)dark {
    // Map a 0..1 strength onto the system material family, from thinnest to thickest.
    if (strength < 0.20) {
        return dark ? UIBlurEffectStyleSystemUltraThinMaterialDark
                    : UIBlurEffectStyleSystemUltraThinMaterialLight;
    }
    if (strength < 0.45) {
        return dark ? UIBlurEffectStyleSystemThinMaterialDark
                    : UIBlurEffectStyleSystemThinMaterialLight;
    }
    if (strength < 0.70) {
        return dark ? UIBlurEffectStyleSystemMaterialDark
                    : UIBlurEffectStyleSystemMaterialLight;
    }
    return dark ? UIBlurEffectStyleSystemThickMaterialDark
                : UIBlurEffectStyleSystemThickMaterialLight;
}

+ (UIVisualEffectView *)axs_glassify_existingOverlayInWindow:(UIWindow *)window {
    for (UIView *subview in window.subviews) {
        if (subview.tag == kAxsGlassifyOverlayTag && [subview isKindOfClass:[UIVisualEffectView class]]) {
            return (UIVisualEffectView *)subview;
        }
    }
    return nil;
}

+ (void)axs_glassify_updateGlassInWindow:(UIWindow *)window
                                 enabled:(BOOL)enabled
                                strength:(double)strength
                                    dark:(BOOL)dark {
    if (!window) {
        return;
    }

    UIVisualEffectView *overlay = [self axs_glassify_existingOverlayInWindow:window];

    if (!enabled) {
        [overlay removeFromSuperview];
        return;
    }

    if (!isfinite(strength)) {
        strength = 0.35;
    }
    strength = fmax(0.0, fmin(1.0, strength));

    UIBlurEffectStyle style = [self axs_glassify_styleForStrength:strength dark:dark];

    if (!overlay) {
        overlay = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
        overlay.tag = kAxsGlassifyOverlayTag;
        // Never intercept touches: the glass is a visual filter only.
        overlay.userInteractionEnabled = NO;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // A translucent tint on top of the blur gives the "glass" its colour cast.
        UIView *tint = [[UIView alloc] init];
        tint.tag = kAxsGlassifyTintTag;
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [overlay.contentView addSubview:tint];

        [window addSubview:overlay];
    } else {
        overlay.effect = [UIBlurEffect effectWithStyle:style];
    }

    overlay.frame = window.bounds;

    UIView *tint = [overlay.contentView viewWithTag:kAxsGlassifyTintTag];
    tint.frame = overlay.bounds;
    tint.backgroundColor = dark ? [UIColor colorWithWhite:0.0 alpha:0.15]
                                : [UIColor colorWithWhite:1.0 alpha:0.10];
}

@end
