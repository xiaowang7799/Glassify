#import "AxsGlassifySBezierCurve.h"
#import "AxsGlassifyNotifyConfig.h"
#import "AxsGlassifyPreferences.h"
#import "AxsGlassifySBezier.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>

// Per-view state. Keeping it in one small integer lets a layout pass bail out
// with a single associated-object read instead of walking the hierarchy.
enum {
    axs_glassify_sbez_stateUnprocessed = 0,
    axs_glassify_sbez_stateClaimed = 1,   // this view owns the decoration
    axs_glassify_sbez_stateRejected = 2,  // an ancestor owns it; never look again
};

// Decoration state lives on the view, so banners never share a layer or observer.
static const char axs_glassify_sbez_keyState = 0;
static const char axs_glassify_sbez_keyLayer = 0;
static const char axs_glassify_sbez_keyObserver = 0;
static const char axs_glassify_sbez_keyLastSize = 0;
static const char axs_glassify_sbez_keyLastStyle = 0;
// Set when the panel writes new values, so a steady layout pass can skip the
// config reads (and the boxed-default allocations they need) entirely.
static const char axs_glassify_sbez_keyDirty = 0;

// Kept in step with the `default` values in AxsGlassifySBezierRoot.plist.
static const CGFloat axs_glassify_sbez_defaultAmplitude = 24.0;
static const CGFloat axs_glassify_sbez_defaultFrequency = 2.0;
static const CGFloat axs_glassify_sbez_defaultWidth = 3.0;
static const CGFloat axs_glassify_sbez_defaultOpacity = 0.45;
static const CGFloat axs_glassify_sbez_defaultHue = 0.60;
static const CGFloat axs_glassify_sbez_defaultDuration = 0.90;

// Missing key, wrong type and non finite values all fall back to the same default
// used by the preference panel, so a stale file cannot skew the geometry.
static CGFloat axs_glassify_sbez_configValue(NSString *key, CGFloat fallback) {
    return (CGFloat)[[AxsGlassifyNotifyConfig axs_glassify_notify_shared]
                     axs_glassify_notify_sbezDoubleForKey:key defaultValue:(double)fallback];
}

// 横幅侧现在是**两个独立功能**（6.7.0 拆分，之前共用一个开关）：
//
//   1. S 形入场轨迹 = transform 动画，`sbz_entrance_enabled`
//   2. S 形装饰曲线 = 画出来的那条线，`sbz_decoration_enabled`（+ `sbz_decoration_style`
//      决定它进场后常驻还是淡出）
//
// 两者几何上本来就不是同一个 S：轨迹是 x(时间)，装饰线是 y(横向位置)，
// 只是看起来像。拆开后用户可以只要轨迹、只要线、或两个都要。
//
// entranceActive 是**共享**谓词（玻璃侧也查它）：轨迹开着时它独占整条 transform，
// 出现动画必须让位。decoActive 只管画线，与 transform 无关，不影响出现动画。
static BOOL axs_glassify_sbez_entranceActive(void) {
    return [[AxsGlassifyNotifyConfig axs_glassify_notify_shared] axs_glassify_notify_sbezEntranceActive];
}

static BOOL axs_glassify_sbez_decoActive(void) {
    return [[AxsGlassifyNotifyConfig axs_glassify_notify_shared] axs_glassify_notify_sbezDecoActive];
}

// 装饰曲线进场后是否淡出（style 1），而不是常驻（style 0）。
static BOOL axs_glassify_sbez_decoFades(void) {
    return [[AxsGlassifyNotifyConfig axs_glassify_notify_shared] axs_glassify_notify_sbezDecoFadeStyle];
}

// 认领横幅的判断：两个功能任意一个要画，这个 view 才需要接管装饰层。
static BOOL axs_glassify_sbez_bannerAnyActive(void) {
    return axs_glassify_sbez_entranceActive() || axs_glassify_sbez_decoActive();
}

// One number standing for every input that affects the drawing, so an unchanged
// layout pass can be detected without rebuilding the path.
static NSUInteger axs_glassify_sbez_styleSignature(BOOL enabled, CGFloat amplitude, CGFloat frequency,
                                                 CGFloat phase, CGFloat width, CGFloat opacity,
                                                 CGFloat hue, BOOL fade) {
    float inputs[6] = {(float)amplitude, (float)frequency, (float)phase,
                       (float)width, (float)opacity, (float)hue};
    uint32_t parts[8];
    parts[0] = enabled ? 1u : 0u;
    for (NSInteger i = 0; i < 6; i++) {
        union { float f; uint32_t u; } cast;
        cast.f = inputs[i];
        parts[i + 1] = cast.u;
    }
    parts[7] = fade ? 1u : 0u;
    uint64_t hash = 1469598103934665603ULL;
    for (NSInteger i = 0; i < 8; i++) {
        hash ^= parts[i];
        hash *= 1099511628211ULL;
    }
    return (NSUInteger)hash;
}

// A nested banner (a long look containing a short look) must not animate twice,
// so an inner view defers to an ancestor that already claimed the decoration.
// Each view runs this at most once: the verdict is cached as claim or reject.
static BOOL axs_glassify_sbez_hasClaimedAncestor(UIView *view) {
    for (UIView *parent = view.superview; parent != nil; parent = parent.superview) {
        NSNumber *state = objc_getAssociatedObject(parent, &axs_glassify_sbez_keyState);
        if (state != nil && state.integerValue == axs_glassify_sbez_stateClaimed) {
            return YES;
        }
    }
    return NO;
}

@implementation UIView (AxsGlassifySBezier)

- (void)axs_glassify_sbez_applyEntranceIfNeeded {
    NSNumber *state = objc_getAssociatedObject(self, &axs_glassify_sbez_keyState);
    NSInteger current = state != nil ? state.integerValue : axs_glassify_sbez_stateUnprocessed;

    if (current == axs_glassify_sbez_stateRejected) {
        return;
    }
    if (current == axs_glassify_sbez_stateClaimed) {
        // refreshDecoration compares size and values first, so an ordinary layout
        // pass costs two associated-object reads and nothing else.
        [self axs_glassify_sbez_refreshDecoration];
        return;
    }

    // Cheap gates before anything hierarchical: no config beyond the shared
    // snapshot, no traversal. 装饰线开关也参与认领：只开线、不开轨迹时同样要有
    // 一个 view 持有装饰层。
    if (!axs_glassify_sbez_bannerAnyActive()) {
        return;
    }
    if (self.window == nil || self.superview == nil) {
        return;
    }
    CGSize size = self.bounds.size;
    if (size.width < 1.0f || size.height < 1.0f) {
        return;
    }
    if (axs_glassify_sbez_hasClaimedAncestor(self)) {
        objc_setAssociatedObject(self, &axs_glassify_sbez_keyState,
                                 @(axs_glassify_sbez_stateRejected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // Claim before the async hop so repeated layout passes cannot queue twice and
    // an inner banner sees the claim immediately.
    objc_setAssociatedObject(self, &axs_glassify_sbez_keyState,
                             @(axs_glassify_sbez_stateClaimed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view = weakSelf;
        if (view == nil) {
            return;
        }
        // 认领时总是装好装饰层与配置观察者：线是否真画由 refreshDecoration 里的
        // decoActive 决定。这样「先只开轨迹、后开装饰线」也能实时生效，不必等
        // 下一条通知重新认领。轨迹与线各自独立：装层不等于播 transform 动画。
        [view axs_glassify_sbez_installDecoration];
        [view axs_glassify_sbez_animateEntrance];
    });
}

- (void)axs_glassify_sbez_installDecoration {
    CAShapeLayer *layer = objc_getAssociatedObject(self, &axs_glassify_sbez_keyLayer);
    if (layer == nil) {
        layer = [CAShapeLayer layer];
        layer.name = @"AxsGlassifySBezierDecoration";
        // An explicit transaction keeps the very first property writes from
        // fading in over the default 0.25s implicit animation.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.fillColor = NULL;
        layer.lineCap = kCALineCapRound;
        layer.lineJoin = kCALineJoinRound;
        [CATransaction commit];
        objc_setAssociatedObject(self, &axs_glassify_sbez_keyLayer, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.layer addSublayer:layer];
    }
    [self axs_glassify_sbez_refreshDecoration];

    if (objc_getAssociatedObject(self, &axs_glassify_sbez_keyObserver) == nil) {
        __weak UIView *weakSelf = self;
        id token = [[NSNotificationCenter defaultCenter]
                    addObserverForName:AxsGlassifyPreferencesChanged
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
            UIView *view = weakSelf;
            if (view != nil) {
                objc_setAssociatedObject(view, &axs_glassify_sbez_keyDirty, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [view axs_glassify_sbez_refreshDecoration];
            }
        }];
        objc_setAssociatedObject(self, &axs_glassify_sbez_keyObserver, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)axs_glassify_sbez_refreshDecoration {
    CAShapeLayer *layer = objc_getAssociatedObject(self, &axs_glassify_sbez_keyLayer);
    if (layer == nil) {
        return;
    }

    CGSize size = self.bounds.size;
    NSValue *lastSize = objc_getAssociatedObject(self, &axs_glassify_sbez_keyLastSize);
    NSNumber *lastStyle = objc_getAssociatedObject(self, &axs_glassify_sbez_keyLastStyle);
    BOOL dirty = [objc_getAssociatedObject(self, &axs_glassify_sbez_keyDirty) boolValue];
    if (!dirty && lastSize != nil && lastStyle != nil
        && CGSizeEqualToSize(lastSize.CGSizeValue, size)) {
        // Steady state: three associated reads and a size compare, nothing else.
        return;
    }

    // 装饰线由自己的开关决定，不再跟 S 轨迹共用；fade 决定进场后常驻还是淡出。
    BOOL enabled = axs_glassify_sbez_decoActive();
    BOOL fade = axs_glassify_sbez_decoFades();
    CGFloat amplitude = axs_glassify_sbez_configValue(@"sbz_amplitude", axs_glassify_sbez_defaultAmplitude);
    CGFloat frequency = axs_glassify_sbez_configValue(@"sbz_frequency", axs_glassify_sbez_defaultFrequency);
    CGFloat phase = axs_glassify_sbez_configValue(@"sbz_phase", 0.0f);
    CGFloat lineWidth = axs_glassify_sbez_configValue(@"sbz_width", axs_glassify_sbez_defaultWidth);
    CGFloat opacity = axs_glassify_sbez_configValue(@"sbz_opacity", axs_glassify_sbez_defaultOpacity);
    CGFloat hue = axs_glassify_sbez_configValue(@"sbz_hue", axs_glassify_sbez_defaultHue);

    NSUInteger style = axs_glassify_sbez_styleSignature(enabled, amplitude, frequency, phase,
                                                      lineWidth, opacity, hue, fade);
    if (lastSize != nil && lastStyle != nil
        && CGSizeEqualToSize(lastSize.CGSizeValue, size)
        && lastStyle.unsignedIntegerValue == style) {
        objc_setAssociatedObject(self, &axs_glassify_sbez_keyDirty, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    objc_setAssociatedObject(self, &axs_glassify_sbez_keyLastSize,
                             [NSValue valueWithCGSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &axs_glassify_sbez_keyLastStyle,
                             @(style), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &axs_glassify_sbez_keyDirty, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!enabled) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.path = NULL;
        // 关掉线时把淡出动画撤掉、strokeEnd 的 model 值拉回 1：
        // 只开轨迹关线时，装饰层必须干净地不存在。
        [layer removeAnimationForKey:@"axs_glassify_sbez_fade"];
        layer.strokeEnd = 1.0f;
        [CATransaction commit];
        return;
    }

    CGRect frame = self.bounds;
    CGFloat scale = self.layer.contentsScale;
    if (scale <= 0.0f) {
        scale = [UIScreen mainScreen].scale;
    }
    UIBezierPath *path = axs_glassify_sbez_wavePath(frame, amplitude, frequency,
                                                  axs_glassify_sbez_waveSeed(phase));

    // Every write below would otherwise spawn a 0.25s implicit animation, and at
    // layout frequency those overlap into permanent redraw work.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.frame = frame;
    layer.contentsScale = scale;
    layer.path = path != nil ? path.CGPath : NULL;
    layer.strokeColor = axs_glassify_sbez_curveColor(hue).CGColor;
    layer.lineWidth = MAX(0.5f, MIN(lineWidth, 24.0f));
    layer.opacity = (float)MAX(0.0f, MIN(opacity, 1.0f));
    layer.strokeEnd = fade ? 0.0f : 1.0f;
    [CATransaction commit];

    // 每次（重）画播放一次生长：常驻档画满停住（最后一条曲线就是原插件的签名
    // 观感），淡出档画满后收回消失。model 值与动画终点一致（常驻 1 / 淡出 0），
    // 动画被清理时也不会闪。
    [self axs_glassify_sbez_playDecorationDrawFade:fade];
}

// strokeEnd 生长动画。Forwards + 不自动移除：表现层停在最后一帧 ——
// 常驻档停在 1，淡出档停在 0（线真消失）。若用 Removed，完成瞬间会跳回
// model 值，淡出档的线会闪回来。
- (void)axs_glassify_sbez_playDecorationDrawFade:(BOOL)fade {
    CAShapeLayer *layer = objc_getAssociatedObject(self, &axs_glassify_sbez_keyLayer);
    if (layer == nil) {
        return;
    }
    CGFloat duration = axs_glassify_sbez_configValue(@"sbz_duration", axs_glassify_sbez_defaultDuration);
    duration = MAX(0.05f, MIN(duration, 5.0f));

    CAKeyframeAnimation *draw = [CAKeyframeAnimation animationWithKeyPath:@"strokeEnd"];
    if (fade) {
        draw.values = @[@0.0f, @1.0f, @1.0f, @0.0f];
        draw.keyTimes = @[@0.0f, @0.45f, @0.6f, @1.0f];
    } else {
        draw.values = @[@0.0f, @1.0f];
        draw.keyTimes = @[@0.0f, @1.0f];
    }
    draw.duration = fade ? duration * 1.5f : duration;
    draw.calculationMode = kCAAnimationLinear;
    draw.fillMode = kCAFillModeForwards;
    draw.removedOnCompletion = NO;
    [layer addAnimation:draw forKey:@"axs_glassify_sbez_fade"];
}

- (void)axs_glassify_sbez_animateEntrance {
    // 轨迹只驱动 transform；装饰曲线的生长/淡出在 playDecorationDrawFade，两者独立开关。
    if (!axs_glassify_sbez_entranceActive()) {
        return;
    }

    CGFloat duration = axs_glassify_sbez_configValue(@"sbz_duration", axs_glassify_sbez_defaultDuration);
    duration = MAX(0.05f, MIN(duration, 5.0f));
    CGFloat amplitude = axs_glassify_sbez_configValue(@"sbz_amplitude", axs_glassify_sbez_defaultAmplitude);
    CGFloat frequency = axs_glassify_sbez_configValue(@"sbz_frequency", axs_glassify_sbez_defaultFrequency);
    CGFloat phase = axs_glassify_sbez_configValue(@"sbz_phase", 0.0f);

    // The banner settles into its real frame; only the transform travels, so an
    // unrelated layout pass cannot fight the animation. The keyframes compose on
    // top of whatever the glass engine wrote as the model transform (缩放/倾斜),
    // so removing the animation at the end lands exactly on the model value.
    CGFloat travel = CGRectGetHeight(self.bounds) + 40.0f;
    CAKeyframeAnimation *entrance = axs_glassify_sbez_entranceAnimation(self.layer.transform,
                                                                         amplitude, frequency, phase,
                                                                         travel, duration);
    if (entrance != nil) {
        [self.layer addAnimation:entrance forKey:@"axs_glassify_sbez_entrance"];
    }
}

- (void)axs_glassify_sbez_cleanup {
    id token = objc_getAssociatedObject(self, &axs_glassify_sbez_keyObserver);
    if (token != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        objc_setAssociatedObject(self, &axs_glassify_sbez_keyObserver, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    CAShapeLayer *layer = objc_getAssociatedObject(self, &axs_glassify_sbez_keyLayer);
    if (layer != nil) {
        [layer removeAllAnimations];
        [layer removeFromSuperlayer];
        objc_setAssociatedObject(self, &axs_glassify_sbez_keyLayer, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    objc_setAssociatedObject(self, &axs_glassify_sbez_keyLastSize, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(self, &axs_glassify_sbez_keyLastStyle, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(self, &axs_glassify_sbez_keyDirty, nil, OBJC_ASSOCIATION_ASSIGN);
    // Back to unprocessed so a recycled banner can claim the accent again.
    objc_setAssociatedObject(self, &axs_glassify_sbez_keyState, nil, OBJC_ASSOCIATION_ASSIGN);
}

@end
