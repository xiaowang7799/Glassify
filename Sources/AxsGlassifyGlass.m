#import "AxsGlassifyGlass.h"
#import "AxsGlassifyConfig.h"
#import <CoreMotion/CoreMotion.h>
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
    if ([NSStringFromClass([view class]) containsString:@"BackdropView"]) {
        [self axs_glassify_decorateBackdropView:view];
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

static NSString * const kAxsGlassifyRimName = @"AxsGlassifyRim";

// 高光层弱引用表：姿态变化时只遍历几十个 layer，不用扫整个窗口树。
static NSHashTable *axs_glassify_rim_registry(void) {
    static NSHashTable *registry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registry = [NSHashTable weakObjectsHashTable];
    });
    return registry;
}

static CMMotionManager *axs_glassify_motion_manager(void) {
    static CMMotionManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[CMMotionManager alloc] init];
        // 10 Hz 对高光位移完全够用，也避开了 60 Hz 的耗电。
        manager.deviceMotionUpdateInterval = 0.1;
    });
    return manager;
}

static void axs_glassify_applyGravity(CGPoint gravity) {
    // gravity.y = -1 是竖直握持，此时亮边在顶部；横向倾斜时亮边跟着左右移动。
    CGFloat sx = fmax(0.0, fmin(1.0, 0.5 + gravity.x * 0.45));
    CGFloat sy = fmax(0.0, fmin(1.0, 0.5 + gravity.y * 0.45));
    CGPoint start = CGPointMake(sx, sy);
    CGPoint end = CGPointMake(1.0 - sx, 1.0 - sy);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CAGradientLayer *rim in [axs_glassify_rim_registry() allObjects]) {
        rim.startPoint = start;
        rim.endPoint = end;
    }
    [CATransaction commit];
}

+ (void)axs_glassify_removeRimFromView:(UIView *)view {
    for (CALayer *layer in [view.layer.sublayers copy]) {
        if ([layer.name isEqualToString:kAxsGlassifyRimName]) {
            [axs_glassify_rim_registry() removeObject:layer];
            [layer removeFromSuperlayer];
        }
    }
}

+ (void)axs_glassify_decorateBackdropView:(UIView *)view {
    if (![self axs_glassify_enabled]) {
        [self axs_glassify_removeRimFromView:view];
        return;
    }
    CGSize size = view.bounds.size;
    CGFloat radius = view.layer.cornerRadius;
    // Only rounded, reasonably large surfaces get the specular rim; tiny or
    // unrounded backdrops look wrong with a border.
    if (size.width < 70.0 || size.height < 40.0 || radius < 6.0) {
        [self axs_glassify_removeRimFromView:view];
        return;
    }
    CAGradientLayer *rim = nil;
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer.name isEqualToString:kAxsGlassifyRimName] &&
            [layer isKindOfClass:[CAGradientLayer class]]) {
            rim = (CAGradientLayer *)layer;
            break;
        }
    }
    if (!rim) {
        rim = [CAGradientLayer layer];
        rim.name = kAxsGlassifyRimName;
        // 45-degree white highlight, fading out along the edge (reference-style).
        // LuCI tokens: border rgba(255,255,255,.8) + inset rgba(255,255,255,.95).
        rim.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.80].CGColor,
                       (id)[UIColor colorWithWhite:1.0 alpha:0.25].CGColor,
                       (id)[UIColor clearColor].CGColor];
        rim.locations = @[@0.0, @0.40, @1.0];
        rim.startPoint = CGPointMake(0.0, 0.0);
        rim.endPoint = CGPointMake(1.0, 1.0);
        rim.zPosition = 1000.0;
        CAShapeLayer *mask = [CAShapeLayer layer];
        mask.fillColor = nil;
        mask.strokeColor = [UIColor whiteColor].CGColor;
        mask.lineWidth = 1.2;
        rim.mask = mask;
        [view.layer addSublayer:rim];
        [axs_glassify_rim_registry() addObject:rim];
        if (axs_glassify_rim_registry().count == 1) {
            [self axs_glassify_syncMotionHighlight];
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    rim.frame = view.bounds;
    CAShapeLayer *mask = (CAShapeLayer *)rim.mask;
    CGRect rect = CGRectInset(view.bounds, 0.6, 0.6);
    mask.path = [UIBezierPath bezierPathWithRoundedRect:rect
                                           cornerRadius:MAX(0.0, radius - 0.6)].CGPath;
    [CATransaction commit];
}

#pragma mark - 动态高光

+ (void)axs_glassify_syncMotionHighlight {
    id value = [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_valueForKey:@"motion_highlight"
                                                                   defaultValue:@(YES)];
    BOOL motionOn = [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
    CMMotionManager *manager = axs_glassify_motion_manager();
    // 没有高光层（或功能关闭）就停表，不白白占着传感器。
    BOOL shouldRun = [self axs_glassify_enabled] && motionOn &&
                     axs_glassify_rim_registry().count > 0 && manager.deviceMotionAvailable;
    if (shouldRun && !manager.deviceMotionActive) {
        // 弱引用：CMMotionManager 会持有 handler，强引用会成环。
        __weak CMMotionManager *weakManager = manager;
        [manager startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue]
                                    withHandler:^(CMDeviceMotion *motion, NSError *error) {
            // 高光层全都没了（页面被拆）→ 自动停表，避免常驻采样。
            if (axs_glassify_rim_registry().count == 0) {
                [weakManager stopDeviceMotionUpdates];
                return;
            }
            if (!motion) return;
            CMAcceleration gravity = motion.gravity;
            axs_glassify_applyGravity(CGPointMake(gravity.x, gravity.y));
        }];
    } else if (!shouldRun && manager.deviceMotionActive) {
        [manager stopDeviceMotionUpdates];
    }
}

@end
