#pragma once

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>

// S curve geometry and animation shared by the tweak and the preference bundle,
// so the panel preview renders exactly what a real notification will do.
//
// Header-only by design: these are `static inline`, so each binary gets its own
// copy and the preference bundle needs no cross-directory source file (Theos
// derives object paths from the source path, and a ../ entry would land outside
// the object directory). Nothing here defines an Objective-C class, so compiling
// it into both the dylib and the bundle cannot collide.
//
// Cost notes: the path is built from a handful of knots (two per requested wave)
// rather than sampling across the banner, and every value is deterministic for a
// given seed, so callers can cache aggressively instead of redrawing.

enum {
    // Two knots per wave; the cap bounds stack use and rasterisation cost.
    axs_glassify_sbez_maxHumps = 20,
};

static inline uint32_t axs_glassify_sbez_random(uint32_t *state) {
    uint32_t value = *state;
    if (value == 0) {
        value = 0x9E3779B9u;
    }
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    *state = value;
    return value;
}

// Uniform draw in [0, 1].
static inline CGFloat axs_glassify_sbez_randomUnit(uint32_t *state) {
    return (CGFloat)(axs_glassify_sbez_random(state) >> 8) / (CGFloat)(1u << 24);
}

// Horizontal offset of the entrance sway for a normalised parameter t in [0, 1].
// The entrance keeps a smooth sine; only the drawn accent is irregular.
static inline CGFloat axs_glassify_sbez_waveOffset(CGFloat t, CGFloat amplitude,
                                                 CGFloat frequency, CGFloat phase) {
    if (!isfinite(t) || !isfinite(amplitude) || !isfinite(frequency) || !isfinite(phase)) {
        return 0.0f;
    }
    return amplitude * sinf(2.0f * (CGFloat)M_PI * frequency * t + phase);
}

// The panel slider doubles as the shape seed, so one value always yields one
// waveform and two callers asking for the same parameters agree.
static inline uint32_t axs_glassify_sbez_waveSeed(CGFloat phase) {
    if (!isfinite(phase)) {
        return 0x9E3779B9u;
    }
    uint32_t steps = (uint32_t)((int64_t)llround(fabs(phase) * 1000.0) & 0xFFFF);
    return steps * 2654435761u + 0x9E3779B9u;
}

// Cubic Bezier path tracing one S wave across the given rectangle.
//
// Every crest and trough gets its own height, spacing and curvature, so the line
// is not a uniform sine. The seed selects the shape; the same seed reproduces it.
static inline UIBezierPath *axs_glassify_sbez_wavePath(CGRect rect, CGFloat amplitude,
                                                     CGFloat frequency, uint32_t seed) {
    CGFloat width = CGRectGetWidth(rect);
    CGFloat height = CGRectGetHeight(rect);
    if (width < 1.0f || height < 1.0f) {
        return nil;
    }
    if (!isfinite(amplitude) || !isfinite(frequency)) {
        return nil;
    }

    CGFloat inset = MIN(8.0f, width * 0.05f);
    CGFloat usable = MAX(1.0f, width - inset * 2.0f);
    CGFloat left = CGRectGetMinX(rect) + inset;
    // Keep the wave in the lower band of the banner so it reads as an accent
    // instead of crossing the notification text.
    CGFloat baseY = CGRectGetMinY(rect) + height * 0.68f;
    CGFloat wave = MIN(MAX(amplitude, 0.0f), height * 0.35f);

    NSInteger humps = (NSInteger)lround(MAX(frequency, 0.5f) * 2.0);
    if (humps < 2) {
        humps = 2;
    }
    if (humps > axs_glassify_sbez_maxHumps) {
        humps = axs_glassify_sbez_maxHumps;
    }

    uint32_t state = seed;
    // Burn two draws so neighbouring seeds do not produce near-identical shapes.
    axs_glassify_sbez_random(&state);
    axs_glassify_sbez_random(&state);

    // Span weights decide how much width each hump gets: this is the "speed" of
    // each crest, and it deliberately differs from hump to hump.
    CGFloat weights[axs_glassify_sbez_maxHumps];
    CGFloat total = 0.0f;
    for (NSInteger i = 0; i < humps; i++) {
        weights[i] = 0.65f + 0.70f * axs_glassify_sbez_randomUnit(&state);
        total += weights[i];
    }

    CGPoint knots[axs_glassify_sbez_maxHumps + 1];
    CGFloat accumulated = 0.0f;
    for (NSInteger i = 0; i <= humps; i++) {
        if (i > 0) {
            accumulated += weights[i - 1];
        }
        CGFloat x = (i == humps) ? (left + usable) : (left + usable * (accumulated / total));
        // Level entry and exit; only the interior knots swing up and down.
        CGFloat y = baseY;
        if (i > 0 && i < humps) {
            CGFloat direction = (i % 2 == 1) ? 1.0f : -1.0f;
            CGFloat scale = 0.45f + 0.55f * axs_glassify_sbez_randomUnit(&state);
            y = baseY + direction * wave * scale;
        }
        knots[i] = CGPointMake(x, y);
    }

    // Guard points outside the span give the end tangents their true direction.
    CGPoint points[axs_glassify_sbez_maxHumps + 3];
    points[0] = CGPointMake(knots[0].x - (knots[1].x - knots[0].x), knots[0].y);
    for (NSInteger i = 0; i <= humps; i++) {
        points[i + 1] = knots[i];
    }
    points[humps + 2] = CGPointMake(knots[humps].x + (knots[humps].x - knots[humps - 1].x),
                                    knots[humps].y);

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:points[1]];
    // humps segments connect points[1..humps+1]; the trailing guard is only there
    // for the last segment's tangent, so the loop must stop at humps.
    for (NSInteger i = 1; i <= humps; i++) {
        CGPoint start = points[i];
        CGPoint end = points[i + 1];
        CGPoint previous = points[i - 1];
        CGPoint next = points[i + 2];
        // Per-segment tension, so no two humps share the same curvature.
        CGFloat tension = 5.0f + 2.5f * axs_glassify_sbez_randomUnit(&state);
        CGPoint control1 = CGPointMake(start.x + (end.x - previous.x) / tension,
                                       start.y + (end.y - previous.y) / tension);
        CGPoint control2 = CGPointMake(end.x - (next.x - start.x) / tension,
                                       end.y - (next.y - start.y) / tension);
        [path addCurveToPoint:end controlPoint1:control1 controlPoint2:control2];
    }
    return path;
}

// Accent colour for a hue in [0, 1]; the hue wraps instead of clamping.
static inline UIColor *axs_glassify_sbez_curveColor(CGFloat hue) {
    CGFloat wrapped = isfinite(hue) ? fmodf(hue, 1.0f) : 0.0f;
    if (wrapped < 0.0f) {
        wrapped += 1.0f;
    }
    return [UIColor colorWithHue:wrapped saturation:0.72f brightness:0.96f alpha:1.0f];
}

// Keyframe animation that travels `travel` points along the S curve and settles
// back onto `base`. Returns nil when duration is not positive.
//
// base 不是随手加的：合并后玻璃引擎会把 notify_scale / tilt 写成卡片的 model
// transform，入场最后一帧若落到 identity，动画移除的一瞬间卡片会从缩放态跳回
// 原尺寸。每帧复合在 base 上，终点恰好等于 model 值，移除无感。
// CALayer.transform is a CATransform3D，这里绝不能塞 CGAffineTransform——
// Core Animation 会拿到错位数据，动画静默地什么都不做。
static inline CAKeyframeAnimation *axs_glassify_sbez_entranceAnimation(CATransform3D base,
                                                                       CGFloat amplitude, CGFloat frequency,
                                                                    CGFloat phase, CGFloat travel,
                                                                    NSTimeInterval duration) {
    if (!isfinite(duration) || duration <= 0.0) {
        return nil;
    }
    if (!isfinite(travel)) {
        travel = 0.0f;
    }

    // 24 samples is smooth at any banner height and keeps the animation small.
    NSInteger frames = 24;
    NSMutableArray *transforms = [NSMutableArray arrayWithCapacity:(NSUInteger)frames + 1];
    for (NSInteger i = 0; i <= frames; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)frames;
        CGFloat dx = axs_glassify_sbez_waveOffset(t, amplitude, frequency, phase) * (1.0f - t);
        CGFloat dy = travel * (1.0f - t);
        [transforms addObject:[NSValue valueWithCATransform3D:CATransform3DTranslate(base, dx, dy, 0.0f)]];
    }

    CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    animation.values = transforms;
    animation.duration = duration;
    animation.calculationMode = kCAAnimationLinear;
    animation.fillMode = kCAFillModeRemoved;
    animation.removedOnCompletion = YES;
    return animation;
}
