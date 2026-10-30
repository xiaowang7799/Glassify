#import "AxsGlassifyLiquid.h"
#import "AxsGlassifyConfig.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const void *kAxsGlassifyPlatterStateKey = &kAxsGlassifyPlatterStateKey;
static NSString * const kAxsGlassifyPlatterHighlightName = @"AxsGlassifyPlatterHighlight";
static NSString * const kAxsGlassifyPlatterFringeName = @"AxsGlassifyPlatterFringe";

@interface AxsGlassifyPlatterState : NSObject
@property (nonatomic, strong) UIVisualEffectView *glassView;
@property (nonatomic, copy) NSArray<UIView *> *suppressedViews;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) double appliedStrength;
@property (nonatomic, assign) BOOL appliedDark;
@property (nonatomic, assign) BOOL updating;
@end

@implementation AxsGlassifyPlatterState
@end

#pragma mark - Preferences

static double axs_glassify_liquid_strength(void) {
    id value = [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_valueForKey:@"strength"
                                                                   defaultValue:@(0.35)];
    double strength = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.35;
    if (!isfinite(strength)) {
        strength = 0.35;
    }
    return fmax(0.0, fmin(1.0, strength));
}

static BOOL axs_glassify_liquid_dark(void) {
    id value = [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_valueForKey:@"dark"
                                                                   defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

static BOOL axs_glassify_liquid_notificationsEnabled(void) {
    id value = [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_valueForKey:@"notifications"
                                                                   defaultValue:@(YES)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

#pragma mark - Runtime helpers

static BOOL axs_glassify_class_name_contains(UIView *view, NSString *needle) {
    NSString *name = NSStringFromClass([view class]);
    return name && [name rangeOfString:needle].location != NSNotFound;
}

// Weak registry so a settings change can re-apply the material to platters that
// are already on screen without keeping them alive.
static NSHashTable *axs_glassify_platter_registry(void) {
    static NSHashTable *registry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registry = [NSHashTable weakObjectsHashTable];
    });
    return registry;
}

static CAGradientLayer *axs_glassify_gradient_layer(CALayer *host, NSString *name) {
    for (CALayer *layer in host.sublayers) {
        if ([layer.name isEqualToString:name] && [layer isKindOfClass:[CAGradientLayer class]]) {
            return (CAGradientLayer *)layer;
        }
    }
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.name = name;
    [host addSublayer:gradient];
    return gradient;
}

@implementation AxsGlassifyLiquid

#pragma mark - Material

+ (BOOL)axs_glassify_hasSystemGlass {
    static BOOL available = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        available = (NSClassFromString(@"UIGlassEffect") != nil);
    });
    return available;
}

// UIGlassEffect only exists in the iOS 26 SDK, which this tweak does not build
// against, so the whole class is driven through the runtime.
+ (UIVisualEffect *)axs_glassify_systemGlassEffectWithStrength:(double)strength dark:(BOOL)dark {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass) {
        return nil;
    }

    id effect = nil;
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    if ([glassClass respondsToSelector:styleSelector]) {
        // UIGlassEffectStyleRegular == 0, clear == 1.
        typedef id (*AxsGlassEffectWithStyle)(id, SEL, NSInteger);
        AxsGlassEffectWithStyle call = (AxsGlassEffectWithStyle)objc_msgSend;
        effect = call((id)glassClass, styleSelector, (NSInteger)0);
    }
    if (!effect) {
        effect = [[glassClass alloc] init];
    }
    if (!effect) {
        return nil;
    }

    // Interactive glass adds hover/press response meant for tappable controls;
    // notification platters slide instead, so keep it off.
    SEL interactiveSelector = NSSelectorFromString(@"setInteractive:");
    if ([effect respondsToSelector:interactiveSelector]) {
        typedef void (*AxsGlassSetInteractive)(id, SEL, BOOL);
        ((AxsGlassSetInteractive)objc_msgSend)(effect, interactiveSelector, NO);
    }

    SEL tintSelector = NSSelectorFromString(@"setTintColor:");
    if ([effect respondsToSelector:tintSelector]) {
        CGFloat white = dark ? 0.0 : 1.0;
        UIColor *tint = [UIColor colorWithWhite:white alpha:0.04 + strength * 0.10];
        typedef void (*AxsGlassSetTint)(id, SEL, id);
        ((AxsGlassSetTint)objc_msgSend)(effect, tintSelector, tint);
    }

    return (UIVisualEffect *)effect;
}

+ (UIVisualEffect *)axs_glassify_platterEffectWithStrength:(double)strength dark:(BOOL)dark {
    UIVisualEffect *system = [self axs_glassify_systemGlassEffectWithStrength:strength dark:dark];
    if (system) {
        return system;
    }
    // Pre-iOS 26 fallback: chrome material is what UIKit itself uses for platters.
    UIBlurEffectStyle style = dark ? UIBlurEffectStyleSystemChromeMaterialDark
                                   : UIBlurEffectStyleSystemChromeMaterial;
    return [UIBlurEffect effectWithStyle:style];
}

#pragma mark - Platter handling

+ (void)axs_glassify_applyToPlatter:(UIView *)platter {
    if (!platter) {
        return;
    }
    // Guards against a leaked hook (e.g. an inherited -layoutSubviews) styling
    // unrelated table cells.
    if (!axs_glassify_class_name_contains(platter, @"Notification") &&
        !axs_glassify_class_name_contains(platter, @"Platter") &&
        !axs_glassify_class_name_contains(platter, @"ShortLook")) {
        return;
    }

    if (![[AxsGlassifyConfig axs_glassify_shared] axs_glassify_isEnabled] ||
        !axs_glassify_liquid_notificationsEnabled()) {
        [self axs_glassify_removeFromPlatter:platter];
        return;
    }

    AxsGlassifyPlatterState *state = objc_getAssociatedObject(platter, kAxsGlassifyPlatterStateKey);
    if (state.updating) {
        return;
    }

    CGRect bounds = platter.bounds;
    if (bounds.size.width < 120.0 || bounds.size.height < 30.0) {
        // Not laid out yet, or not a notification card.
        return;
    }

    if (!state) {
        state = [AxsGlassifyPlatterState new];
        objc_setAssociatedObject(platter, kAxsGlassifyPlatterStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    state.updating = YES;

    [self axs_glassify_suppressBackdropsOnPlatter:platter state:state];
    CGFloat radius = [self axs_glassify_cornerRadiusForPlatter:platter state:state];

    double strength = axs_glassify_liquid_strength();
    BOOL dark = axs_glassify_liquid_dark();

    UIVisualEffectView *glass = state.glassView;
    if (!glass) {
        glass = [[UIVisualEffectView alloc] initWithEffect:nil];
        glass.userInteractionEnabled = NO;
        glass.clipsToBounds = YES;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // Behind the label/icon content, in front of the (now hidden) backdrop.
        [platter insertSubview:glass atIndex:0];
        state.glassView = glass;
    }
    if (!glass) {
        state.updating = NO;
        return;
    }

    if (glass.superview != platter) {
        [platter insertSubview:glass atIndex:0];
    }

    // Rebuilding the effect is expensive; only do it when the inputs changed.
    if (!glass.effect ||
        fabs(state.appliedStrength - strength) > 0.001 ||
        state.appliedDark != dark) {
        glass.effect = [self axs_glassify_platterEffectWithStrength:strength dark:dark];
        state.appliedStrength = strength;
        state.appliedDark = dark;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    glass.frame = bounds;
    glass.layer.cornerRadius = radius;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [CATransaction commit];

    state.cornerRadius = radius;
    [self axs_glassify_decorateGlassView:glass radius:radius];

    [axs_glassify_platter_registry() addObject:platter];
    state.updating = NO;
}

+ (void)axs_glassify_suppressBackdropsOnPlatter:(UIView *)platter
                                          state:(AxsGlassifyPlatterState *)state {
    if (state.suppressedViews) {
        return;
    }
    NSMutableArray<UIView *> *suppressed = [NSMutableArray array];
    for (UIView *subview in platter.subviews) {
        if (subview == state.glassView) {
            continue;
        }
        if (!axs_glassify_class_name_contains(subview, @"Backdrop")) {
            continue;
        }
        // Only hide surfaces that are currently fully visible; restoring them is
        // then just alpha = 1.
        if (subview.alpha > 0.99) {
            subview.alpha = 0.0;
            [suppressed addObject:subview];
        }
    }
    state.suppressedViews = suppressed;
}

+ (CGFloat)axs_glassify_cornerRadiusForPlatter:(UIView *)platter
                                         state:(AxsGlassifyPlatterState *)state {
    CGFloat radius = platter.layer.cornerRadius;
    for (UIView *view in state.suppressedViews) {
        if (view.layer.cornerRadius > radius) {
            radius = view.layer.cornerRadius;
        }
    }
    // Notification cards are strongly rounded; a square fallback looks broken.
    if (radius < 6.0) {
        radius = 22.0;
    }
    return radius;
}

#pragma mark - Decoration

+ (void)axs_glassify_decorateGlassView:(UIVisualEffectView *)glass radius:(CGFloat)radius {
    CALayer *host = glass.contentView.layer;
    if (!host) {
        return;
    }
    CGRect bounds = glass.bounds;
    if (bounds.size.width < 1.0 || bounds.size.height < 1.0) {
        return;
    }

    CAGradientLayer *highlight = axs_glassify_gradient_layer(host, kAxsGlassifyPlatterHighlightName);
    CAGradientLayer *fringe = axs_glassify_gradient_layer(host, kAxsGlassifyPlatterFringeName);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    // Milky top edge: the light that a real glass slab gathers along its bevel.
    highlight.frame = CGRectMake(0.0, 0.0, bounds.size.width, bounds.size.height * 0.55);
    highlight.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.22].CGColor,
                         (id)[UIColor colorWithWhite:1.0 alpha:0.05].CGColor,
                         (id)[UIColor clearColor].CGColor];
    highlight.locations = @[@0.0, @0.45, @1.0];
    highlight.startPoint = CGPointMake(0.5, 0.0);
    highlight.endPoint = CGPointMake(0.5, 1.0);
    highlight.cornerRadius = radius;
    highlight.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    highlight.masksToBounds = YES;
    highlight.zPosition = 999.0;

    // Slight colour separation at the left/right edges (glass thickness).
    fringe.frame = bounds;
    fringe.colors = @[(id)[UIColor colorWithRed:0.35 green:0.85 blue:1.0 alpha:0.10].CGColor,
                      (id)[UIColor clearColor].CGColor,
                      (id)[UIColor clearColor].CGColor,
                      (id)[UIColor colorWithRed:1.0 green:0.45 blue:0.85 alpha:0.10].CGColor];
    fringe.locations = @[@0.0, @0.05, @0.95, @1.0];
    fringe.startPoint = CGPointMake(0.0, 0.5);
    fringe.endPoint = CGPointMake(1.0, 0.5);
    fringe.cornerRadius = radius;
    fringe.masksToBounds = YES;
    fringe.zPosition = 998.0;

    [CATransaction commit];
}

#pragma mark - Teardown

+ (void)axs_glassify_removeFromPlatter:(UIView *)platter {
    if (!platter) {
        return;
    }
    AxsGlassifyPlatterState *state = objc_getAssociatedObject(platter, kAxsGlassifyPlatterStateKey);
    if (!state) {
        return;
    }
    for (UIView *view in state.suppressedViews) {
        view.alpha = 1.0;
    }
    state.suppressedViews = nil;
    [state.glassView removeFromSuperview];
    state.glassView = nil;
    objc_setAssociatedObject(platter, kAxsGlassifyPlatterStateKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [axs_glassify_platter_registry() removeObject:platter];
}

+ (void)axs_glassify_refreshPlatters {
    NSArray *platters = [axs_glassify_platter_registry() allObjects];
    for (UIView *platter in platters) {
        [self axs_glassify_applyToPlatter:platter];
    }
}

@end
