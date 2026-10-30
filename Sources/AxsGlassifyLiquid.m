#import "AxsGlassifyLiquid.h"
#import "AxsGlassifyConfig.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

NSString * const AxsGlassifyPlatterGlassChanged = @"com.axs.glassify.platter-glass-changed";

static const void *kAxsGlassifyPlatterStateKey = &kAxsGlassifyPlatterStateKey;
static NSString * const kAxsGlassifyPlatterHighlightName = @"AxsGlassifyPlatterHighlight";
static NSString * const kAxsGlassifyPlatterFringeName = @"AxsGlassifyPlatterFringe";

@interface AxsGlassifyPlatterState : NSObject
@property (nonatomic, strong) UIVisualEffectView *glassView;
@property (nonatomic, weak) UIView *backgroundHost;
@property (nonatomic, copy) NSArray<UIView *> *suppressedViews;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) CGSize lastBoundsSize;
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

// 通知圆角由「锁屏通知 · 外观」里的 corner_radius 统一决定：玻璃层和渐变层读同一个键，
// 不会再出现两层各自用不同半径。
static double axs_glassify_liquid_cornerRadius(void) {
    id value = [[AxsGlassifyConfig axs_glassify_shared] axs_glassify_valueForKey:@"corner_radius"
                                                                   defaultValue:@(0)];
    double radius = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.0;
    if (!isfinite(radius) || radius < 0.5) {
        return 0.0;
    }
    return fmax(0.0, fmin(60.0, radius));
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

// Notification platters draw their own material through MaterialKit: the card is an
// MTTitledPlatterView and the background is an MTMaterialView (or a plain
// _UIBackdropView on older builds). Both are matched by class name, and only when
// the view covers (almost) the whole platter so button-sized materials survive.
static UIView *axs_glassify_find_material_view(UIView *root, UIView *view, UIView *skip,
                                               NSUInteger depth) {
    if (depth > 4) {
        return nil;
    }
    CGRect target = root.bounds;
    for (UIView *subview in view.subviews) {
        if (skip && (subview == skip || [subview isDescendantOfView:skip])) {
            continue;
        }
        NSString *name = NSStringFromClass([subview class]);
        BOOL matches = [name rangeOfString:@"Backdrop"].location != NSNotFound ||
                       [name rangeOfString:@"Material"].location != NSNotFound ||
                       [name rangeOfString:@"Background"].location != NSNotFound;
        if (matches && subview.alpha > 0.99) {
            CGRect frame = [root convertRect:subview.bounds fromView:subview];
            if (CGRectGetWidth(frame) >= CGRectGetWidth(target) * 0.9 &&
                CGRectGetHeight(frame) >= CGRectGetHeight(target) * 0.9) {
                return subview;
            }
        }
        UIView *found = axs_glassify_find_material_view(root, subview, skip, depth + 1);
        if (found) {
            return found;
        }
    }
    return nil;
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

+ (BOOL)axs_glassify_isGlassView:(UIView *)view {
    if (!view) {
        return NO;
    }
    return [objc_getAssociatedObject(view, kAxsGlassifyPlatterStateKey) boolValue];
}

+ (UIView *)axs_glassify_glassContentViewForPlatter:(UIView *)platter {
    if (!platter) {
        return nil;
    }
    AxsGlassifyPlatterState *state = objc_getAssociatedObject(platter, kAxsGlassifyPlatterStateKey);
    UIVisualEffectView *glass = state.glassView;
    if (!glass || glass.superview != platter) {
        return nil;
    }
    return glass.contentView;
}

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

    [self axs_glassify_suppressBackgroundForPlatter:platter state:state];
    CGFloat radius = [self axs_glassify_cornerRadiusForPlatter:platter state:state];

    double strength = axs_glassify_liquid_strength();
    BOOL dark = axs_glassify_liquid_dark();

    UIVisualEffectView *glass = state.glassView;
    if (!glass) {
        glass = [[UIVisualEffectView alloc] initWithEffect:nil];
        glass.userInteractionEnabled = NO;
        glass.clipsToBounds = YES;
        // 标记自己，动画引擎找背景层时要跳过它。
        objc_setAssociatedObject(glass, kAxsGlassifyPlatterStateKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // Behind the label/icon content, in front of the (now hidden) backdrop.
        [platter insertSubview:glass atIndex:0];
        state.glassView = glass;
        // 渐变层要重新挂到 contentView（玻璃之上、文字之下）。
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsGlassifyPlatterGlassChanged
                                                            object:platter];
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

    // 布局和圆角都没变就跳过：滚动时 -layoutSubviews 触发非常频繁。
    BOOL geometryChanged = !CGSizeEqualToSize(state.lastBoundsSize, bounds.size) ||
                           fabs(state.cornerRadius - radius) > 0.5;
    if (geometryChanged) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        glass.frame = bounds;
        glass.layer.cornerRadius = radius;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.layer.masksToBounds = YES;
        [CATransaction commit];

        state.cornerRadius = radius;
        state.lastBoundsSize = bounds.size;
        [self axs_glassify_decorateGlassView:glass radius:radius];
    }

    [axs_glassify_platter_registry() addObject:platter];
    state.updating = NO;
}

+ (void)axs_glassify_suppressBackgroundForPlatter:(UIView *)platter
                                            state:(AxsGlassifyPlatterState *)state {
    if (state.backgroundHost) {
        return;
    }
    UIView *host = axs_glassify_find_material_view(platter, platter, state.glassView, 0);
    if (!host) {
        // The platter may paint its material itself; the glass panel still covers
        // it, it just keeps the system tint underneath.
        return;
    }
    state.backgroundHost = host;
    // Only hide surfaces that are currently fully visible; restoring them is then
    // just alpha = 1.
    if (host.alpha > 0.99) {
        host.alpha = 0.0;
        state.suppressedViews = @[host];
    }
}

+ (CGFloat)axs_glassify_cornerRadiusForPlatter:(UIView *)platter
                                         state:(AxsGlassifyPlatterState *)state {
    double preferred = axs_glassify_liquid_cornerRadius();
    if (preferred > 0.5) {
        return (CGFloat)preferred;
    }
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

#pragma mark - 已有模糊面的装饰（控制中心 / 文件夹 / Dock）

// 用一个圆角矩形 mask 让装饰层只画在圆角内（不依赖视图自己的 masksToBounds）。
static CAShapeLayer *axs_glassify_rounded_mask(CALayer *owner) {
    if ([owner.mask isKindOfClass:[CAShapeLayer class]]) {
        return (CAShapeLayer *)owner.mask;
    }
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.fillColor = [UIColor whiteColor].CGColor;
    owner.mask = mask;
    return mask;
}

+ (void)axs_glassify_decorateLiquidSurface:(UIView *)view radius:(CGFloat)radius {
    if (!view || radius < 6.0) {
        return;
    }
    CALayer *host = view.layer;
    CGRect bounds = view.bounds;
    if (!host || bounds.size.width < 70.0 || bounds.size.height < 40.0) {
        return;
    }

    CAGradientLayer *highlight = axs_glassify_gradient_layer(host, kAxsGlassifyPlatterHighlightName);
    CAGradientLayer *fringe = axs_glassify_gradient_layer(host, kAxsGlassifyPlatterFringeName);
    if (!highlight || !fringe) {
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    highlight.frame = CGRectMake(0.0, 0.0, bounds.size.width, bounds.size.height * 0.55);
    highlight.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.20].CGColor,
                         (id)[UIColor colorWithWhite:1.0 alpha:0.04].CGColor,
                         (id)[UIColor clearColor].CGColor];
    highlight.locations = @[@0.0, @0.45, @1.0];
    highlight.startPoint = CGPointMake(0.5, 0.0);
    highlight.endPoint = CGPointMake(0.5, 1.0);
    highlight.zPosition = 997.0;
    axs_glassify_rounded_mask(highlight).path =
        [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius].CGPath;

    fringe.frame = bounds;
    fringe.colors = @[(id)[UIColor colorWithRed:0.35 green:0.85 blue:1.0 alpha:0.08].CGColor,
                      (id)[UIColor clearColor].CGColor,
                      (id)[UIColor clearColor].CGColor,
                      (id)[UIColor colorWithRed:1.0 green:0.45 blue:0.85 alpha:0.08].CGColor];
    fringe.locations = @[@0.0, @0.05, @0.95, @1.0];
    fringe.startPoint = CGPointMake(0.0, 0.5);
    fringe.endPoint = CGPointMake(1.0, 0.5);
    fringe.zPosition = 996.0;
    axs_glassify_rounded_mask(fringe).path =
        [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius].CGPath;

    [CATransaction commit];
}

+ (void)axs_glassify_removeLiquidSurfaceDecoration:(UIView *)view {
    for (CALayer *layer in [view.layer.sublayers copy]) {
        if ([layer.name isEqualToString:kAxsGlassifyPlatterHighlightName] ||
            [layer.name isEqualToString:kAxsGlassifyPlatterFringeName]) {
            [layer removeFromSuperlayer];
        }
    }
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
    state.backgroundHost = nil;
    [state.glassView removeFromSuperview];
    state.glassView = nil;
    objc_setAssociatedObject(platter, kAxsGlassifyPlatterStateKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [axs_glassify_platter_registry() removeObject:platter];
    // 玻璃拆掉后渐变层需要退回系统材质那一层，否则会跟着 contentView 一起消失。
    [[NSNotificationCenter defaultCenter] postNotificationName:AxsGlassifyPlatterGlassChanged
                                                        object:platter];
}

+ (void)axs_glassify_refreshPlatters {
    NSArray *platters = [axs_glassify_platter_registry() allObjects];
    for (UIView *platter in platters) {
        [self axs_glassify_applyToPlatter:platter];
    }
}

@end
