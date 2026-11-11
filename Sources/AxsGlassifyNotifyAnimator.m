#import "AxsGlassifyNotifyAnimator.h"
#import "AxsGlassifyLiquid.h"
#import "AxsGlassifyNotifyConfig.h"
#import "AxsGlassifyPreferences.h"
// axs_glassify_sbez_viewSerpDisplaced：蜿蜒排版占用 transform 的围栏判断。
#import "AxsGlassifySBezier.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>

// 视图是否已播过入场/爆发（滚动复用不重播）。
static const void *kAxsLiquidSeenKey = &kAxsLiquidSeenKey;
// 标记卡片上已挂过我们的拖动手势，避免重复添加。
static const void *kAxsGlassifyNotifyPanKey = &kAxsGlassifyNotifyPanKey;

// 触摸反馈：轻段触感，节流 0.2s（连点不刷屏）。
static void axs_glassify_notify_haptic(BOOL enabled) {
    if (!enabled) return;
    static CFTimeInterval last = 0.0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.2) return;
    last = now;
    UIImpactFeedbackGenerator *generator =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [generator prepare];
    [generator impactOccurred];
}

// 拖动进度（-1…1）→ 横向偏移比例（-1…1），让卡片真的沿 S 形轨迹走。
// 取值 sin(πu)·sin(2πu) 再归一化到 [-1,1]（u = |t|）：
//   u=0 起始居中 → u≈0.30 摆到 +1 → u=0.5 过中线 → u≈0.70 摆到 -1 → u=1 回到居中。
// 曲线两端按 u² 起势，所以刚起手不会横向跳；乘 t 的符号后，上滑与下滑镜像对称。
// （旧的 3u²-2u³ 在 0→1 上单调，只是一道弧，永远看不到反向的那一半，所以看不出 S。）
static CGFloat axs_glassify_notify_sCurveShape(CGFloat t) {
    CGFloat c = (CGFloat)fmax(-1.0, fmin(1.0, t));
    CGFloat u = (CGFloat)fabs(c);
    // 1.2990 = 1 / max(sin(πu)·sin(2πu))，归一化后最大横向偏移正好等于设置值。
    CGFloat s = (CGFloat)(sin(M_PI * u) * sin(2.0 * M_PI * u) * 1.2990);
    return c < 0.0f ? -s : s;
}

// 单条通知的效果容器（视图弱引用，通知消失自动失效）。
@interface AxsGlassifyNotifyEffect : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic, strong) CAGradientLayer *gradient;   // 流动渐变背景
@property (nonatomic, strong) NSMutableArray<CALayer *> *fishLayers;  // 鱼缸游鱼
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishNextBubble;  // 每条鱼的吐泡倒计时
@property (nonatomic, assign) double fishSeed;   // 每条通知随机相位（鱼游互不同步）
@property (nonatomic, assign) double particleJitter;   // 每条通知粒子发射率抖动（发射互不同步）
@property (nonatomic, weak) UILabel *titleLabel;       // 标题标签（最大的字）
@property (nonatomic, weak) UIImageView *iconView;     // 应用图标
@property (nonatomic, strong) CAGradientLayer *iconGlow;  // 图标光晕（背后径向渐变）
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fishFlip;   // 每条鱼的朝向缓存
@property (nonatomic, weak) UIView *gradientHost;       // 渐变挂在哪一层（玻璃 contentView / 材质层）
@property (nonatomic, assign) float lastGradientAlpha;     // 渐变透明度缓存（避免重复写）
@property (nonatomic, assign) double chargeNext; // 充电火花倒计时
@property (nonatomic, strong) CAEmitterLayer *burst;       // 到达粒子爆发
@property (nonatomic, strong) CAEmitterLayer *season;      // 季节粒子
@property (nonatomic, strong) UIColor *iconColor;          // 应用图标取色（缓存）
@property (nonatomic, assign) NSInteger lastParticleKey;   // 粒子样式缓存（-1 = 回退态）
@property (nonatomic, assign) CFTimeInterval lastLoadAttempt;  // 图片加载重试时间戳
@property (nonatomic, assign) BOOL burstPlayed;
@property (nonatomic, assign) CGFloat dragProgress;        // S 曲线滑动进度（-1…1，0 = 未拖动）
@property (nonatomic, strong) CAGradientLayer *dragGlow;   // 拖动时的边缘色散光（静止不可见）
@property (nonatomic, assign) NSUInteger styleGeneration;  // 样式上次应用时的配置代次
@property (nonatomic, assign) CGSize styleSize;            // 上次应用时的卡片尺寸
@property (nonatomic, assign) CGFloat styleSuperWidth;     // 上次应用时的父视图宽度
@end
@implementation AxsGlassifyNotifyEffect
@end

// emoji 渲染成图片（粒子 sprite）。
static UIImage *axs_glassify_notify_emojiImage(NSString *emoji, CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    [emoji drawInRect:CGRectMake(0, size * 0.05, size, size * 0.9)
       withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:size * 0.8],
                        NSParagraphStyleAttributeName: style}];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// 透明彩色玻璃鱼（半透明渐变身体 + 亮边描线 + 内高光 + 条纹）。
static UIImage *axs_glassify_notify_fishImage(UIColor *base, CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w = size, h = size;

    CGFloat r = 0, g = 0, b = 0, a = 1;
    [base getRed:&r green:&g blue:&b alpha:&a];
    CGFloat topR = (CGFloat)fmin(1.0, r * 1.3 + 0.15);
    CGFloat topG = (CGFloat)fmin(1.0, g * 1.3 + 0.15);
    CGFloat topB = (CGFloat)fmin(1.0, b * 1.3 + 0.15);

    // 尾鳍（半透明扇形 + 亮边）。
    UIBezierPath *tail = [UIBezierPath bezierPath];
    [tail moveToPoint:CGPointMake(w * 0.66, h * 0.5)];
    [tail addQuadCurveToPoint:CGPointMake(w * 0.97, h * 0.16)
                 controlPoint:CGPointMake(w * 0.92, h * 0.34)];
    [tail addLineToPoint:CGPointMake(w * 0.97, h * 0.84)];
    [tail addQuadCurveToPoint:CGPointMake(w * 0.66, h * 0.5)
                 controlPoint:CGPointMake(w * 0.92, h * 0.66)];
    [tail closePath];
    [[base colorWithAlphaComponent:0.38] setFill];
    [tail fill];
    [[base colorWithAlphaComponent:0.75] setStroke];
    tail.lineWidth = w * 0.022;
    [tail stroke];

    // 身体（水滴形，半透明渐变：上亮下深）。
    UIBezierPath *body = [UIBezierPath bezierPath];
    [body moveToPoint:CGPointMake(w * 0.05, h * 0.5)];
    [body addQuadCurveToPoint:CGPointMake(w * 0.70, h * 0.18)
                 controlPoint:CGPointMake(w * 0.34, h * 0.10)];
    [body addQuadCurveToPoint:CGPointMake(w * 0.70, h * 0.82)
                 controlPoint:CGPointMake(w * 0.92, h * 0.5)];
    [body addQuadCurveToPoint:CGPointMake(w * 0.05, h * 0.5)
                 controlPoint:CGPointMake(w * 0.34, h * 0.90)];
    [body closePath];
    CGFloat comps[] = {topR, topG, topB, 0.82f, (CGFloat)(r * 0.85), (CGFloat)(g * 0.85), (CGFloat)(b * 0.85), 0.38f};
    CGFloat locs[] = {0, 1};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
    CGContextSaveGState(ctx);
    [body addClip];
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, h * 0.12), CGPointMake(0, h * 0.88), 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(grad);
    CGColorSpaceRelease(space);
    // 亮边描线（玻璃轮廓）。
    [[base colorWithAlphaComponent:0.95] setStroke];
    body.lineWidth = w * 0.028;
    [body stroke];

    // 背鳍（半透明）。
    UIBezierPath *fin = [UIBezierPath bezierPath];
    [fin moveToPoint:CGPointMake(w * 0.40, h * 0.22)];
    [fin addQuadCurveToPoint:CGPointMake(w * 0.60, h * 0.16)
                 controlPoint:CGPointMake(w * 0.54, h * 0.02)];
    [fin addQuadCurveToPoint:CGPointMake(w * 0.50, h * 0.26)
                 controlPoint:CGPointMake(w * 0.58, h * 0.20)];
    [fin closePath];
    [[base colorWithAlphaComponent:0.45] setFill];
    [fin fill];
    [[base colorWithAlphaComponent:0.8] setStroke];
    fin.lineWidth = w * 0.018;
    [fin stroke];

    // 内高光（玻璃质感：上部白色柔光）。
    UIBezierPath *glint = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(w * 0.18, h * 0.22, w * 0.34, h * 0.16)];
    [[UIColor colorWithWhite:1 alpha:0.35] setFill];
    [glint fill];

    // 条纹（浅弧）。
    [[UIColor colorWithWhite:1 alpha:0.30] setStroke];
    for (int s = 0; s < 2; s++) {
        UIBezierPath *stripe = [UIBezierPath bezierPath];
        CGFloat sx = w * (0.42 + 0.16 * s);
        [stripe moveToPoint:CGPointMake(sx, h * 0.26)];
        [stripe addQuadCurveToPoint:CGPointMake(sx, h * 0.74)
                      controlPoint:CGPointMake(sx + w * 0.12, h * 0.5)];
        stripe.lineWidth = w * 0.04;
        stripe.lineCapStyle = kCGLineCapRound;
        [stripe stroke];
    }

    // 眼睛（白 + 瞳孔 + 高光）。
    CGRect eyeRect = CGRectMake(w * 0.20, h * 0.38, w * 0.17, h * 0.17);
    [[UIColor colorWithWhite:1 alpha:0.92] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:eyeRect] fill];
    [[UIColor colorWithWhite:0.08 alpha:1] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(eyeRect, w * 0.042, h * 0.042)] fill];
    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:
      CGRectMake(eyeRect.origin.x + w * 0.05, eyeRect.origin.y + h * 0.05, w * 0.04, h * 0.04)] fill];

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// 手绘小鱼 sprite 缓存：同一套 5 张图只在进程内渲染一次。
// 之前每张通知 attach 都要画 8 次 Core Graphics，通知一多就白掉帧。
static UIImage *axs_glassify_notify_fishSprite(NSUInteger index) {
    static NSArray<UIImage *> *sprites;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<UIColor *> *palette = @[
            [UIColor colorWithRed:1.00 green:0.62 blue:0.21 alpha:1],   // 金橙
            [UIColor colorWithRed:0.25 green:0.72 blue:0.85 alpha:1],   // 青蓝
            [UIColor colorWithRed:1.00 green:0.45 blue:0.62 alpha:1],   // 粉
            [UIColor colorWithRed:0.66 green:0.42 blue:0.90 alpha:1],   // 紫
            [UIColor colorWithRed:0.36 green:0.82 blue:0.50 alpha:1],   // 绿
        ];
        NSMutableArray<UIImage *> *built = [NSMutableArray arrayWithCapacity:palette.count];
        for (UIColor *color in palette) {
            UIImage *image = axs_glassify_notify_fishImage(color, 64.0);
            if (image) [built addObject:image];
        }
        sprites = [built copy];
    });
    if (sprites.count == 0) return nil;
    return sprites[index % sprites.count];
}

// 亮晶晶的蝴蝶：半透明渐变翅膀 + 白色亮边 + 星芒点绀（充电特效用）。
static UIImage *axs_glassify_notify_butterflyImage(CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w = size, h = size;

    UIBezierPath *(^wing)(BOOL, BOOL) = ^UIBezierPath *(BOOL upper, BOOL left) {
        CGFloat s = left ? -1.0 : 1.0;
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(w * 0.50, h * 0.52)];
        if (upper) {
            [p addCurveToPoint:CGPointMake(w * (0.50 + s * 0.45), h * 0.08)
                 controlPoint1:CGPointMake(w * (0.50 + s * 0.08), h * 0.42)
                 controlPoint2:CGPointMake(w * (0.50 + s * 0.40), h * 0.02)];
            [p addCurveToPoint:CGPointMake(w * 0.50, h * 0.52)
                 controlPoint1:CGPointMake(w * (0.50 + s * 0.56), h * 0.30)
                 controlPoint2:CGPointMake(w * (0.50 + s * 0.20), h * 0.58)];
        } else {
            [p addCurveToPoint:CGPointMake(w * (0.50 + s * 0.32), h * 0.94)
                 controlPoint1:CGPointMake(w * (0.50 + s * 0.14), h * 0.62)
                 controlPoint2:CGPointMake(w * (0.50 + s * 0.40), h * 0.76)];
            [p addCurveToPoint:CGPointMake(w * 0.50, h * 0.52)
                 controlPoint1:CGPointMake(w * (0.50 + s * 0.40), h * 1.04)
                 controlPoint2:CGPointMake(w * (0.50 + s * 0.12), h * 0.80)];
        }
        [p closePath];
        return p;
    };

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = {1.00f, 0.52f, 0.88f, 0.88f,   0.42f, 0.86f, 1.00f, 0.52f};
    CGFloat locs[] = {0.0f, 1.0f};

    for (NSInteger i = 0; i < 4; i++) {
        UIBezierPath *p = wing((i % 2) == 0, (i / 2) == 0);
        CGContextSaveGState(ctx);
        [p addClip];
        CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
        CGContextDrawLinearGradient(ctx, grad, CGPointMake(w * 0.5, 0), CGPointMake(w * 0.5, h), 0);
        CGGradientRelease(grad);
        CGContextRestoreGState(ctx);
        [[UIColor colorWithWhite:1.0 alpha:0.88] setStroke];
        p.lineWidth = size * 0.012;
        [p stroke];
    }
    CGColorSpaceRelease(space);

    // 身体
    UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(w * 0.466, h * 0.26, w * 0.068, h * 0.52) cornerRadius:w * 0.034];
    [[UIColor colorWithRed:0.44 green:0.30 blue:0.66 alpha:0.95] setFill];
    [body fill];

    // 触角
    [[UIColor colorWithWhite:1.0 alpha:0.72] setStroke];
    UIBezierPath *ant = [UIBezierPath bezierPath];
    [ant moveToPoint:CGPointMake(w * 0.49, h * 0.28)];
    [ant addQuadCurveToPoint:CGPointMake(w * 0.34, h * 0.10) controlPoint:CGPointMake(w * 0.40, h * 0.21)];
    [ant moveToPoint:CGPointMake(w * 0.51, h * 0.28)];
    [ant addQuadCurveToPoint:CGPointMake(w * 0.66, h * 0.10) controlPoint:CGPointMake(w * 0.60, h * 0.21)];
    ant.lineWidth = size * 0.012;
    ant.lineCapStyle = kCGLineCapRound;
    [ant stroke];

    // 星芒点缀（亮晶晶）
    const CGFloat starPos[4][3] = {{0.20, 0.30, 1.00}, {0.78, 0.20, 0.80},
                                   {0.34, 0.80, 0.70}, {0.72, 0.72, 0.90}};
    for (int i = 0; i < 4; i++) {
        CGFloat cx = w * starPos[i][0];
        CGFloat cy = h * starPos[i][1];
        CGFloat r = size * 0.035 * starPos[i][2];
        UIBezierPath *sp = [UIBezierPath bezierPath];
        [sp moveToPoint:CGPointMake(cx, cy - r)];
        [sp addQuadCurveToPoint:CGPointMake(cx + r, cy) controlPoint:CGPointMake(cx + r * 0.15, cy - r * 0.15)];
        [sp addQuadCurveToPoint:CGPointMake(cx, cy + r) controlPoint:CGPointMake(cx + r * 0.15, cy + r * 0.15)];
        [sp addQuadCurveToPoint:CGPointMake(cx - r, cy) controlPoint:CGPointMake(cx - r * 0.15, cy + r * 0.15)];
        [sp addQuadCurveToPoint:CGPointMake(cx, cy - r) controlPoint:CGPointMake(cx - r * 0.15, cy - r * 0.15)];
        [sp closePath];
        [[UIColor colorWithWhite:1.0 alpha:0.92] setFill];
        [sp fill];
    }

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// 爆发回退光点也只需画一次。
static UIImage *axs_glassify_notify_defaultBurstSprite(void) {
    static UIImage *sprite;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(12, 12), NO, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(3, 3, 6, 6));
        sprite = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return sprite;
}

// UIImage 平均色（壁纸/图标取色用）。
@interface UIImage (AxsGlassifyNotifyAverage)
- (UIColor *)axs_glassify_notify_averageColor;
@end
@implementation UIImage (AxsGlassifyNotifyAverage)
- (UIColor *)axs_glassify_notify_averageColor {
    CGImageRef cg = self.CGImage;
    if (!cg) return nil;
    size_t w = 16, h = 16;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    uint8_t *buf = (uint8_t *)calloc(w * h * 4, 1);
    if (!buf) { CGColorSpaceRelease(space); return nil; }
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) { free(buf); CGColorSpaceRelease(space); return nil; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    double r = 0, g = 0, b = 0;
    for (size_t i = 0; i < w * h; i++) { r += buf[i*4]; g += buf[i*4+1]; b += buf[i*4+2]; }
    size_t n = w * h;
    UIColor *color = [UIColor colorWithRed:r/n/255.0 green:g/n/255.0 blue:b/n/255.0 alpha:1.0];
    CGContextRelease(ctx); CGColorSpaceRelease(space); free(buf);
    return color;
}
@end

// 壁纸主色（缓存 5 秒，避免逐帧解码）。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static UIColor *axs_glassify_notify_wallpaperColor(void) {
    static UIColor *cached = nil;
    static CFTimeInterval cachedAt = -100.0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cached && now - cachedAt < 5.0) return cached;
    cachedAt = now;
    if (@available(iOS 13.0, *)) {
        Class cls = NSClassFromString(@"SBFWallpaperView");
        if (!cls) return cached;
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if (![cls respondsToSelector:sharedSel]) return cached;
        id view = [cls performSelector:sharedSel];
        if (!view) return cached;
        SEL imgSel = NSSelectorFromString(@"currentWallpaperImage");
        if (![view respondsToSelector:imgSel]) return cached;
        UIImage *img = [view performSelector:imgSel];
        if (![img isKindOfClass:[UIImage class]]) return cached;
        cached = [img axs_glassify_notify_averageColor];
        return cached;
    }
    return cached;
}
#pragma clang diagnostic pop

// 找通知里的应用图标（正方形小 UIImageView）。
static UIImageView *axs_glassify_notify_findIconView(UIView *view, int depth) {
    if (depth > 6) return nil;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIImageView class]]) {
            UIImageView *iv = (UIImageView *)sub;
            CGFloat w = iv.bounds.size.width;
            if (iv.image && w > 8 && w < 80 && fabs(w - iv.bounds.size.height) < 4) {
                return iv;
            }
        }
        UIImageView *deep = axs_glassify_notify_findIconView(sub, depth + 1);
        if (deep) return deep;
    }
    return nil;
}

// 热路径（布局 / 找背景层）：用 C 字符串比较，不建 NSString。
static BOOL axs_glassify_notify_class_contains(UIView *view, const char *needle) {
    const char *name = class_getName(object_getClass(view));
    return name != NULL && strstr(name, needle) != NULL;
}

// 自定义鱼图按路径缓存：同一套图只从磁盘读一次，而不是每张通知各读一遍。
static NSArray<UIImage *> *axs_glassify_notify_customFishImages(NSString *paths) {
    static NSString *cachedPaths = nil;
    static NSArray<UIImage *> *cachedImages = nil;
    NSString *key = paths ?: @"";
    if (cachedPaths != nil && [cachedPaths isEqualToString:key]) {
        return cachedImages;
    }
    NSMutableArray<UIImage *> *images = [NSMutableArray array];
    for (NSString *raw in [key componentsSeparatedByString:@";"]) {
        NSString *trimmed = [raw stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;
        UIImage *img = [UIImage imageWithContentsOfFile:trimmed];
        if (img) [images addObject:img];
        if (images.count >= 6) break;
    }
    cachedPaths = [key copy];
    cachedImages = [images copy];
    return cachedImages;
}

// 找通知的背景视图（毛玻璃/材质层）。圆角打在它身上而不是通知层，
// 避免 masksToBounds 裁掉粒子（粒子要飘出通知边界）。
static UIView *axs_glassify_notify_findBackgroundView(UIView *view, int depth) {
    if (depth > 5) return nil;
    for (UIView *sub in view.subviews) {
        if (sub.bounds.size.width < 10) continue;
        // 玻璃底板是合并后新增的背景层，圆角归 AxsGlassifyLiquid 管；
        // 这里跳过它，继续找卡片真正的材质层。
        if ([AxsGlassifyLiquid axs_glassify_isGlassView:sub]) continue;
        if ([sub isKindOfClass:[UIVisualEffectView class]]
            || axs_glassify_notify_class_contains(sub, "WallpaperEffect")
            || axs_glassify_notify_class_contains(sub, "Material")
            || axs_glassify_notify_class_contains(sub, "Backdrop")
            || axs_glassify_notify_class_contains(sub, "Background")) {
            return sub;
        }
        UIView *deep = axs_glassify_notify_findBackgroundView(sub, depth + 1);
        if (deep) return deep;
    }
    return nil;
}

// 渐变层要待在「玻璃之上、文字之下」：优先挂到玻璃底板的 contentView，
// 没有玻璃（开关关掉 / 还没装上）就退回卡片自己的材质层。
static UIView *axs_glassify_notify_gradientHost(UIView *view) {
    UIView *glassContent = [AxsGlassifyLiquid axs_glassify_glassContentViewForPlatter:view];
    if (glassContent) return glassContent;
    UIView *background = axs_glassify_notify_findBackgroundView(view, 0);
    return background ?: view;
}

static void axs_glassify_notify_attachGradient(AxsGlassifyNotifyEffect *effect, UIView *host,
                                              CGFloat radius) {
    if (!effect.gradient || !host) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [effect.gradient removeFromSuperlayer];
    effect.gradient.frame = host.bounds;
    // 玻璃底板自己会裁圆角，挂在它里面就不需要再圆一次。
    effect.gradient.cornerRadius = (host == effect.view) ? radius : 0.0;
    effect.gradient.zPosition = 0.0;      // 同层里排最前 → 内容之下
    [host.layer insertSublayer:effect.gradient atIndex:0];
    [CATransaction commit];
    effect.gradientHost = host;
}

// 找通知标题（字体最大的 UILabel）。
static UILabel *axs_glassify_notify_findTitleLabel(UIView *view, int depth) {
    if (depth > 6) return nil;
    UILabel *best = nil;
    CGFloat bestSize = 0;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *lb = (UILabel *)sub;
            CGFloat fs = lb.font.pointSize;
            if (fs > bestSize && lb.text.length > 0) {
                best = lb;
                bestSize = fs;
            }
        }
        UILabel *deep = axs_glassify_notify_findTitleLabel(sub, depth + 1);
        if (deep && deep.font.pointSize > bestSize && deep.text.length > 0) {
            best = deep;
            bestSize = deep.font.pointSize;
        }
    }
    return best;
}

@interface AxsGlassifyNotifyAnimator () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSMutableArray<AxsGlassifyNotifyEffect *> *effects;
@property (nonatomic, assign) NSUInteger activeDrags;        // 正在拖动的卡片数（拖动中保持 tick）
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) CFTimeInterval phase;
@property (nonatomic, assign) NSUInteger frameCounter;   // 帧计数（降频更新用）
@property (nonatomic, strong) id prefsObserver;          // 配置变更→重启 tick
@property (nonatomic, strong) id glassObserver;          // 玻璃底板安装/移除→重挂渐变层

- (void)axs_glassify_notify_rehostGradientForView:(UIView *)view;
- (void)axs_glassify_notify_updateLink;
- (BOOL)axs_glassify_notify_needsTicking;
- (void)axs_glassify_notify_applyScale:(double)scale tilt:(double)tilt offsetX:(CGFloat)offsetX toView:(UIView *)view;
- (void)axs_glassify_notify_quiesce;
- (void)axs_glassify_notify_ensureFishForEffect:(AxsGlassifyNotifyEffect *)e view:(UIView *)view;
- (void)axs_glassify_notify_ensureBurstForEffect:(AxsGlassifyNotifyEffect *)e view:(UIView *)view;
- (void)axs_glassify_notify_ensureSeasonForEffect:(AxsGlassifyNotifyEffect *)e view:(UIView *)view;
- (void)axs_glassify_notify_installDragGestureOnView:(UIView *)view;
- (void)axs_glassify_notify_ensureDragGlowForEffect:(AxsGlassifyNotifyEffect *)e view:(UIView *)view;
- (void)axs_glassify_notify_handlePan:(UIPanGestureRecognizer *)pan;
- (void)axs_glassify_notify_beginDragForView:(UIView *)view;
@end

@implementation AxsGlassifyNotifyAnimator

+ (instancetype)axs_glassify_notify_shared {
    static AxsGlassifyNotifyAnimator *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _effects = [NSMutableArray array];
        // 电池监听改成按需打开（见 tick 里的 1Hz 轮询）：常开 monitoring 本身就是一笔常驻开销。
        // 空闲停表后，配置变更时重新拉起 tick（弱引用防循环）。
        __weak AxsGlassifyNotifyAnimator *weakSelf = self;
        _prefsObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AxsGlassifyPreferencesChanged
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            (void)note;
            AxsGlassifyNotifyAnimator *strongSelf = weakSelf;
            if (strongSelf && strongSelf.effects.count > 0) {
                [strongSelf axs_glassify_notify_updateLink];
            }
        }];
        // 玻璃底板装上/拆掉时把渐变层搬回正确层级。
        _glassObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AxsGlassifyPlatterGlassChanged
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            AxsGlassifyNotifyAnimator *strongSelf = weakSelf;
            id object = note.object;
            if (strongSelf && [object isKindOfClass:[UIView class]]) {
                [strongSelf axs_glassify_notify_rehostGradientForView:(UIView *)object];
            }
        }];
    }
    return self;
}

#pragma mark - 挂载 / 卸载

- (void)axs_glassify_notify_attachToView:(UIView *)view {
    if (!view) return;
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    if (![config axs_glassify_notify_isEnabled]) return;
    // 清除残留的消散动画（滚动复用会带着"隐形"fillMode 回来，导致通知消失）。
    [view.layer removeAnimationForKey:@"axs_liquid_dissolve"];
    // 入场/爆发每个视图实例只播一次（滚动复用不重播）。
    BOOL seen = [objc_getAssociatedObject(view, kAxsLiquidSeenKey) boolValue];
    objc_setAssociatedObject(view, kAxsLiquidSeenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (AxsGlassifyNotifyEffect *e in self.effects) {
        if (e.view == view) {
            [self axs_glassify_notify_refreshForView:view];
            return;
        }
    }

    // 拖动靠独立的手势识别器驱动（touchesMoved 会被列表的滚动手势取消）。
    [self axs_glassify_notify_installDragGestureOnView:view];

    AxsGlassifyNotifyEffect *effect = [[AxsGlassifyNotifyEffect alloc] init];
    effect.view = view;
    CGFloat radius = view.layer.cornerRadius > 0 ? view.layer.cornerRadius : 24.0;

    // 流动渐变背景（三段渐变横向流动）：位置由 attachGradient 决定，
    // 玻璃装好后会收到通知并重新挂到 contentView，不再盖在文字上。
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.startPoint = CGPointMake(0, 0.5);
    gradient.endPoint = CGPointMake(1, 0.5);
    gradient.opacity = 0;
    effect.gradient = gradient;
    axs_glassify_notify_attachGradient(effect, axs_glassify_notify_gradientHost(view), radius);

    // 鱼缸 / 爆发 / 粒子层按需创建：默认配置下这些效果全关。
    // 以前每张通知都白建 8 个鱼层 + 2 个发射器、同步读 PNG（滚动列表时全在主线程）。
    effect.fishLayers = [NSMutableArray array];
    effect.fishNextBubble = [NSMutableArray array];
    effect.fishFlip = [NSMutableArray array];
    effect.fishSeed = (double)arc4random_uniform(10000) / 100.0;   // 随机相位：各通知鱼游互不同步
    effect.particleJitter = 0.85 + ((double)arc4random() / UINT32_MAX) * 0.5;   // 发射率抖动 ±25%
    effect.chargeNext = 1.0;
    effect.lastParticleKey = -1;
    effect.burstPlayed = NO;
    if ([config axs_glassify_notify_fishOn]) {
        [self axs_glassify_notify_ensureFishForEffect:effect view:view];
    }
    if ([config axs_glassify_notify_burstOn]) {
        [self axs_glassify_notify_ensureBurstForEffect:effect view:view];
    }

    // 图标取色只在「跟随应用图标」时需要：16×16 位图采样不必每张卡都画一次。
    UIImageView *iconView = axs_glassify_notify_findIconView(view, 0);
    effect.iconView = iconView;
    // 跟随图标配色、或开了图标光晕（光晕用图标主色）时才需要采样。
    if (iconView.image && ([config axs_glassify_notify_colorSource] == 1 ||
                           [config axs_glassify_notify_iconGlow] > 0.001)) {
        effect.iconColor = [iconView.image axs_glassify_notify_averageColor];
    }
    effect.titleLabel = axs_glassify_notify_findTitleLabel(view, 0);

    [self.effects addObject:effect];

    // 出现动画（五档）：果冻弹跳 / 除雾渐显 / 挤压拉伸 / 凝胶膨胀。仅首次挂载播放。
    // 互斥：横幅 S 形入场开着时它独占整条 transform，这里必须让位（见 NotifyConfig）。
    NSInteger appearMode = [config axs_glassify_notify_appearMode];
    if ([config axs_glassify_notify_sbezEntranceActive]) {
        appearMode = 0;
    }
    if (appearMode > 0 && !seen) {
        double intensity = [config axs_glassify_notify_appearIntensity];
        double s = [config axs_glassify_notify_notifyScale];
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.removedOnCompletion = YES;
        if (appearMode == 1) {
            // 果冻弹跳（jelly pop）。
            CAKeyframeAnimation *pop = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
            pop.values = @[@(s * (1.0 - 0.25 * intensity)),
                           @(s * (1.0 + 0.08 * intensity)),
                           @(s * (1.0 - 0.03 * intensity)),
                           @(s)];
            pop.keyTimes = @[@0, @0.45, @0.75, @1.0];
            group.animations = @[pop];
            group.duration = 0.55;
        } else if (appearMode == 2) {
            // 除雾渐显（progressive defogging）：半透明雾感 → 清晰。
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = @0.15;
            fade.toValue = @1.0;
            CABasicAnimation *settle = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            settle.fromValue = @(s * 1.07);
            settle.toValue = @(s);
            group.animations = @[fade, settle];
            group.duration = 0.65;
        } else if (appearMode == 3) {
            // 挤压拉伸（squeeze & stretch）：X/Y 反相形变。
            CAKeyframeAnimation *sx = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.x"];
            sx.values = @[@(s), @(s * (1.0 + 0.20 * intensity)),
                          @(s * (1.0 - 0.12 * intensity)), @(s * (1.0 + 0.05 * intensity)), @(s)];
            sx.keyTimes = @[@0, @0.25, @0.55, @0.8, @1.0];
            CAKeyframeAnimation *sy = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
            sy.values = @[@(s), @(s * (1.0 - 0.18 * intensity)),
                          @(s * (1.0 + 0.12 * intensity)), @(s * (1.0 - 0.04 * intensity)), @(s)];
            sy.keyTimes = @[@0, @0.25, @0.55, @0.8, @1.0];
            group.animations = @[sx, sy];
            group.duration = 0.6;
        } else {
            // 凝胶膨胀（gel swell）：从压缩胶囊膨胀回弹。
            CAKeyframeAnimation *pop = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
            pop.values = @[@(s * (1.0 - 0.30 * intensity)),
                           @(s * (1.0 + 0.12 * intensity)),
                           @(s * (1.0 - 0.04 * intensity)),
                           @(s)];
            pop.keyTimes = @[@0, @0.5, @0.78, @1.0];
            group.animations = @[pop];
            group.duration = 0.5;
        }
        group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [view.layer addAnimation:group forKey:@"axs_liquid_appear"];
    }

    [self axs_glassify_notify_refreshForView:view];
    [self axs_glassify_notify_updateLink];

    // 到达粒子爆发：一次性播放（仅首次挂载）。延迟 0.1s 等布局完成，按实际 bounds 中心发射。
    if ([config axs_glassify_notify_burstOn] && !effect.burstPlayed && !seen) {
        effect.burstPlayed = YES;
        double bi = [config axs_glassify_notify_burstIntensity];
        __weak AxsGlassifyNotifyEffect *we = effect;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AxsGlassifyNotifyEffect *e = we;
            UIView *ev = e.view;
            if (!e || !ev || !e.burst) return;
            e.burst.frame = ev.bounds;
            e.burst.emitterPosition = CGPointMake(CGRectGetMidX(ev.bounds), CGRectGetMidY(ev.bounds));
            e.burst.emitterSize = CGSizeMake(MAX(6.0, ev.bounds.size.width * 0.3),
                                             MAX(6.0, ev.bounds.size.height * 0.3));
            e.burst.opacity = 1.0f;
            CAEmitterCell *bc = e.burst.emitterCells.firstObject;
            if (bc) {
                bc.birthRate = (float)(26.0 * bi);
                bc.scale = (float)(0.35 * (0.7 + 0.3 * bi));
                UIColor *source = e.iconColor ?: [UIColor colorWithHue:0.6 saturation:0.7 brightness:1 alpha:1];
                bc.color = source.CGColor;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AxsGlassifyNotifyEffect *e2 = we;
                if (e2 && e2.burst) e2.burst.birthRate = 0;
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AxsGlassifyNotifyEffect *e2 = we;
                if (e2 && e2.burst) e2.burst.opacity = 0;
            });
        });
    }
}

#pragma mark - 拖动（UIPanGestureRecognizer，不再依赖 touchesMoved）

// 通知列表本身就是 UIScrollView：它一开始滚动就会给卡片发 touchesCancelled，
// 用 -touchesMoved: 只能拿到开头十几点位移，S 曲线看起来就像“没反应”。
// 独立的手势识别器不受触摸取消影响，并且能显式跟系统的滚动 / 划走手势并行。
- (void)axs_glassify_notify_installDragGestureOnView:(UIView *)view {
    if (!view) return;
    if (objc_getAssociatedObject(view, kAxsGlassifyNotifyPanKey)) return;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(axs_glassify_notify_handlePan:)];
    pan.cancelsTouchesInView = NO;   // 不抢子控件的点击，也不取消系统手势
    pan.delegate = self;
    [view addGestureRecognizer:pan];
    objc_setAssociatedObject(view, kAxsGlassifyNotifyPanKey, pan,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;   // 与列表滚动、划走手势同时生效
}

- (void)axs_glassify_notify_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *view = pan.view;
    if (!view) return;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [self axs_glassify_notify_beginDragForView:view];
            break;
        case UIGestureRecognizerStateChanged: {
            // 位移取窗口坐标：卡片被列表滚动带着走时，自身坐标系里的位移会被抵消。
            UIView *reference = view.window ?: view.superview;
            CGPoint translation = [pan translationInView:reference];
            [self axs_glassify_notify_dragGradientForView:view translationY:translation.y];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self axs_glassify_notify_endDragForView:view];
            break;
        default:
            break;
    }
}

- (void)axs_glassify_notify_beginDragForView:(UIView *)view {
    self.activeDrags += 1;
    for (AxsGlassifyNotifyEffect *e in self.effects) {
        if (e.view != view) continue;
        e.dragProgress = 0;
        break;
    }
    [self axs_glassify_notify_updateLink];
}

#pragma mark - 按需创建效果层

// 拖动时的边缘色散：平时 opacity 为 0（不影响静止观感），
// 拖动中按摆幅比例亮起，松手淡出。放在卡片图层最上层，只描边不挡文字。
- (void)axs_glassify_notify_ensureDragGlowForEffect:(AxsGlassifyNotifyEffect *)e view:(UIView *)view {
    if (!e || !view || e.dragGlow) return;
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    double configured = [config axs_glassify_notify_cornerRadius];
    CGFloat radius = configured > 0.5 ? (CGFloat)configured
                                      : (view.layer.cornerRadius > 0 ? view.layer.cornerRadius : 24.0);
    CAGradientLayer *glow = [CAGradientLayer layer];
    glow.name = @"AxsGlassifyDragGlow";
    glow.startPoint = CGPointMake(0.0, 0.5);
    glow.endPoint = CGPointMake(1.0, 0.5);
    glow.colors = @[(id)[UIColor colorWithRed:0.35 green:0.85 blue:1.0 alpha:0.50].CGColor,
                    (id)[UIColor clearColor].CGColor,
                    (id)[UIColor clearColor].CGColor,
                    (id)[UIColor colorWithRed:1.0 green:0.45 blue:0.85 alpha:0.50].CGColor];
    glow.locations = @[@0.0, @0.07, @0.93, @1.0];
    glow.cornerRadius = radius;
    glow.masksToBounds = YES;
    glow.opacity = 0.0f;
    glow.zPosition = 1001.0;
    glow.frame = view.bounds;
    [view.layer addSublayer:glow];
    e.dragGlow = glow;
}

- (void)axs_glassify_notify_ensureFishForEffect:(AxsGlassifyNotifyEffect *)e view:(UIView *)view {
    if (!e || !view || e.fishLayers.count > 0) return;
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    NSArray<UIImage *> *customFish = axs_glassify_notify_customFishImages([config axs_glassify_notify_fishPng]);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSInteger i = 0; i < 8; i++) {
        CALayer *fish = [CALayer layer];
        fish.opacity = 0;
        fish.zPosition = 6;   // 背景之上、渐变之下
        [view.layer addSublayer:fish];
        [e.fishLayers addObject:fish];
        // 自定义图优先，否则手绘小鱼；sprite 高分辨率渲染，显示大小由 bounds + fish_size 控制。
        UIImage *img = customFish.count > 0
            ? customFish[(NSUInteger)i % customFish.count]
            : axs_glassify_notify_fishSprite((NSUInteger)i);
        fish.contents = (__bridge id)img.CGImage;
        [e.fishNextBubble addObject:@(1.0 + (i % 5) * 0.6 + ((double)arc4random() / UINT32_MAX) * 1.5)];
        [e.fishFlip addObject:@NO];
    }
    [CATransaction commit];
}

- (void)axs_glassify_notify_ensureBurstForEffect:(AxsGlassifyNotifyEffect *)e view:(UIView *)view {
    if (!e || !view || e.burst) return;
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    // 到达粒子爆发层（新通知瞬间光斑飞溅）。
    CAEmitterLayer *burst = [CAEmitterLayer layer];
    burst.frame = view.bounds;
    burst.emitterPosition = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    burst.emitterSize = CGSizeMake(6, 6);
    burst.emitterShape = kCAEmitterLayerRectangle;
    burst.renderMode = kCAEmitterLayerAdditive;
    burst.opacity = 0;
    // 爆发 sprite：从文件导入（burst_png），找不到回退白色光点。
    UIImage *burstSprite = nil;
    NSString *burstPath = [config axs_glassify_notify_burstPng];
    if (burstPath.length > 0) {
        burstSprite = [UIImage imageWithContentsOfFile:burstPath];
    }
    if (!burstSprite) {
        burstSprite = axs_glassify_notify_defaultBurstSprite();
    }
    CAEmitterCell *bCell = [CAEmitterCell emitterCell];
    bCell.contents = (__bridge id)burstSprite.CGImage;
    bCell.birthRate = 26.0;
    bCell.lifetime = 1.0;
    bCell.velocity = 110.0;
    bCell.velocityRange = 55.0;
    bCell.emissionRange = M_PI * 2;
    bCell.scale = burstPath.length > 0 ? 0.55f : 0.35f;
    bCell.scaleRange = 0.2;
    bCell.alphaSpeed = -1.2;
    burst.emitterCells = @[bCell];
    [view.layer addSublayer:burst];
    e.burst = burst;
}

- (void)axs_glassify_notify_ensureSeasonForEffect:(AxsGlassifyNotifyEffect *)e view:(UIView *)view {
    if (!e || !view || e.season) return;
    CAEmitterLayer *season = [CAEmitterLayer layer];
    season.frame = view.bounds;
    season.emitterPosition = CGPointMake(CGRectGetMidX(view.bounds), -6.0);
    season.emitterSize = CGSizeMake(view.bounds.size.width, 3.0);
    season.emitterShape = kCAEmitterLayerLine;
    season.renderMode = kCAEmitterLayerUnordered;
    season.opacity = 0;
    [view.layer addSublayer:season];
    e.season = season;
    e.lastParticleKey = -1;
}

// 玻璃底板装上 / 拆掉后，把渐变层搬到正确层级。
- (void)axs_glassify_notify_rehostGradientForView:(UIView *)view {
    if (!view) return;
    for (AxsGlassifyNotifyEffect *e in self.effects) {
        if (e.view != view) continue;
        CGFloat radius = view.layer.cornerRadius > 0 ? view.layer.cornerRadius : 24.0;
        UIView *host = axs_glassify_notify_gradientHost(view);
        if (!host) return;
        if (e.gradientHost == host && e.gradient.superlayer == host.layer) return;
        axs_glassify_notify_attachGradient(e, host, radius);
        return;
    }
}

- (void)axs_glassify_notify_detachView:(UIView *)view {
    for (NSInteger i = (NSInteger)self.effects.count - 1; i >= 0; i--) {
        AxsGlassifyNotifyEffect *e = self.effects[(NSUInteger)i];
        if (e.view == view || e.view == nil) {
            [e.gradient removeFromSuperlayer];
            for (CALayer *f in e.fishLayers) [f removeFromSuperlayer];
            [e.burst removeFromSuperlayer];
            [e.season removeFromSuperlayer];
            [e.iconGlow removeFromSuperlayer];
            [e.dragGlow removeFromSuperlayer];
            [self.effects removeObjectAtIndex:(NSUInteger)i];
        }
    }
    if (self.effects.count == 0) {
        self.activeDrags = 0;   // 手势可能来不及收到 Ended，别让链接空转
    }
    [self axs_glassify_notify_updateLink];
}

- (void)axs_glassify_notify_refreshForView:(UIView *)view {
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    if (![config axs_glassify_notify_isEnabled]) return;
    for (AxsGlassifyNotifyEffect *e in self.effects) {
        if (e.view != view) continue;
        UIView *v = e.view;
        if (!v) return;
        // 系统每次布局都会改写 transform：在签名记忆之前先校正一次（不同才写）。
        // 这样即使显示链接因为“没有动画”而停表，通知大小也不会失效。
        [self axs_glassify_notify_applyScale:[config axs_glassify_notify_notifyScale]
                                        tilt:[config axs_glassify_notify_tiltIntensity]
                                     offsetX:e.dragProgress
                                             * (CGFloat)[config axs_glassify_notify_sCurveAmp]
                                      toView:v];
        // 配置代次 + 卡片尺寸 + 父视图宽度都没变就直接返回。
        // 以前这里每次都要读 11 个配置键做“签名”，而 -layoutSubviews 在滚动时对每张卡都会触发。
        NSUInteger generation = [config axs_glassify_notify_generation];
        CGSize cardSize = v.bounds.size;
        CGFloat superWidth = v.superview ? v.superview.bounds.size.width : 0.0;
        if (generation == e.styleGeneration &&
            CGSizeEqualToSize(cardSize, e.styleSize) &&
            fabs(e.styleSuperWidth - superWidth) < 0.5) {
            return;
        }
        e.styleGeneration = generation;
        e.styleSize = cardSize;
        e.styleSuperWidth = superWidth;

        // ── 布局光影：宽度 / 圆角 / 透明度 / 投影 ──
        double wFrac = [config axs_glassify_notify_notifyWidth];
        if (wFrac < 0.999 && v.superview) {
            CGFloat targetW = v.superview.bounds.size.width * (CGFloat)wFrac;
            CGRect f = v.frame;
            if (targetW > 1 && fabs(f.size.width - targetW) > 1) {
                f.size.width = targetW;
                f.origin.x = (v.superview.bounds.size.width - targetW) / 2.0;
                v.frame = f;
            }
        }
        double cr = [config axs_glassify_notify_cornerRadius];
        if (cr > 0) {
            // 圆角打在背景视图上（只裁背景的角）；通知层不设 masksToBounds，
            // 否则粒子/火花/泡泡全被裁在通知内飘不出去。
            UIView *bg = axs_glassify_notify_findBackgroundView(v, 0);
            if (bg) {
                bg.layer.cornerRadius = (CGFloat)cr;
                bg.layer.masksToBounds = YES;
            } else {
                v.layer.cornerRadius = (CGFloat)cr;   // 无背景层时仅设圆角（不裁剪）
            }
        }
        double op = [config axs_glassify_notify_notifyOpacity];
        if (op < 0.999) {
            v.layer.opacity = (float)op;
        }
        double sh = [config axs_glassify_notify_shadowIntensity];
        if (sh > 0) {
            v.layer.shadowColor = [UIColor blackColor].CGColor;
            v.layer.shadowRadius = (CGFloat)(4.0 + 10.0 * sh);
            v.layer.shadowOpacity = (float)(0.4 * sh);
            v.layer.shadowOffset = CGSizeMake(0, 6);
        } else if (v.layer.shadowOpacity != 0) {
            v.layer.shadowOpacity = 0;
        }

        // ── 通知缩放 + 3D 倾斜（transform 归我们，frame 归系统） ──
        [self axs_glassify_notify_applyScale:[config axs_glassify_notify_notifyScale]
                                        tilt:[config axs_glassify_notify_tiltIntensity]
                                     offsetX:e.dragProgress
                                             * (CGFloat)[config axs_glassify_notify_sCurveAmp]
                                      toView:v];

        // ── 效果层帧同步 ──
        UIView *gradientHost = e.gradientHost ?: v;
        e.gradient.frame = gradientHost.bounds;
        e.gradient.cornerRadius = (gradientHost == v)
            ? (cr > 0 ? (CGFloat)cr : (v.layer.cornerRadius > 0 ? v.layer.cornerRadius : 24.0))
            : 0.0;
        e.burst.frame = v.bounds;
        e.burst.emitterPosition = CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds));

        // ── 标题：颜色 + 发光 ──
        UILabel *title = e.titleLabel;
        if (title) {
            if ([config axs_glassify_notify_titleColorOn]) {
                title.textColor = [UIColor colorWithHue:(CGFloat)[config axs_glassify_notify_titleHue]
                                             saturation:0.75 brightness:1 alpha:1];
            }
            double glow = [config axs_glassify_notify_titleGlow];
            if (glow > 0) {
                title.layer.shadowColor = [config axs_glassify_notify_titleColorOn]
                    ? title.textColor.CGColor
                    : [UIColor whiteColor].CGColor;
                title.layer.shadowRadius = (CGFloat)(3.0 + 6.0 * glow);
                title.layer.shadowOpacity = (float)(0.6 * glow);
                title.layer.shadowOffset = CGSizeZero;
            } else if (title.layer.shadowOpacity != 0) {
                title.layer.shadowOpacity = 0;
            }
        }

        // ── 图标：圆角 / 大小 / 发光（光晕用背后渐变层，避免与圆角裁剪冲突） ──
        UIImageView *iv = e.iconView;
        if (iv) {
            double ic = [config axs_glassify_notify_iconCorner];
            if (ic > 0) {
                iv.layer.cornerRadius = (CGFloat)ic;
                iv.layer.masksToBounds = YES;
            }
            double isc = [config axs_glassify_notify_iconScale];
            iv.layer.transform = CATransform3DMakeScale((CGFloat)isc, (CGFloat)isc, 1.0);
            double ig = [config axs_glassify_notify_iconGlow];
            if (ig > 0 && !e.iconColor && iv.image) {
                // 中途打开图标光晕时补一次主色采样（只在布局时发生一次）。
                e.iconColor = [iv.image axs_glassify_notify_averageColor];
            }
            if (ig > 0 && iv.superview) {
                if (!e.iconGlow) {
                    CAGradientLayer *glowL = [CAGradientLayer layer];
                    glowL.type = kCAGradientLayerRadial;
                    glowL.startPoint = CGPointMake(0.5, 0.5);
                    glowL.endPoint = CGPointMake(1.0, 1.0);
                    glowL.zPosition = -1;   // 图标之下
                    [iv.superview.layer insertSublayer:glowL atIndex:0];
                    e.iconGlow = glowL;
                }
                CGRect gf = CGRectInset(iv.frame, -10, -10);
                e.iconGlow.frame = gf;
                UIColor *gc = e.iconColor ?: [UIColor whiteColor];
                e.iconGlow.colors = @[(id)[gc colorWithAlphaComponent:(CGFloat)(0.55 * ig)].CGColor,
                                      (id)[UIColor clearColor].CGColor];
                e.iconGlow.locations = @[@0, @1];
            } else if (e.iconGlow) {
                e.iconGlow.opacity = 0;
            }
        }
        return;
    }
}

#pragma mark - 触摸发光（touch glow）：渐变闪亮 + 微挤压

- (void)axs_glassify_notify_touchGlowForView:(UIView *)view {
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    if (![config axs_glassify_notify_isEnabled] || ![config axs_glassify_notify_touchGlowOn]) return;
    for (AxsGlassifyNotifyEffect *e in self.effects) {
        if (e.view != view) continue;
        axs_glassify_notify_haptic([config axs_glassify_notify_touchHaptic]);
        // 渐变闪亮：透明度瞬间拉高再落回。
        float base = e.gradient.opacity;
        CAKeyframeAnimation *glow = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        glow.values = @[@(base), @(fmin(1.0f, base + 0.5f)), @(base)];
        glow.keyTimes = @[@0, @0.3, @1.0];
        glow.duration = 0.45;
        [e.gradient addAnimation:glow forKey:@"axs_touch_glow"];
        // 微挤压（果冻手感）。
        double s = [config axs_glassify_notify_notifyScale];
        CAKeyframeAnimation *squeeze = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        squeeze.values = @[@(s), @(s * 0.95), @(s * 1.02), @(s)];
        squeeze.keyTimes = @[@0, @0.3, @0.7, @1.0];
        squeeze.duration = 0.35;
        [view.layer addAnimation:squeeze forKey:@"axs_touch_squeeze"];
        return;
    }
}

#pragma mark - 滑动拖尾（拖动通知时渐变跟手 + 视图沿 S 曲线运动，松手回位）

- (void)axs_glassify_notify_dragGradientForView:(UIView *)view translationY:(CGFloat)dy {
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    CGFloat amp = (CGFloat)[config axs_glassify_notify_sCurveAmp];
    for (AxsGlassifyNotifyEffect *e in self.effects) {
        if (e.view != view) continue;
        CGFloat clamped = (CGFloat)fmax(-60.0, fmin(60.0, dy * 0.35));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        e.gradient.position = CGPointMake(CGRectGetMidX(view.bounds),
                                          CGRectGetMidY(view.bounds) + clamped);
        // S 曲线滑动：把纵向位移归一化成进度，经 S 形映射后驱动横向位移（并带一点倾转）。
        // amp = 0 时保持原有行为（transform 由缩放/倾斜单独负责，这里不动）。
        if (amp > 0) {
            // 满幅 = 一张卡片的高度（太矮的卡片给 70pt 下限）：拖出一张卡的距离就到最大摆幅。
            CGFloat span = MAX(70.0, CGRectGetHeight(view.bounds) * 0.9);
            CGFloat progress = (CGFloat)fmax(-1.0, fmin(1.0, dy / span));
            e.dragProgress = axs_glassify_notify_sCurveShape(progress);
            [self axs_glassify_notify_applyScale:[config axs_glassify_notify_notifyScale]
                                            tilt:[config axs_glassify_notify_tiltIntensity]
                                         offsetX:e.dragProgress * amp
                                          toView:view];
            // 边缘色散随摆幅增强：|拖拽进度| 本来就已经是一 0…1 的比例。
            [self axs_glassify_notify_ensureDragGlowForEffect:e view:view];
            if (e.dragGlow) {
                e.dragGlow.frame = view.bounds;
                e.dragGlow.opacity = (float)(fabs(e.dragProgress) * 0.85);
            }
        }
        [CATransaction commit];
        return;
    }
}

- (void)axs_glassify_notify_endDragForView:(UIView *)view {
    if (self.activeDrags > 0) {
        self.activeDrags -= 1;
    }
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    CGFloat amp = (CGFloat)[config axs_glassify_notify_sCurveAmp];
    for (AxsGlassifyNotifyEffect *e in self.effects) {
        if (e.view != view) continue;
        CGFloat startProgress = e.dragProgress;
        e.dragProgress = 0;
        // 弹回中心（带缓动）。
        CABasicAnimation *back = [CABasicAnimation animationWithKeyPath:@"position"];
        back.fromValue = [NSValue valueWithCGPoint:e.gradient.position];
        back.toValue = [NSValue valueWithCGPoint:
            CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))];
        back.duration = 0.35;
        back.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [e.gradient addAnimation:back forKey:@"axs_drag_back"];
        // S 曲线回位：沿同一条曲线反向滑回原点，用 keyframe 采样保持轨迹形状。
        if (e.dragGlow && e.dragGlow.opacity > 0.001f) {
            CABasicAnimation *glowOut = [CABasicAnimation animationWithKeyPath:@"opacity"];
            glowOut.fromValue = @(e.dragGlow.opacity);
            glowOut.toValue = @0.0;
            glowOut.duration = 0.28;
            [e.dragGlow addAnimation:glowOut forKey:@"axs_drag_glow_out"];
            e.dragGlow.opacity = 0.0f;
        }
        if (amp > 0 && fabs(startProgress) > 0.002) {
            CAKeyframeAnimation *slideBack = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
            NSMutableArray *values = [NSMutableArray array];
            NSMutableArray *keyTimes = [NSMutableArray array];
            double tilt = [config axs_glassify_notify_tiltIntensity];
            double scale = [config axs_glassify_notify_notifyScale];
            for (NSInteger i = 0; i <= 16; i++) {
                float k = (float)i / 16.0f;
                // 阻尼弹簧：回中心时轻微过冲（约 6%）再归零，比纯 ease-out 更像液态。
                float eased = expf(-5.5f * k) * cosf(2.0f * (float)M_PI * 0.85f * k);
                CGFloat off = (CGFloat)eased * startProgress * amp;
                CATransform3D tf = CATransform3DIdentity;
                if (tilt > 0) {
                    tf.m34 = -1.0f / 500.0f;
                    tf = CATransform3DRotate(tf, (CGFloat)(0.10 * tilt), 1, 0, 0);
                }
                tf = CATransform3DScale(tf, (CGFloat)scale, (CGFloat)scale, 1.0);
                tf = CATransform3DRotate(tf, off * 0.00116f, 0, 0, 1);
                tf = CATransform3DTranslate(tf, off, 0, 0);
                [values addObject:[NSValue valueWithCATransform3D:tf]];
                [keyTimes addObject:@(k)];
            }
            slideBack.values = values;
            slideBack.keyTimes = keyTimes;
            slideBack.duration = 0.35;
            // 缓动已经烘进 values（eased 采样），这里必须线性，否则会被再缓一次、回位发闷。
            slideBack.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
            [view.layer addAnimation:slideBack forKey:@"axs_drag_scurve_back"];
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        e.gradient.position = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
        [self axs_glassify_notify_applyScale:[config axs_glassify_notify_notifyScale]
                                        tilt:[config axs_glassify_notify_tiltIntensity]
                                     offsetX:0
                                      toView:view];
        [CATransaction commit];
        [self axs_glassify_notify_updateLink];
        return;
    }
    [self axs_glassify_notify_updateLink];
}

#pragma mark - 消失消散（划走/清除时液态溶解）

- (void)axs_glassify_notify_dissolveForView:(UIView *)view {
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    if (![config axs_glassify_notify_isEnabled] || ![config axs_glassify_notify_dissolveOn]) return;
    // 延迟 0.15s：滚动复用的 Cell 通常很快回到窗口（取消淡出）；
    // 真正被划走/清除的视图此时已离场或正在离场，淡出叠加在系统动画上。
    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *v = weakView;
        if (!v || v.window) return;   // 回到窗口 = 滚动复用，取消消散
        // 整体淡出 + 轻微收缩。
        CAAnimationGroup *group = [CAAnimationGroup animation];
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @1.0;
        fade.toValue = @0.0;
        CABasicAnimation *shrink = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        shrink.fromValue = @1.0;
        shrink.toValue = @0.88;
        group.animations = @[fade, shrink];
        group.duration = 0.25;
        group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        group.removedOnCompletion = NO;
        group.fillMode = kCAFillModeForwards;
        [v.layer addAnimation:group forKey:@"axs_liquid_dissolve"];
    });
}

#pragma mark - 动画驱动（30fps，仅有效果时运行）

- (void)axs_glassify_notify_ensureLink {
    if (self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(axs_glassify_notify_tick:)];
    // 30fps：慢动画足够流畅，省电降温。
    self.link.preferredFramesPerSecond = 30;
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (BOOL)axs_glassify_notify_needsTicking {
    if (self.effects.count == 0) return NO;
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    if (![config axs_glassify_notify_isEnabled]) return NO;
    // 拖动中必须保持 tick：系统布局随时改写 transform，S 位移要靠逐帧校正补回去。
    if (self.activeDrags > 0) return YES;
    // 只有这几项需要逐帧驱动。出现/爆发/溶解/触摸发光都是 CA 动画，不需要 tick。
    return [config axs_glassify_notify_gradientOn] ||
           [config axs_glassify_notify_fishOn] ||
           [config axs_glassify_notify_particleOn] ||
           [config axs_glassify_notify_chargeFx];
}

// 只有渐变时 15fps 足够（颜色本来就只按 10Hz 级变化）；有鱼/粒子/蝴蝶才要 30fps。
- (NSUInteger)axs_glassify_notify_preferredFPS {
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    if (self.activeDrags > 0 ||
        [config axs_glassify_notify_fishOn] ||
        [config axs_glassify_notify_particleOn] ||
        [config axs_glassify_notify_chargeFx]) {
        return 30;
    }
    return 15;
}

- (void)axs_glassify_notify_updateLink {
    if ([self axs_glassify_notify_needsTicking]) {
        [self axs_glassify_notify_ensureLink];
        self.link.preferredFramesPerSecond = [self axs_glassify_notify_preferredFPS];
    } else {
        // 停表前先把逐帧驱动的图层收干净，否则关掉渐变/游鱼时画面会冻在原地。
        [self axs_glassify_notify_quiesce];
        [self axs_glassify_notify_stopLink];
    }
}

- (void)axs_glassify_notify_quiesce {
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    BOOL gradientOn = [config axs_glassify_notify_gradientOn];
    BOOL fishOn = [config axs_glassify_notify_fishOn];
    BOOL particleOn = [config axs_glassify_notify_particleOn];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (AxsGlassifyNotifyEffect *e in self.effects) {
        if (!gradientOn && e.gradient.opacity != 0.0f) e.gradient.opacity = 0.0f;
        if (!fishOn) {
            for (CALayer *fish in e.fishLayers) {
                if (fish.opacity != 0.0f) fish.opacity = 0.0f;
            }
        }
        if (!particleOn && e.season.opacity != 0.0f) e.season.opacity = 0.0f;
    }
    [CATransaction commit];
}

// 只在真的不同时才写 layer.transform：读 + 比较几乎免费，写入会进 CA 事务。
// offsetX：S 曲线滑动的当前横向偏移（pt，0 = 无偏移），叠加在缩放/倾斜之上。
// 蜿蜒排列占用中的 cell 直接跳过：排版 pass 是这些 cell transform 的唯一写手，
// 它写进 model 的偏移量会被这里当"脏值"抹掉，两个所有权互相顶掉就是抖动。
- (void)axs_glassify_notify_applyScale:(double)scale tilt:(double)tilt offsetX:(CGFloat)offsetX toView:(UIView *)view {
    if (!view) return;
    if (axs_glassify_sbez_viewSerpDisplaced(view)) return;
    CATransform3D desired = CATransform3DIdentity;
    if (tilt > 0) {
        desired.m34 = -1.0f / 500.0f;
        desired = CATransform3DRotate(desired, (CGFloat)(0.10 * tilt), 1, 0, 0);
    }
    desired = CATransform3DScale(desired, (CGFloat)scale, (CGFloat)scale, 1.0);
    if (offsetX != 0) {
        // 横向位移时带一点倾转（60pt ≈ 4°），摆动看起来是“甩”而不是平移。
        desired = CATransform3DRotate(desired, offsetX * 0.00116f, 0, 0, 1);
        desired = CATransform3DTranslate(desired, offsetX, 0, 0);
    }
    if (!CATransform3DEqualToTransform(view.layer.transform, desired)) {
        view.layer.transform = desired;
    }
}

- (void)axs_glassify_notify_stopLink {
    [self.link invalidate];
    self.link = nil;
}

- (void)axs_glassify_notify_tick:(CADisplayLink *)link {
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    if (![config axs_glassify_notify_isEnabled]) {
        [self axs_glassify_notify_stopLink];
        return;
    }
    double t = self.phase += link.duration > 0 ? link.duration : 1.0 / 30.0;
    NSUInteger fc = self.frameCounter++;
    BOOL slowTick = ((fc % 3) == 0);     // 渐变颜色/位点分配：10Hz（慢动画足够）
    BOOL paramTick = ((fc % 10) == 0);   // 粒子参数/发射几何：3Hz
    float dt = (float)(link.duration > 0 ? link.duration : 1.0 / 30.0);

    // ── tick 级配置快照：每帧只查一次配置，循环内零字典查询 ──
    BOOL gradientOn = [config axs_glassify_notify_gradientOn];
    BOOL darkDim = [config axs_glassify_notify_darkDim];
    NSInteger colorSource = [config axs_glassify_notify_colorSource];
    BOOL fishOn = [config axs_glassify_notify_fishOn];
    NSInteger fishCount = [config axs_glassify_notify_fishCount];
    double fishSize = [config axs_glassify_notify_fishSize];
    double bubbleSize = [config axs_glassify_notify_bubbleSize];
    double bubbleOpacity = [config axs_glassify_notify_bubbleOpacity];
    BOOL chargeOn = [config axs_glassify_notify_chargeFx];
    BOOL particleOn = [config axs_glassify_notify_particleOn];
    NSInteger pDir = [config axs_glassify_notify_particleDir];
    double pSize = [config axs_glassify_notify_particleSize];
    double density = [config axs_glassify_notify_particleDensity];
    double gSpeed = [config axs_glassify_notify_gradientSpeed];
    double gOpacity = [config axs_glassify_notify_gradientOpacity];
    double hue1 = [config axs_glassify_notify_gradientHue1];
    double hue2 = [config axs_glassify_notify_gradientHue2];
    double nScale = [config axs_glassify_notify_notifyScale];
    double tiltI = [config axs_glassify_notify_tiltIntensity];
    CGFloat sCurveAmp = (CGFloat)[config axs_glassify_notify_sCurveAmp];
    // 低电量模式 + 电池状态：查询不便宜（batteryState 要走 IOKit），降到 1Hz 轮询。
    static BOOL cachedLowPower = NO;
    static UIDeviceBatteryState cachedBatteryState = UIDeviceBatteryStateUnknown;
    static CFTimeInterval lastPowerPoll = 0.0;
    CFTimeInterval nowPoll = CFAbsoluteTimeGetCurrent();
    if (nowPoll - lastPowerPoll > 1.0) {
        lastPowerPoll = nowPoll;
        cachedLowPower = [NSProcessInfo processInfo].isLowPowerModeEnabled;
        // 只有开着充电特效时才需要电池状态；不用时把 monitoring 关掉。
        UIDevice *device = [UIDevice currentDevice];
        if (device.batteryMonitoringEnabled != chargeOn) {
            device.batteryMonitoringEnabled = chargeOn;
        }
        cachedBatteryState = chargeOn ? device.batteryState : UIDeviceBatteryStateUnknown;
    }
    // 低电量保护：降粒子密度、降吐泡频率、关充电特效。
    BOOL lowPower = [config axs_glassify_notify_lowPowerGuard] && cachedLowPower;
    BOOL charging = NO;
    if (chargeOn && !lowPower) {
        charging = (cachedBatteryState == UIDeviceBatteryStateCharging ||
                    cachedBatteryState == UIDeviceBatteryStateFull);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (NSInteger i = (NSInteger)self.effects.count - 1; i >= 0; i--) {
        AxsGlassifyNotifyEffect *e = self.effects[(NSUInteger)i];
        UIView *v = e.view;
        if (!v) {
            [e.gradient removeFromSuperlayer];
            for (CALayer *f in e.fishLayers) [f removeFromSuperlayer];
            [e.burst removeFromSuperlayer];
            [e.season removeFromSuperlayer];
            [e.iconGlow removeFromSuperlayer];
            [e.dragGlow removeFromSuperlayer];
            [self.effects removeObjectAtIndex:(NSUInteger)i];
            continue;
        }

        // 通知缩放 + 3D 倾斜：系统布局会改写 transform，所以每帧校一次；
        // 但只在真的不同时才写（写入会进 CA 事务，读+比较几乎免费）。
        // S 曲线滑动：把当前拖拽进度换算成横向偏移一起写回，系统改写后自愈。
        [self axs_glassify_notify_applyScale:nScale tilt:tiltI
                                     offsetX:e.dragProgress * sCurveAmp
                                      toView:v];

        // 流动渐变：配色来源（手动双色 / 应用图标取色 / 壁纸取色）+ 色相漂移 + 位点往复。
        if (gradientOn) {
            double dim = 1.0;
            if (darkDim) {
                if (@available(iOS 12.0, *)) {
                    if (v.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) dim = 0.72;
                }
            }
            float gAlpha = (float)(gOpacity * dim);
            if (e.lastGradientAlpha != gAlpha) {
                e.lastGradientAlpha = gAlpha;
                e.gradient.opacity = gAlpha;
            }
            // 轴向缓慢旋转（便宜，逐帧）。
            double ang = t * 0.12;
            e.gradient.startPoint = CGPointMake(0.5 + 0.5 * cos(ang), 0.5 + 0.5 * sin(ang));
            e.gradient.endPoint = CGPointMake(0.5 - 0.5 * cos(ang), 0.5 - 0.5 * sin(ang));
            // 颜色/位点需要分配 NSArray/UIColor —— 降到 10Hz（色带推移肉眼仍顺滑）。
            if (slowTick) {
                // 切到「跟随应用图标」后补一次采样（attach 时只在已选该模式才采）。
                if (colorSource == 1 && !e.iconColor && e.iconView.image) {
                    e.iconColor = [e.iconView.image axs_glassify_notify_averageColor];
                }
                UIColor *c1, *c2, *cm;
                if (colorSource == 1 && e.iconColor) {
                    // 应用图标取色：同色系微漂移（每条通知专属色）。
                    CGFloat h, s, b;
                    [e.iconColor getHue:&h saturation:&s brightness:&b alpha:nil];
                    c1 = [UIColor colorWithHue:(CGFloat)fmod(h + 0.05 + t * 0.02, 1.0) saturation:MAX(s, 0.5f) brightness:1 alpha:1];
                    c2 = [UIColor colorWithHue:(CGFloat)fmod(h - 0.05 + t * 0.02, 1.0) saturation:MAX(s, 0.5f) brightness:1 alpha:1];
                    cm = [UIColor colorWithHue:(CGFloat)fmod(h + t * 0.02, 1.0) saturation:MAX(s, 0.5f) brightness:1 alpha:1];
                } else if (colorSource == 2) {
                    // 壁纸取色：主色 ± 微漂移。
                    UIColor *wp = axs_glassify_notify_wallpaperColor();
                    CGFloat h = 0.6f, s = 0.5f;
                    if (wp) [wp getHue:&h saturation:NULL brightness:NULL alpha:nil];
                    c1 = [UIColor colorWithHue:(CGFloat)fmod(h + 0.06 + t * 0.02, 1.0) saturation:MAX(s, 0.4f) brightness:1 alpha:1];
                    c2 = [UIColor colorWithHue:(CGFloat)fmod(h - 0.06 + t * 0.02, 1.0) saturation:MAX(s, 0.4f) brightness:1 alpha:1];
                    cm = [UIColor colorWithHue:(CGFloat)fmod(h + t * 0.02, 1.0) saturation:MAX(s, 0.4f) brightness:1 alpha:1];
                } else {
                    c1 = [UIColor colorWithHue:(CGFloat)fmod(hue1 + t * 0.04, 1.0) saturation:0.75 brightness:1 alpha:1];
                    c2 = [UIColor colorWithHue:(CGFloat)fmod(hue2 + t * 0.04, 1.0) saturation:0.75 brightness:1 alpha:1];
                    cm = [UIColor colorWithHue:(CGFloat)fmod((hue1 + hue2) / 2.0 + t * 0.04, 1.0) saturation:0.75 brightness:1 alpha:1];
                }
                // 色带波浪推移（每条通知错相，两端固定不卡顿）。
                double wave = (sin(t * gSpeed * 1.8 + e.fishSeed) + 1.0) / 2.0;
                double w1 = 0.18 + 0.22 * wave;
                e.gradient.locations = @[@0, @(w1), @(1.0 - w1), @1];
                e.gradient.colors = @[(id)c1.CGColor, (id)cm.CGColor, (id)c2.CGColor, (id)cm.CGColor];
            }
        } else if (e.gradient.opacity != 0) {
            e.gradient.opacity = 0;
            e.lastGradientAlpha = 0;
        }

        // 鱼缸游鱼：前 fish_count 条可见，正弦游动 + 方向翻转（数量/大小实时生效）。
        if (fishOn) {
            // 首次打开游鱼时按需建层（默认配置下 attach 不建这些层）。
            if (e.fishLayers.count == 0) {
                [self axs_glassify_notify_ensureFishForEffect:e view:v];
            }
            double fishCountD = (double)fishCount;
            for (NSInteger fi = 0; fi < (NSInteger)e.fishLayers.count; fi++) {
                CALayer *fish = e.fishLayers[(NSUInteger)fi];
                if (fi >= fishCountD) {
                    if (fish.opacity != 0) fish.opacity = 0;
                    continue;
                }
                if (fish.opacity != 0.9f) fish.opacity = 0.9f;
                CGFloat displaySize = (CGFloat)(22.0 * fishSize);
                if (paramTick) {
                    fish.bounds = CGRectMake(0, 0, displaySize, displaySize);
                }
                double speed = 0.35 + (fi % 4) * 0.09;
                double phase = (t + e.fishSeed) * speed + fi * 1.3;
                CGRect b = v.bounds;
                CGFloat fishX = (CGFloat)(sin(phase) * b.size.width * 0.32) + CGRectGetMidX(b);
                CGFloat fishY = (CGFloat)(cos(phase * 0.7) * 7.0) + b.size.height * (0.40 + 0.09 * (fi % 3));
                fish.position = CGPointMake(fishX, fishY);
                // 方向翻转：只在掉头瞬间写 transform（图头朝左，向右游时镜像）。
                BOOL flip = cos(phase) > 0;
                NSNumber *lastFlip = (fi < (NSInteger)e.fishFlip.count) ? e.fishFlip[(NSUInteger)fi] : nil;
                if (lastFlip.boolValue != flip) {
                    if (fi < (NSInteger)e.fishFlip.count) e.fishFlip[(NSUInteger)fi] = @(flip);
                    fish.transform = flip ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity;
                }

                // 鱼吐泡泡：倒计时到 0 时从嘴边冒一个泡泡，上浮渐隐后自清。
                if (fi < (NSInteger)e.fishNextBubble.count) {
                    double remain = [e.fishNextBubble[(NSUInteger)fi] doubleValue] - (double)dt;
                    if (remain <= 0) {
                        remain = (1.4 + ((double)arc4random() / UINT32_MAX) * 1.8) * (lowPower ? 2.0 : 1.0);
                        CGFloat bs = (CGFloat)((3.5 + fishSize * 2.5) * bubbleSize);
                        CALayer *bub = [CALayer layer];
                        bub.bounds = CGRectMake(0, 0, bs, bs);
                        bub.cornerRadius = bs / 2.0;
                        bub.borderWidth = 1.1;
                        bub.borderColor = [UIColor colorWithWhite:1 alpha:(CGFloat)(0.8 * bubbleOpacity)].CGColor;
                        bub.backgroundColor = [UIColor colorWithWhite:1 alpha:(CGFloat)(0.18 * bubbleOpacity)].CGColor;
                        CGFloat dir = cos(phase) < 0 ? -1 : 1;
                        bub.position = CGPointMake(fish.position.x + dir * displaySize * 0.42,
                                                   fish.position.y - displaySize * 0.12);
                        bub.zPosition = 7;
                        [v.layer addSublayer:bub];
                        CABasicAnimation *rise = [CABasicAnimation animationWithKeyPath:@"position.y"];
                        rise.fromValue = @(bub.position.y);
                        rise.toValue = @(bub.position.y - 42);
                        CABasicAnimation *bfade = [CABasicAnimation animationWithKeyPath:@"opacity"];
                        bfade.fromValue = @0.9;
                        bfade.toValue = @0.0;
                        CAAnimationGroup *bg = [CAAnimationGroup animation];
                        bg.animations = @[rise, bfade];
                        bg.duration = 2.2;
                        bg.removedOnCompletion = YES;
                        [bub addAnimation:bg forKey:@"axs_bubble_rise"];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.3 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            [bub removeFromSuperlayer];
                        });
                    }
                    e.fishNextBubble[(NSUInteger)fi] = @(remain);
                }
            }
        } else {
            // 关闭时只把鱼隐藏一次（之后 opacity 已为 0，零写入）。
            for (CALayer *fish in e.fishLayers) {
                if (fish.opacity != 0) fish.opacity = 0;
            }
        }

        // 充电特效：亮晶晶的蝴蝶从底部飘起（充电中且未低电量时，快照判定）。
        if (charging) {
            e.chargeNext -= (double)dt;
            if (e.chargeNext <= 0) {
                e.chargeNext = 1.4 + ((double)arc4random() / UINT32_MAX) * 1.4;
                static UIImage *butterflySprite = nil;
                static dispatch_once_t onceToken;
                dispatch_once(&onceToken, ^{
                    butterflySprite = axs_glassify_notify_butterflyImage(96.0);
                });
                if (butterflySprite) {
                    CGFloat side = 22.0 * (CGFloat)[config axs_glassify_notify_chargeSize];
                    CGFloat span = MAX(side, v.bounds.size.width - side);
                    CGFloat startX = side * 0.5 + (CGFloat)(((double)arc4random() / UINT32_MAX) * span);
                    CGFloat startY = CGRectGetMaxY(v.bounds) - side * 0.4;

                    CALayer *fly = [CALayer layer];
                    fly.bounds = CGRectMake(0, 0, side, side);
                    fly.contents = (__bridge id)butterflySprite.CGImage;
                    fly.opacity = 0.0f;
                    fly.position = CGPointMake(startX, startY);
                    fly.zPosition = 7;
                    [v.layer addSublayer:fly];

                    CFTimeInterval duration = 2.8;
                    // 上升
                    CABasicAnimation *rise = [CABasicAnimation animationWithKeyPath:@"position.y"];
                    rise.fromValue = @(startY);
                    rise.toValue = @(startY - 96.0);
                    // 横向飘移
                    CGFloat drift = (10.0 + (CGFloat)(((double)arc4random() / UINT32_MAX) * 16.0))
                                    * (arc4random_uniform(2) == 0 ? 1.0 : -1.0);
                    CAKeyframeAnimation *sway = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
                    sway.values = @[@(startX), @(startX + drift * 0.6),
                                    @(startX + drift), @(startX + drift * 0.5)];
                    sway.keyTimes = @[@0, @0.35, @0.7, @1.0];
                    // 扇翅膀：横向压缩 + 轻微旋转
                    CAKeyframeAnimation *flap = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.x"];
                    flap.values = @[@1.0, @0.38, @1.0, @0.38, @1.0, @0.38, @1.0];
                    flap.duration = 0.62;
                    flap.repeatCount = 4.0f;
                    CAKeyframeAnimation *tilt = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
                    tilt.values = @[@(-0.10), @(0.10), @(-0.06), @(0.06)];
                    tilt.keyTimes = @[@0, @0.4, @0.75, @1.0];
                    // 淡入淡出
                    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
                    fade.values = @[@0.0, @0.95, @0.95, @0.0];
                    fade.keyTimes = @[@0, @0.12, @0.72, @1.0];

                    CAAnimationGroup *group = [CAAnimationGroup animation];
                    group.animations = @[rise, sway, flap, tilt, fade];
                    group.duration = duration;
                    group.removedOnCompletion = YES;
                    [fly addAnimation:group forKey:@"axs_charge_butterfly"];

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)((duration + 0.2) * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [fly removeFromSuperlayer];
                    });
                }
            }
        }

        // 粒子特效（图片文件导入）：几何/参数降到 3Hz 同步（分配与 emitter 写入大头）。
        if (particleOn) {
            if (!e.season) {
                [self axs_glassify_notify_ensureSeasonForEffect:e view:v];
            }
            if (e.season.opacity != 0.85f) e.season.opacity = 0.85f;
            if (paramTick) {
                e.season.frame = v.bounds;
                // 按方向布置发射器几何。
                CGRect pb = v.bounds;
                if (pDir == 1) {
                    e.season.emitterShape = kCAEmitterLayerLine;
                    e.season.emitterPosition = CGPointMake(CGRectGetMidX(pb), CGRectGetMaxY(pb) + 6.0);
                    e.season.emitterSize = CGSizeMake(pb.size.width, 3.0);
                } else if (pDir == 2) {
                    e.season.emitterShape = kCAEmitterLayerLine;
                    e.season.emitterPosition = CGPointMake(-6.0, CGRectGetMidY(pb));
                    e.season.emitterSize = CGSizeMake(3.0, pb.size.height);
                } else if (pDir == 3) {
                    e.season.emitterShape = kCAEmitterLayerRectangle;
                    e.season.emitterPosition = CGPointMake(CGRectGetMidX(pb), CGRectGetMidY(pb));
                    e.season.emitterSize = CGSizeMake(8.0, 8.0);
                } else {
                    e.season.emitterShape = kCAEmitterLayerLine;
                    e.season.emitterPosition = CGPointMake(CGRectGetMidX(pb), -6.0);
                    e.season.emitterSize = CGSizeMake(pb.size.width, 3.0);
                }
                NSString *paths = [config axs_glassify_notify_particlePng];
                NSInteger styleKey = 9000 + (NSInteger)((NSUInteger)[paths hash] % 100000);
                // 路径变了，或上次是回退态（文件可能后放进来）→ 2 秒重试一次。
                CFTimeInterval now = CFAbsoluteTimeGetCurrent();
                BOOL needRebuild = (e.lastParticleKey != styleKey);
                if (!needRebuild && e.lastParticleKey == -1 && now - e.lastLoadAttempt > 2.0) {
                    needRebuild = YES;
                }
                if (needRebuild) {
                    e.lastLoadAttempt = now;
                    // 从文件导入图片（最多 6 张，全部加载失败回退 ✨）。
                    NSMutableArray<UIImage *> *sprites = [NSMutableArray array];
                    for (NSString *raw in [paths componentsSeparatedByString:@";"]) {
                        NSString *p = [raw stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        if (p.length == 0) continue;
                        UIImage *img = [UIImage imageWithContentsOfFile:p];
                        if (img) [sprites addObject:img];
                        if (sprites.count >= 6) break;
                    }
                    if (sprites.count == 0) {
                        // 回退 ✨ 并标记回退态（lastParticleKey = -1），后续定时重试。
                        [sprites addObject:axs_glassify_notify_emojiImage(@"✨", 24.0)];
                        e.lastParticleKey = -1;
                    } else {
                        e.lastParticleKey = styleKey;
                    }
                    // 每张图一个 cell，混合飘落。
                    NSMutableArray<CAEmitterCell *> *cells = [NSMutableArray array];
                    for (UIImage *sp in sprites) {
                        CAEmitterCell *pCell = [CAEmitterCell emitterCell];
                        pCell.contents = (__bridge id)sp.CGImage;
                        // 寿命/速度随机抖动：各通知发射图案不同步。
                        pCell.lifetime = 4.6f + ((float)arc4random() / UINT32_MAX) * 1.2f;
                        pCell.velocity = 28.0f + ((float)arc4random() / UINT32_MAX) * 10.0f;
                        pCell.velocityRange = 14.0f;
                        pCell.emissionLongitude = M_PI_2;   // 向下飘落
                        pCell.emissionRange = M_PI / 6.0;
                        pCell.spin = 0.5f;
                        pCell.spinRange = 1.2f;
                        pCell.alphaSpeed = -0.12f;
                        [cells addObject:pCell];
                    }
                    e.season.emitterCells = cells;
                }
                // 数量（密度）/ 大小 / 发射角 同步（3Hz 足够，滑块响应延迟 ≤0.33s）。
                NSArray<CAEmitterCell *> *cells = e.season.emitterCells;
                float perRate = (float)(3.5 * density * (lowPower ? 0.4 : 1.0) * e.particleJitter
                                        / (double)MAX((NSUInteger)1, cells.count));
                double pLongitude = (pDir == 1) ? -M_PI_2 : ((pDir == 2) ? 0.0 : M_PI_2);
                double pRange = (pDir == 3) ? M_PI * 2 : M_PI / 6.0;   // 多向 = 全方向发散
                float pVelocity = (pDir == 2) ? 26.0f : ((pDir == 3) ? 36.0f : 32.0f);
                for (CAEmitterCell *pc in cells) {
                    pc.birthRate = perRate;
                    pc.scale = (float)(0.5 * pSize);
                    pc.scaleRange = (float)(0.2 * pSize);
                    pc.emissionLongitude = pLongitude;
                    pc.emissionRange = pRange;
                    pc.velocity = (float)(pVelocity * e.particleJitter);   // 各通知速度不同步
                }
            }
        } else if (e.season.opacity != 0) {
            e.season.opacity = 0;
        }
    }

    [CATransaction commit];

    if (self.effects.count == 0) {
        self.activeDrags = 0;
        [self axs_glassify_notify_stopLink];
        return;
    }
    // 全关且无缩放/倾斜：停表省电（配置变更通知 / 新通知挂载会自动重启）。
    // 缩放/倾斜必须保持 tick 存活——系统随时改写 transform，停表就会被覆盖（大小失效根因）。
    BOOL transformActive = (fabs(nScale - 1.0) > 0.001) || (tiltI > 0.001) ||
                           self.activeDrags > 0;
    if (!gradientOn && !fishOn && !particleOn && !charging && !transformActive) {
        [self axs_glassify_notify_stopLink];
        return;
    }
    // 自适应帧率：纯慢效（渐变）15fps，鱼/粒子/充电等快效 30fps。
    NSInteger want = (fishOn || particleOn || charging || self.activeDrags > 0) ? 30 : 15;
    if (self.link && self.link.preferredFramesPerSecond != (int)want) {
        self.link.preferredFramesPerSecond = (int)want;
    }
}

- (void)dealloc {
    if (self.prefsObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.prefsObserver];
    }
    [self axs_glassify_notify_stopLink];
}

@end
