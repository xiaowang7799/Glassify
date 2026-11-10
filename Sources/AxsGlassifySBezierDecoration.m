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
    axs_glassify_sbez_stateClaimed = 1,   // this view owns the accent
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

// The entrance effect needs both the master switch and its own switch. The
// verdict is one shared predicate on the config object because the glass side
// must consult the same answer: while the S-shaped banner entrance is active it
// owns the card's `transform`, so the appear animation (transform.scale) has to
// stand down instead of fighting it frame by frame.
static BOOL axs_glassify_sbez_entranceActive(void) {
    return [[AxsGlassifyNotifyConfig axs_glassify_notify_shared] axs_glassify_notify_sbezEntranceActive];
}

// One number standing for every input that affects the drawing, so an unchanged
// layout pass can be detected without rebuilding the path.
static NSUInteger axs_glassify_sbez_styleSignature(BOOL enabled, CGFloat amplitude, CGFloat frequency,
                                                 CGFloat phase, CGFloat width, CGFloat opacity,
                                                 CGFloat hue) {
    float inputs[6] = {(float)amplitude, (float)frequency, (float)phase,
                       (float)width, (float)opacity, (float)hue};
    uint32_t parts[7];
    parts[0] = enabled ? 1u : 0u;
    for (NSInteger i = 0; i < 6; i++) {
        union { float f; uint32_t u; } cast;
        cast.f = inputs[i];
        parts[i + 1] = cast.u;
    }
    uint64_t hash = 1469598103934665603ULL;
    for (NSInteger i = 0; i < 7; i++) {
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

    // Cheap gates before anything hierarchical: no config, no traversal.
    if (!axs_glassify_sbez_entranceActive()) {
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

    BOOL enabled = axs_glassify_sbez_entranceActive();
    CGFloat amplitude = axs_glassify_sbez_configValue(@"sbz_amplitude", axs_glassify_sbez_defaultAmplitude);
    CGFloat frequency = axs_glassify_sbez_configValue(@"sbz_frequency", axs_glassify_sbez_defaultFrequency);
    CGFloat phase = axs_glassify_sbez_configValue(@"sbz_phase", 0.0f);
    CGFloat lineWidth = axs_glassify_sbez_configValue(@"sbz_width", axs_glassify_sbez_defaultWidth);
    CGFloat opacity = axs_glassify_sbez_configValue(@"sbz_opacity", axs_glassify_sbez_defaultOpacity);
    CGFloat hue = axs_glassify_sbez_configValue(@"sbz_hue", axs_glassify_sbez_defaultHue);

    NSUInteger style = axs_glassify_sbez_styleSignature(enabled, amplitude, frequency, phase,
                                                      lineWidth, opacity, hue);
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
    [CATransaction commit];
}

- (void)axs_glassify_sbez_animateEntrance {
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

    CAShapeLayer *layer = objc_getAssociatedObject(self, &axs_glassify_sbez_keyLayer);
    if (layer != nil) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.strokeEnd = 1.0f;
        [CATransaction commit];

        CABasicAnimation *draw = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        draw.fromValue = @0.0f;
        draw.toValue = @1.0f;
        draw.duration = duration;
        draw.fillMode = kCAFillModeRemoved;
        draw.removedOnCompletion = YES;
        [layer addAnimation:draw forKey:@"axs_glassify_sbez_draw"];
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
