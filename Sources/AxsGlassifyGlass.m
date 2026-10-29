#import "AxsGlassifyGlass.h"
#import "AxsGlassifyConfig.h"
#import <objc/runtime.h>
#import <math.h>

// Stores each view's original blur effect so disabling restores the system look.
static const void *kAxsGlassifyOriginalEffectKey = &kAxsGlassifyOriginalEffectKey;

@implementation AxsGlassifyGlass

+ (BOOL)axs_glassify_enabled {
    return [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_isEnabled];
}

+ (double)axs_glassify_strength {
    id value = [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_valueForKey:@"strength" defaultValue:@(0.35)];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.35;
}

+ (BOOL)axs_glassify_forceDark {
    id value = [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_valueForKey:@"dark" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

+ (UIBlurEffectStyle)axs_glassify_styleForStrength:(double)strength dark:(BOOL)dark {
    // Map 0..1 strength onto the adaptive material family. Without the dark switch,
    // the *adaptive* styles follow the system light/dark appearance automatically.
    if (strength < 0.20) {
        return dark ? UIBlurEffectStyleSystemUltraThinMaterialDark : UIBlurEffectStyleSystemUltraThinMaterial;
    }
    if (strength < 0.45) {
        return dark ? UIBlurEffectStyleSystemThinMaterialDark : UIBlurEffectStyleSystemThinMaterial;
    }
    if (strength < 0.70) {
        return dark ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterial;
    }
    return dark ? UIBlurEffectStyleSystemThickMaterialDark : UIBlurEffectStyleSystemThickMaterial;
}

+ (UIBlurEffect *)axs_glassify_mappedEffect {
    double strength = [self axs_glassify_strength];
    if (!isfinite(strength)) strength = 0.35;
    strength = fmax(0.0, fmin(1.0, strength));
    UIBlurEffectStyle style = [self axs_glassify_styleForStrength:strength dark:[self axs_glassify_forceDark]];
    return [UIBlurEffect effectWithStyle:style];
}

+ (UIVisualEffect *)axs_glassify_transformIncoming:(UIVisualEffect *)effect
                                           forView:(UIVisualEffectView *)view {
    // Only blur effects are restyled; vibrancy and nil effects are left alone.
    if (![self axs_glassify_enabled] || ![effect isKindOfClass:[UIBlurEffect class]]) {
        return effect;
    }
    objc_setAssociatedObject(view, kAxsGlassifyOriginalEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return [self axs_glassify_mappedEffect];
}

+ (void)axs_glassify_refreshView:(UIView *)view {
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *effectView = (UIVisualEffectView *)view;
        UIVisualEffect *original = objc_getAssociatedObject(effectView, kAxsGlassifyOriginalEffectKey);
        UIVisualEffect *base = original ?: effectView.effect;
        if ([base isKindOfClass:[UIBlurEffect class]]) {
            if ([self axs_glassify_enabled]) {
                if (!original) {
                    objc_setAssociatedObject(effectView, kAxsGlassifyOriginalEffectKey, base,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                effectView.effect = [self axs_glassify_mappedEffect];
            } else if (original) {
                effectView.effect = original;
                objc_setAssociatedObject(effectView, kAxsGlassifyOriginalEffectKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    for (UIView *subview in view.subviews) {
        [self axs_glassify_refreshView:subview];
    }
}

+ (void)axs_glassify_refreshAllWindows {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [self axs_glassify_refreshView:window];
        }
    }
}

@end
