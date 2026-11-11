#import "AxsGlassifySBezierCurve.h"
#import "AxsGlassifyNotifyConfig.h"
#import "AxsGlassifySBezierDiagnostics.h"
#import "AxsGlassifySBezier.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <string.h>

// Entrance effects offered in the panel; the value is stored in `scrollEffect`.
enum {
    axs_glassify_sbez_effectNone = 0,
    axs_glassify_sbez_effectFade = 1,
    axs_glassify_sbez_effectGrow = 2,
    axs_glassify_sbez_effectStretch = 3,
    axs_glassify_sbez_effectSlide = 4,
    axs_glassify_sbez_effectRise = 5,
    axs_glassify_sbez_effectFlip = 6,
    axs_glassify_sbez_effectS = 7,
    // Rotation family: these need a perspective term (m34 on the transform) or a
    // 3D rotation just reads as a flat squash.
    axs_glassify_sbez_effectFlipY = 8,
    axs_glassify_sbez_effectSpinZ = 9,
    axs_glassify_sbez_effectFlip3D = 10,
    axs_glassify_sbez_effectSpinSlide = 11,
    axs_glassify_sbez_effectFlip3DSlide = 12,
};

// Depth of field for the 3D variants; larger is a gentler perspective.
static const CGFloat axs_glassify_sbez_perspectiveDistance = 700.0;

static CATransform3D axs_glassify_sbez_perspective(CATransform3D transform) {
    transform.m34 = -1.0 / axs_glassify_sbez_perspectiveDistance;
    return transform;
}

// Cache of the "is this the notification list" verdict. A list is only
// classified once, so a wrong guess costs a single read afterwards.
static const char axs_glassify_sbez_listKeyIsNotificationList = 0;
static const char axs_glassify_sbez_listKeyLogged = 0;
// Set while a list has only just appeared, so opening Notification Center does
// not animate every row at once; scrolling afterwards does animate.
static const char axs_glassify_sbez_listKeyJustAppeared = 0;
// Timestamp of the last effect played on a view, so the several triggers that can
// fire for one appearance do not animate it twice.
static const char axs_glassify_sbez_listKeyLastEffectAt = 0;
// ── S 形蜿蜒排列（v8：接管卡片自己的 setter）──
// v7（在列表 layoutSubviews 之后覆盖 frame）真机：不闪了，但摆幅/缩小拉满
// 仍纹丝不动 —— 摆卡片的不是列表自己，是外层容器，它在我们之后还会再写一次;
// 任何"事后覆盖"都慢一步，抢不赢。
//
// v8 不再事后，改成**接管写入点**：hook NCNotificationListCell 的 -setFrame:
// 与 -setCenter:。无论哪个布局发起者，最终都必须经过这两个咽喉 —— 系统在
// 这里交出坐标，我们就地把它们按 y 相位弯成 S 再转交真实 setter。写者只有
// 一个（弯折后的值就是系统要写的值），所以没有竞态、没有覆盖、没有闪烁。
//
// 三条铁律（违反任何一条都会立刻死循环 —— 旧版卡死设备的教训）：
//  1. 写入闸：我们写 frame/center 会同步重入同一个 hook，用 thread-local
//     标志挡住，重入时原样放行，绝不二次弯折。
//  2. 基准只取"系统交进来的那个值"（参数），绝不从 cell.frame 回推 ——
//     回推会把弯折值当基准，偏移叠进偏移。
//  3. 反馈检测：若系统下一次交进来的值 == 我们上次写出去的值，说明它把
//     我们的输出当成了输入（回环），该卡片永久跳过弯折，诊断报 fbk=。
// One queued pass per runloop tick: layout + setContentOffset + cell-add all
// fire several times per frame; the pass itself is idempotent, so coalescing
// is free correctness, not an optimisation.
static const char axs_glassify_sbez_listKeyPassQueued = 0;

// Fast mirror of the config verdict, refreshed on every preferences reload and
// at load. setFrame: is a per-layout hot hook: when the effect is off the path
// must cost ONE static read and nothing else.
static BOOL axs_glassify_sbez_serpFastOn = NO;

// 减弱动态效果同样是镜像：UIAccessibilityIsReduceMotionEnabled() 是系统调用，
// 绝不能放在每帧几十次的 setFrame: 里。低频点（reload / passNow）刷新。
static BOOL axs_glassify_sbez_serpReduce = NO;

static BOOL axs_glassify_sbez_serpLive(void) {
    return axs_glassify_sbez_serpFastOn && !axs_glassify_sbez_serpReduce;
}

// v8 关联键：系统交进来的原值 / 我们写出去的值（frame 与 center 各一对）。
static const char axs_glassify_sbez_keySerpInFrame = 0;
static const char axs_glassify_sbez_keySerpOutFrame = 0;
static const char axs_glassify_sbez_keySerpInCenter = 0;
static const char axs_glassify_sbez_keySerpOutCenter = 0;
static const char axs_glassify_sbez_keySerpNoBend = 0;   // 反馈回环：该卡片不再弯

// 写入闸与计数。bentFrame/bentCenter 进诊断：>0 才证明系统真的走的是
// 这个 setter（本方案唯一需要真机确认的前提）。
// __thread：写入会同步重入同一个 hook，闸必须按线程隔离。
static __thread BOOL axs_glassify_sbez_serpWriting = NO;
static volatile NSUInteger axs_glassify_sbez_serpBentFrame = 0;
static volatile NSUInteger axs_glassify_sbez_serpBentCenter = 0;
static volatile NSUInteger axs_glassify_sbez_serpFeedback = 0;

// Weak registry of cells we have ever bent: 关开关时把它们恢复成系统原值,
// 面板刚打开（静止、系统不再重摆）时靠它们补一次弯折。
static NSHashTable<UIView *> *axs_glassify_sbez_serpDisplaced(void) {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

// Weak registry of every scroll view this process ever recognised (recordList
// runs once per list). When the panel turns the serpentine ON there is *no*
// scroll, no new cell and no window event - the toggle itself is the only cue,
// so re-passing must be driven from the known lists, not from waiting for one.
static NSHashTable<UIScrollView *> *axs_glassify_sbez_serpLists(void) {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

// ── S 形蜿蜒排列（v7：帧偏移版）──
// 真机 v6 录屏：静止仍整齐 + 卡片持续闪现。闪现是 v6 在跟系统抢
// layer.transform 所有权的结果：我们清掉系统常驻动画 -> 呈现值跳到我们的
// model 位移；系统下一次布局写回 identity 并重挂动画 -> 跳回直线。每拍最多
// 两次可见跳变 = 闪烁，而且系统总写在最后，S 永远看不见。抢属性抢不赢。
//
// v7 把位移与缩小写进 cell 的 frame，并且只在列表自己的 layoutSubviews
// 之后（同一趟布局里当最后写手）执行 —— frame 本来就是列表在写的属性，
// 这不是抢，是接力：系统摆完，我们按 y 相位挪位。transform 完全让给系统/
// 玻璃（入场动画、notify_scale 照常合成在帧之上），无闪烁，也不需要定时器。
//
// 边界：只对普通 scroll 列表生效（真机诊断：锁屏列表 NCNotificationListView
// 是 表格=0 集合=0 的普通 scroll 列表）。UITableView/UICollectionView 里改
// cell frame 会触发系统重新布局、可能成环 —— 那两类直接跳过。

// Geometric notes (v7 frame offsets; why this cannot loop the way the old
// per-frame transform version did):
// - The only property written is a cell's own `frame`, and only inside the
//   list's own layout pass (after %orig) or an idempotent queued pass. The list
//   does not re-layout because a cell moved - it lays cells out, it is not
//   notified by them - so pass -> layout -> pass cycles cannot form.
// - Every pass recomputes from the stored *system base* frame, and re-bases
//   whenever the current frame differs from what we last wrote. System wins
//   the base, we only append the offset: offsets can never compound.
// - transform is never touched, so the system's own cell animations and the
//   glass engine's scale/tilt compose on top of the frame naturally, with no
//   ownership fight and no visible snapping.
static void axs_glassify_sbez_serpGeometryForY(CGFloat y, CGFloat amplitude, CGFloat wavelength,
                                               CGFloat shrink, CGFloat *outX, CGFloat *outScale) {
    CGFloat phase = (CGFloat)M_PI * 2.0f * y / MAX(wavelength, 60.0f);
    CGFloat s = sinf(phase);
    *outX = amplitude * s;
    // 用户定稿：不存在"回到中线就恢复整齐"。波峰/波谷（|sin|=1）缩到最大
    // (1-shrink)；穿越中线的卡片也保留 0.35·shrink 的"穿越态"缩小 —— 整屏
    // 任何时候看都是一条连续的蛇形，不会有一排全尺寸居中的正常卡片。
    // （倾转档已移除：旋转只能走 transform，而 transform 归系统所有 ——
    //  v6 抢它的代价就是满屏闪烁。位移与缩小走 setter，零冲突。）
    CGFloat a = fabs(s);
    *outScale = 1.0f - shrink * (0.35f + 0.65f * a);
}

// 写入闸：包住我们自己那次 %orig，防止重入二次弯折。
void axs_glassify_sbez_serpWriteBegin(void) { axs_glassify_sbez_serpWriting = YES; }
void axs_glassify_sbez_serpWriteEnd(void)   { axs_glassify_sbez_serpWriting = NO; }

static BOOL axs_glassify_sbez_serpCGRectNear(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) < 1.0 && fabs(a.origin.y - b.origin.y) < 1.0
        && fabs(a.size.width - b.size.width) < 1.0 && fabs(a.size.height - b.size.height) < 1.0;
}

// 把系统交来的 frame 弯成 S：横向按 y 相位摆位，拐弯处缩小（保持中心不动)。
// 纯函数：同一个输入永远同一个输出，所以系统重复摆位不会让画面变化。
static CGRect axs_glassify_sbez_serpBendGeometry(CGRect sys) {
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    CGFloat amp = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_amp" defaultValue:28.0];
    CGFloat wavelength = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_wavelength" defaultValue:260.0];
    CGFloat shrink = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_shrink" defaultValue:0.18];
    amp = MAX(0.0f, MIN(amp, 120.0f));
    wavelength = MAX(80.0f, MIN(wavelength, 800.0f));
    shrink = MAX(0.0f, MIN(shrink, 0.5f));
    if (sys.size.width < 1.0f || sys.size.height < 1.0f) {
        return sys;
    }
    CGFloat dx, sc;
    axs_glassify_sbez_serpGeometryForY(sys.origin.y + sys.size.height * 0.5f,
                                       amp, wavelength, shrink, &dx, &sc);
    CGFloat w = sys.size.width * sc;
    CGFloat h = sys.size.height * sc;
    return CGRectMake(sys.origin.x + (sys.size.width - w) * 0.5f + dx,
                      sys.origin.y + (sys.size.height - h) * 0.5f, w, h);
}

static void axs_glassify_sbez_serpDiag(void);

static void axs_glassify_sbez_serpRestoreCell(UIView *cell) {
    NSValue *inF = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpInFrame);
    NSValue *outF = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpOutFrame);
    // 只有当前 frame 仍是我们写出去的那个值时才恢复 —— 系统已经自己改过
    // 就别去打断它（也避免把系统的最新布局当成"我们的"给抹掉）。
    if (inF != nil && outF != nil && axs_glassify_sbez_serpCGRectNear(cell.frame, outF.CGRectValue)) {
        axs_glassify_sbez_serpWriteBegin();
        cell.frame = inF.CGRectValue;
        axs_glassify_sbez_serpWriteEnd();
    }
    NSValue *inC = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpInCenter);
    NSValue *outC = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpOutCenter);
    if (inC != nil && outC != nil && CGPointEqualToPoint(cell.center, outC.CGPointValue)) {
        axs_glassify_sbez_serpWriteBegin();
        cell.center = inC.CGPointValue;
        axs_glassify_sbez_serpWriteEnd();
    }
    [axs_glassify_sbez_serpDisplaced() removeObject:cell];
}

static void axs_glassify_sbez_serpRestoreAllDisplaced(void) {
    for (UIView *cell in [axs_glassify_sbez_serpDisplaced().allObjects copy]) {
        axs_glassify_sbez_serpRestoreCell(cell);
    }
}

// 系统交进来一个 frame，我们要不要把它弯成 S？要则通过 out 返回弯折值。
// 返回值 YES = 调用方应当 %orig(bent)；NO = 原样放行。
BOOL axs_glassify_sbez_serpBendFrame(UIView *cell, CGRect in, CGRect *out) {
    *out = in;
    if (!axs_glassify_sbez_serpLive() || axs_glassify_sbez_serpWriting) {
        return NO;                       // 铁律 1：我们自己写的那次，放行
    }
    if ([objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpNoBend) boolValue]) {
        return NO;                       // 已判定反馈回环
    }
    NSValue *outV = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpOutFrame);
    if (outV != nil && axs_glassify_sbez_serpCGRectNear(in, outV.CGRectValue)) {
        // 铁律 3：系统把我们上次写出的值当输入交回来 = 回环。这张卡片以后
        // 不再弯折（否则偏移会叠进偏移），并计入诊断 fbk=。
        objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpNoBend, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        axs_glassify_sbez_serpFeedback++;
        return NO;
    }
    *out = axs_glassify_sbez_serpBendGeometry(in);
    if (CGRectEqualToRect(*out, in)) {
        return NO;
    }
    // 铁律 2：基准 = 系统交进来的 in，绝不从 cell.frame 回推。
    objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpInFrame,
                             [NSValue valueWithCGRect:in], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpOutFrame,
                             [NSValue valueWithCGRect:*out], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [axs_glassify_sbez_serpDisplaced() addObject:cell];
    axs_glassify_sbez_serpBentFrame++;
    return YES;
}

// setCenter: 路径：只弯横向位移（center 改不了尺寸，缩小在这条路上不生效）。
// 两条路的计数分开上报，bentF / bentC，真机一眼看出系统用的是哪个 setter。
BOOL axs_glassify_sbez_serpBendCenter(UIView *cell, CGPoint in, CGPoint *out) {
    *out = in;
    if (!axs_glassify_sbez_serpLive() || axs_glassify_sbez_serpWriting) {
        return NO;
    }
    if ([objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpNoBend) boolValue]) {
        return NO;
    }
    NSValue *outV = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpOutCenter);
    if (outV != nil && CGPointEqualToPoint(in, outV.CGPointValue)) {
        objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpNoBend, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        axs_glassify_sbez_serpFeedback++;
        return NO;
    }
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    CGFloat amp = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_amp" defaultValue:28.0];
    CGFloat wavelength = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_wavelength" defaultValue:260.0];
    CGFloat shrink = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_shrink" defaultValue:0.18];
    CGFloat dx, sc;
    axs_glassify_sbez_serpGeometryForY(in.y, MAX(0.0f, MIN(amp, 120.0f)),
                                       MAX(80.0f, MIN(wavelength, 800.0f)),
                                       MAX(0.0f, MIN(shrink, 0.5f)), &dx, &sc);
    *out = CGPointMake(in.x + dx, in.y);
    if (CGPointEqualToPoint(*out, in)) {
        return NO;
    }
    objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpInCenter,
                             [NSValue valueWithCGPoint:in], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpOutCenter,
                             [NSValue valueWithCGPoint:*out], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [axs_glassify_sbez_serpDisplaced() addObject:cell];
    axs_glassify_sbez_serpBentCenter++;
    return YES;
}

// 静止时系统不会再摆卡片，所以"刚打开开关"这一刻必须自己补一次：
// 登记表里有历史值的，按历史基准重弯；还没被弯过的（首次开），拿当前
// frame 当系统基准弯一次 —— 此刻 frame 一定是系统的笔直值。
static void axs_glassify_sbez_serpRepassAllKnownLists(void) {
    if (!axs_glassify_sbez_serpLive()) {
        return;
    }
    for (UIView *cell in [axs_glassify_sbez_serpDisplaced().allObjects copy]) {
        NSValue *inF = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpInFrame);
        if (inF == nil) {
            continue;
        }
        CGRect bent;
        CGRect sys = inF.CGRectValue;
        bent = axs_glassify_sbez_serpBendGeometry(sys);
        if (!CGRectEqualToRect(bent, cell.frame)) {
            axs_glassify_sbez_serpWriteBegin();
            cell.frame = bent;
            axs_glassify_sbez_serpWriteEnd();
            objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpOutFrame,
                                     [NSValue valueWithCGRect:bent], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (UIScrollView *list in [axs_glassify_sbez_serpLists().allObjects copy]) {
        if (list.window == nil) {
            continue;
        }
        for (UIView *cell in list.subviews) {
            const char *name = object_getClassName(cell);
            if (name == NULL || strstr(name, "Notification") == NULL) {
                continue;
            }
            if (objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpInFrame) != nil) {
                continue;                      // 登记表已处理
            }
            CGRect bent = axs_glassify_sbez_serpBendGeometry(cell.frame);
            if (CGRectEqualToRect(bent, cell.frame)) {
                continue;
            }
            objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpInFrame,
                                     [NSValue valueWithCGRect:cell.frame],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpOutFrame,
                                     [NSValue valueWithCGRect:bent], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [axs_glassify_sbez_serpDisplaced() addObject:cell];
            axs_glassify_sbez_serpWriteBegin();
            cell.frame = bent;
            axs_glassify_sbez_serpWriteEnd();
            axs_glassify_sbez_serpBentFrame++;
        }
    }
}

// 权威谓词 -> static 镜像（热 hook 只读这个 BOOL）。
void axs_glassify_sbez_serpUpdateGate(void) {
    axs_glassify_sbez_serpFastOn =
        [[AxsGlassifyNotifyConfig axs_glassify_notify_shared] axs_glassify_notify_sbezSerpActive];
    axs_glassify_sbez_serpReduce = UIAccessibilityIsReduceMotionEnabled();
}

// 诊断一行（面板「S 形贝塞尔诊断」可见）：门控、减弱动态、已知列表数、
// 位移中的卡片数，外加头 3 张在屏卡片的 (dx,dy,k) —— 当前 frame 相对系统
// 基准的位移与宽比。dx!=0 但肉眼直线 = 列表在我们之后又重摆过；moved=0 =
// 没排到卡片。MergeIfChanged 内存去重，只在变化时落盘，调用点全在低频路径。
static void axs_glassify_sbez_serpDiag(void) {
    BOOL reduce = axs_glassify_sbez_serpReduce;
    NSUInteger lists = axs_glassify_sbez_serpLists().allObjects.count;
    NSUInteger moved = axs_glassify_sbez_serpDisplaced().allObjects.count;
    NSMutableArray *samples = [NSMutableArray array];
    NSUInteger inwin = 0, nobend = 0;
    for (UIView *cell in axs_glassify_sbez_serpDisplaced().allObjects) {
        if ([objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpNoBend) boolValue]) {
            nobend++;
        }
        if (cell.window == nil) {
            continue;
        }
        inwin++;
        if (samples.count >= 3) {
            continue;
        }
        NSValue *inF = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpInFrame);
        CGRect f = cell.frame, b = inF.CGRectValue;
        // (dx,k)=当前 frame 相对系统交进来的原值的横向位移与宽比。
        // dx!=0 而肉眼仍是直线 => 外层又改写了一次（那就要连外层一起接管）。
        [samples addObject:[NSString stringWithFormat:@"(dx=%.0f dy=%.0f k=%.2f)",
                            f.origin.x - b.origin.x, f.origin.y - b.origin.y,
                            b.size.width > 0 ? f.size.width / b.size.width : 0.0]];
    }
    // bentF / bentC 是本轮的判据：都为 0 => 系统根本没走这两个 setter,
    // 需要换接管点（外层容器 / 图层 position）；只 bentC>0 => 尺寸缩小
    // 在这条路上无效，观感会只有横向摆动。
    axs_glassify_sbez_diagnosticsMergeIfChanged(@"serp",
        [NSString stringWithFormat:@"on=%d reduce=%d lists=%lu cells=%lu inwin=%lu bentF=%lu bentC=%lu fbk=%lu nobend=%lu sample=%@",
         (int)axs_glassify_sbez_serpFastOn, (int)reduce,
         (unsigned long)lists, (unsigned long)moved, (unsigned long)inwin,
         (unsigned long)axs_glassify_sbez_serpBentFrame,
         (unsigned long)axs_glassify_sbez_serpBentCenter,
         (unsigned long)axs_glassify_sbez_serpFeedback, (unsigned long)nobend,
         samples.count ? [samples componentsJoinedByString:@" "] : @"(无在屏)"]);
}

// 面板保存（主线程通知）：三种触发都必须主动重排，不能"等下一个事件"——
// 用户在设置页打开开关再回锁屏时，列表早已在窗口、没有新卡片、也不会滚动，
// 没有任何被动触发源会命中（这正是真机"静止仍整齐"的根因）。
//
// 快照竞态：本通知由主配置发出；本模块用的 NotifyConfig 快照在另一条串行队列
// 重载，此刻可能还是旧值（没人再发第二条通知）。所以连拍四下（当拍 / 下一拍 /
// 0.12s / 0.4s），每拍用权威谓词重校门控；0.4s 那拍同时盖住"列表刚出现、cell
// 还没挂上"的挂载竞态。帧偏移幂等（比较后才写），连拍无闪烁风险。
void axs_glassify_sbez_serpPreferencesChanged(void) {
    void (^tick)(void) = ^{
        axs_glassify_sbez_serpUpdateGate();
        if (axs_glassify_sbez_serpLive()) {
            axs_glassify_sbez_serpRepassAllKnownLists();
        } else {
            axs_glassify_sbez_serpRestoreAllDisplaced();
        }
        axs_glassify_sbez_serpDiag();
    };
    tick();
    dispatch_async(dispatch_get_main_queue(), ^{ tick(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ tick(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ tick(); });
}

static NSArray *axs_glassify_sbez_visibleCells(UIScrollView *scrollView) {
    if ([scrollView isKindOfClass:[UITableView class]]) {
        return ((UITableView *)scrollView).visibleCells;
    }
    if ([scrollView isKindOfClass:[UICollectionView class]]) {
        return ((UICollectionView *)scrollView).visibleCells;
    }
    // Plain scroll list (NCNotificationListView): its entries sit directly in
    // subviews. Same strstr rule as the entrance path - no string allocs on a
    // per-frame path, and only the list's own direct children are scanned.
    NSMutableArray *out = nil;
    for (UIView *sub in scrollView.subviews) {
        const char *name = object_getClassName(sub);
        if (name != NULL && strstr(name, "Notification") != NULL) {
            if (out == nil) {
                out = [NSMutableArray array];
            }
            [out addObject:sub];
        }
    }
    return out;
}

static BOOL axs_glassify_sbez_looksLikeNotification(NSString *name) {
    return name != nil && [name rangeOfString:@"Notification"].location != NSNotFound;
}

// The cell is not necessarily a direct subview of the list, so the enclosing list
// is found by walking up a few levels rather than trusting superview alone.
static UIScrollView *axs_glassify_sbez_enclosingList(UIView *view) {
    NSInteger depth = 0;
    for (UIView *current = view; current != nil && depth < 8; current = current.superview, depth++) {
        if ([current isKindOfClass:[UITableView class]] ||
            [current isKindOfClass:[UICollectionView class]]) {
            return (UIScrollView *)current;
        }
    }
    return nil;
}

// Every effect is a Core Animation on the cell's layer, so the cell's model
// transform is never touched and the list's own layout cannot fight or compound it.
//
// Transform values must be CATransform3D: CALayer.transform is a CATransform3D, and
// handing Core Animation a CGAffineTransform here silently produces nothing.
static CAAnimation *axs_glassify_sbez_effectAnimation(NSInteger effect,
                                                    CATransform3D base,
                                                    CGFloat baseOpacity,
                                                    CGFloat slideDistance,
                                                    CGFloat riseDistance,
                                                    CGFloat amplitude,
                                                    CGFloat span,
                                                    CGFloat rate,
                                                    NSTimeInterval duration) {
    if (!isfinite(duration) || duration <= 0.0) {
        return nil;
    }

    // base / baseOpacity = 卡片当前的 model transform 与不透明度。合并后玻璃引擎会把
    // notify_scale / tilt 写成 model transform，所有档位都必须以它为基准起落：
    // 终点 == 基准值时动画移除零跳变，中途也不会把缩放态的卡片拍回原尺寸。
    CAAnimation *animation = nil;
    switch (effect) {
        case axs_glassify_sbez_effectFade: {
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = @0.0f;
            fade.toValue = @(baseOpacity);
            animation = fade;
            break;
        }
        case axs_glassify_sbez_effectGrow: {
            CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform"];
            grow.fromValue = [NSValue valueWithCATransform3D:CATransform3DScale(base, 0.01, 0.01, 1.0)];
            grow.toValue = [NSValue valueWithCATransform3D:base];
            animation = grow;
            break;
        }
        case axs_glassify_sbez_effectStretch: {
            CABasicAnimation *stretch = [CABasicAnimation animationWithKeyPath:@"transform"];
            stretch.fromValue = [NSValue valueWithCATransform3D:CATransform3DScale(base, 0.01, 1.0, 1.0)];
            stretch.toValue = [NSValue valueWithCATransform3D:base];
            animation = stretch;
            break;
        }
        case axs_glassify_sbez_effectSlide: {
            CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform"];
            slide.fromValue = [NSValue valueWithCATransform3D:
                               CATransform3DTranslate(base, slideDistance, 0.0, 0.0)];
            slide.toValue = [NSValue valueWithCATransform3D:base];
            animation = slide;
            break;
        }
        case axs_glassify_sbez_effectRise: {
            CABasicAnimation *rise = [CABasicAnimation animationWithKeyPath:@"transform"];
            rise.fromValue = [NSValue valueWithCATransform3D:
                              CATransform3DTranslate(base, 0.0, riseDistance, 0.0)];
            rise.toValue = [NSValue valueWithCATransform3D:base];
            animation = rise;
            break;
        }
        case axs_glassify_sbez_effectFlip: {
            CABasicAnimation *flip = [CABasicAnimation animationWithKeyPath:@"transform"];
            flip.fromValue = [NSValue valueWithCATransform3D:
                              CATransform3DRotate(base, (CGFloat)M_PI_2, 1.0, 0.0, 0.0)];
            flip.toValue = [NSValue valueWithCATransform3D:base];
            animation = flip;
            break;
        }
        case axs_glassify_sbez_effectS: {
            if (!isfinite(span) || span <= 0.0f) {
                span = 0.5f;
            }
            if (!isfinite(rate) || rate <= 0.0f) {
                rate = 1.0f;
            }
            if (!isfinite(amplitude)) {
                amplitude = 0.0f;
            }
            if (!isfinite(riseDistance)) {
                riseDistance = 0.0f;
            }
            NSInteger frames = 24;
            NSMutableArray *values = [NSMutableArray arrayWithCapacity:(NSUInteger)frames + 1];
            for (NSInteger i = 0; i <= frames; i++) {
                CGFloat t = (CGFloat)i / (CGFloat)frames;
                // Ease out, so the cell decelerates as it lands.
                CGFloat progress = 1.0f - (1.0f - t) * (1.0f - t);
                CGFloat remaining = 1.0f - progress;
                CGFloat dx = amplitude * sinf(2.0f * (CGFloat)M_PI * span * progress * rate) * remaining;
                CGFloat dy = riseDistance * remaining;
                [values addObject:[NSValue valueWithCATransform3D:CATransform3DTranslate(base, dx, dy, 0.0f)]];
            }
            CAKeyframeAnimation *sCurve = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
            sCurve.values = values;
            sCurve.calculationMode = kCAAnimationLinear;
            animation = sCurve;
            break;
        }
        case axs_glassify_sbez_effectFlipY: {
            CABasicAnimation *flipY = [CABasicAnimation animationWithKeyPath:@"transform"];
            flipY.fromValue = [NSValue valueWithCATransform3D:axs_glassify_sbez_perspective(
                               CATransform3DRotate(base, (CGFloat)M_PI_2, 0.0, 1.0, 0.0))];
            flipY.toValue = [NSValue valueWithCATransform3D:base];
            animation = flipY;
            break;
        }
        case axs_glassify_sbez_effectSpinZ: {
            CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform"];
            spin.fromValue = [NSValue valueWithCATransform3D:
                              CATransform3DRotate(base, (CGFloat)-M_PI_2, 0.0, 0.0, 1.0)];
            spin.toValue = [NSValue valueWithCATransform3D:base];
            animation = spin;
            break;
        }
        case axs_glassify_sbez_effectFlip3D: {
            CABasicAnimation *flip3d = [CABasicAnimation animationWithKeyPath:@"transform"];
            flip3d.fromValue = [NSValue valueWithCATransform3D:axs_glassify_sbez_perspective(
                                CATransform3DRotate(base, (CGFloat)M_PI_2, 1.0, 0.0, 0.0))];
            flip3d.toValue = [NSValue valueWithCATransform3D:base];
            animation = flip3d;
            break;
        }
        case axs_glassify_sbez_effectSpinSlide: {
            // Rotate first (about the cell's own anchor), then carry it in from the
            // right, so it arrives spinning rather than pivoting in place.
            CATransform3D start = CATransform3DConcat(
                CATransform3DTranslate(base, slideDistance, 0.0, 0.0),
                CATransform3DMakeRotation((CGFloat)-M_PI_4, 0.0, 0.0, 1.0));
            CABasicAnimation *spinSlide = [CABasicAnimation animationWithKeyPath:@"transform"];
            spinSlide.fromValue = [NSValue valueWithCATransform3D:axs_glassify_sbez_perspective(start)];
            spinSlide.toValue = [NSValue valueWithCATransform3D:base];
            animation = spinSlide;
            break;
        }
        case axs_glassify_sbez_effectFlip3DSlide: {
            CATransform3D start = CATransform3DConcat(
                CATransform3DTranslate(base, 0.0, riseDistance, 0.0),
                CATransform3DMakeRotation((CGFloat)M_PI / 3.0, 1.0, 0.0, 0.0));
            CABasicAnimation *flipSlide = [CABasicAnimation animationWithKeyPath:@"transform"];
            flipSlide.fromValue = [NSValue valueWithCATransform3D:axs_glassify_sbez_perspective(start)];
            flipSlide.toValue = [NSValue valueWithCATransform3D:base];
            animation = flipSlide;
            break;
        }
        default:
            return nil;
    }

    animation.duration = duration;
    animation.fillMode = kCAFillModeRemoved;
    animation.removedOnCompletion = YES;
    // A keyframe animation already carries its own easing; a global timing
    // function would flatten it into a straight move.
    if ([animation isKindOfClass:[CABasicAnimation class]]) {
        ((CABasicAnimation *)animation).timingFunction =
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    }
    return animation;
}

@implementation UIScrollView (AxsGlassifySBezierList)

- (BOOL)axs_glassify_sbez_isNotificationList {
    NSNumber *cached = objc_getAssociatedObject(self, &axs_glassify_sbez_listKeyIsNotificationList);
    if (cached != nil) {
        return cached.boolValue;
    }

    // The class name is the primary signal, and the list does NOT have to be a table
    // or a collection: on current iOS the lock screen list is NCNotificationListView,
    // a plain UIScrollView subclass. Requiring a table/collection rejected it before
    // the name was ever considered.
    if (axs_glassify_sbez_looksLikeNotification(NSStringFromClass([self class]))) {
        objc_setAssociatedObject(self, &axs_glassify_sbez_listKeyIsNotificationList, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }

    // Fallback: a table or collection whose visible cells look like notifications.
    NSArray *cells = axs_glassify_sbez_visibleCells(self);
    if (cells.count == 0) {
        return NO;  // undecided; try again once it has content
    }
    BOOL matched = NO;
    for (UIView *cell in cells) {
        if (axs_glassify_sbez_looksLikeNotification(NSStringFromClass([cell class]))) {
            matched = YES;
            break;
        }
    }
    objc_setAssociatedObject(self, &axs_glassify_sbez_listKeyIsNotificationList, @(matched),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return matched;
}

// Records what this scroll view actually is, once per list. The record always goes
// into the self-report the panel displays, so a wrong guess is diagnosable without
// reaching the system log; the NSLog happens only when 调试日志 is on.
- (void)axs_glassify_sbez_recordList {
    if (objc_getAssociatedObject(self, &axs_glassify_sbez_listKeyLogged) != nil) {
        return;
    }
    objc_setAssociatedObject(self, &axs_glassify_sbez_listKeyLogged, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // 蜿蜒的「已知列表」登记处：recordList 每个列表只跑一次，这里加一次弱引用。
    [axs_glassify_sbez_serpLists() addObject:self];

    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    NSArray *cells = axs_glassify_sbez_visibleCells(self);
    NSMutableArray *names = [NSMutableArray array];
    for (UIView *cell in cells) {
        [names addObject:NSStringFromClass([cell class])];
    }
    // A plain scroll view has no visibleCells, so fall back to its subtree: that is
    // where the real cell class shows up.
    if (names.count == 0) {
        NSInteger budget = 6;
        for (UIView *subview in self.subviews) {
            if (budget <= 0) {
                break;
            }
            budget--;
            [names addObject:NSStringFromClass([subview class])];
            NSInteger inner = 2;
            for (UIView *nested in subview.subviews) {
                if (inner <= 0) {
                    break;
                }
                inner--;
                [names addObject:[NSString stringWithFormat:@"└%@", NSStringFromClass([nested class])]];
            }
        }
    }
    BOOL matches = axs_glassify_sbez_looksLikeNotification(NSStringFromClass([self class]));
    if (!matches) {
        for (UIView *cell in cells) {
            if (axs_glassify_sbez_looksLikeNotification(NSStringFromClass([cell class]))) {
                matches = YES;
                break;
            }
        }
    }

    BOOL enabled = [config axs_glassify_notify_isEnabled];
    NSInteger effect = (NSInteger)llround([config axs_glassify_notify_sbezDoubleForKey:@"sbz_scroll_effect"
                                                                  defaultValue:0.0]);
    NSString *summary = [NSString stringWithFormat:@"%@ 表格=%d 集合=%d 匹配=%d cells=[%@]",
                         NSStringFromClass([self class]),
                         (int)[self isKindOfClass:[UITableView class]],
                         (int)[self isKindOfClass:[UICollectionView class]],
                         (int)matches,
                         [names componentsJoinedByString:@", "]];
    axs_glassify_sbez_diagnosticsNoteList(summary);
    axs_glassify_sbez_diagnosticsMergeIfChanged(@"config",
        [NSString stringWithFormat:@"enabled=%d effect=%d debug=%d",
         (int)enabled, (int)effect,
         (int)[config axs_glassify_notify_sbezBoolForKey:@"sbz_debug_log" defaultValue:NO]]);

    if ([config axs_glassify_notify_sbezBoolForKey:@"sbz_debug_log" defaultValue:NO]) {
        NSLog(@"[Glassify-SBez] scrollView=%@ table=%d collection=%d matches=%d"
              @" enabled=%d effect=%d cells=[%@]",
              NSStringFromClass([self class]),
              (int)[self isKindOfClass:[UITableView class]],
              (int)[self isKindOfClass:[UICollectionView class]],
              (int)matches, (int)enabled, (int)effect,
              [names componentsJoinedByString:@", "]);
    }
}

// Also arms the "just appeared" guard, which is what stops the initial fill of the
// list from animating every row at once.
//
// 合并后的节流：这个 hook 挂在 UIScrollView 上，SpringBoard 里每一个滚动视图出现都
// 会走一遍。recordList 自带「每个列表只跑一次」的缓存，保留（诊断独立于开关是原
// 插件的设计）；但「刚出现」标记的写入和 async 派发只在滚动入场真的会用到时才做，
// 总开关关闭时这里等于零额外开销。
- (void)axs_glassify_sbez_noteAppeared {
    [self axs_glassify_sbez_recordList];

    if (![[AxsGlassifyNotifyConfig axs_glassify_notify_shared] axs_glassify_notify_sbezScrollActive]) {
        return;
    }
    objc_setAssociatedObject(self, &axs_glassify_sbez_listKeyJustAppeared, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIScrollView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScrollView *list = weakSelf;
        if (list != nil) {
            objc_setAssociatedObject(list, &axs_glassify_sbez_listKeyJustAppeared, nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
    });
    // v8：列表刚出现不需要事后 pass —— 系统随后就会对每个 cell 调
    // setFrame:/setCenter:，弯折在那里完成。
}

// One pass per runloop tick at most (see keyPassQueued). The pass is idempotent
// because every target recomputes from the stored original base.
- (void)axs_glassify_sbez_serpPassQueued {
    // v8：开着（且没开减弱动态）时这里无事可做 —— 弯折在卡片自己的 setter 里
    // 完成，不需要事后 pass。只有"欠着恢复"才排队（两道静态读 + 一次 count,
    // 滚动热路径可忽略），passNow 负责把弯过的卡片拉回系统原值。
    if (axs_glassify_sbez_serpLive()) {
        return;
    }
    if ([axs_glassify_sbez_serpDisplaced() count] == 0) {
        return;
    }
    if (objc_getAssociatedObject(self, &axs_glassify_sbez_listKeyPassQueued) != nil) {
        return;
    }
    objc_setAssociatedObject(self, &axs_glassify_sbez_listKeyPassQueued, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIScrollView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScrollView *list = weakSelf;
        if (list != nil) {
            [list axs_glassify_sbez_serpPassNow];
        }
    });
}

- (void)axs_glassify_sbez_serpPassNow {
    objc_setAssociatedObject(self, &axs_glassify_sbez_listKeyPassQueued, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    // 异步跳转之后重读一次权威谓词校正镜像：排队与执行之间面板可能已改过。
    axs_glassify_sbez_serpUpdateGate();

    // v8：开着时这里什么都不做 —— 弯折发生在卡片自己的 setFrame:/setCenter:
    // 里（系统每次摆位都会经过），不需要事后 pass。这里只负责"关/减弱动态"
    // 那一侧的恢复，任何一次列表事件都能自愈门控竞态。
    if (!axs_glassify_sbez_serpLive()) {
        NSUInteger before = axs_glassify_sbez_serpDisplaced().allObjects.count;
        axs_glassify_sbez_serpRestoreAllDisplaced();
        if (axs_glassify_sbez_serpDisplaced().allObjects.count != before) {
            axs_glassify_sbez_serpDiag();
        }
        return;
    }
}

@end

@implementation UIView (AxsGlassifySBezierCellEntrance)

- (void)axs_glassify_sbez_cellDidMoveToSuperview {
    if (self.superview == nil) {
        return;
    }
    UIScrollView *list = axs_glassify_sbez_enclosingList(self);
    if (list == nil) {
        return;
    }
    [self axs_glassify_sbez_applyFromList:list];
}

// The notification list turned out to be NCNotificationListView, a plain
// UIScrollView subclass, so a view whose direct superview is such a list is treated
// as a cell as well. Only the direct superview is inspected: walking the hierarchy
// for every subview add would be far too expensive on a hook this hot, and the class
// name test avoids allocating a string.
- (void)axs_glassify_sbez_viewDidMoveToSuperview {
    UIView *superview = self.superview;
    if (superview == nil || ![superview isKindOfClass:[UIScrollView class]]) {
        return;
    }
    const char *name = object_getClassName(superview);
    if (name == NULL || strstr(name, "Notification") == NULL) {
        return;
    }
    [self axs_glassify_sbez_applyFromList:(UIScrollView *)superview];
}

- (void)axs_glassify_sbez_applyFromList:(UIScrollView *)list {
    // One appearance can arrive through several hooks at once: the generic view hook
    // and the table/collection cell hook both fire for a cell. Bail out before doing
    // any work at all - the row lookup below allocates, so this is worth short
    // circuiting.
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSNumber *previous = objc_getAssociatedObject(self, &axs_glassify_sbez_listKeyLastEffectAt);
    if (previous != nil && now - previous.doubleValue < 0.3) {
        return;
    }

    // A list that was already on screen never fires didMoveToWindow again, so the
    // one-shot report is also driven from here.
    [list axs_glassify_sbez_recordList];

    // Classify before the switches so the report still fills in when the effect is
    // off; the verdict is cached, so this is one read afterwards.
    if (![list axs_glassify_sbez_isNotificationList]) {
        return;
    }

    // 减弱动态效果 is the system-level request for less motion. Honouring it is both
    // correct and free: the whole effect is skipped.
    if (UIAccessibilityIsReduceMotionEnabled()) {
        return;
    }

    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    if (![config axs_glassify_notify_isEnabled]) {
        return;
    }
    NSInteger effect = (NSInteger)llround([config axs_glassify_notify_sbezDoubleForKey:@"sbz_scroll_effect"
                                                                  defaultValue:0.0]);
    if (effect <= axs_glassify_sbez_effectNone) {
        return;
    }
    if (objc_getAssociatedObject(list, &axs_glassify_sbez_listKeyJustAppeared) != nil) {
        return;
    }
    if (CGRectGetWidth(list.bounds) < 1.0f) {
        return;
    }

    // Seeded from the row so a notification keeps its own strength and rate, and
    // differs from its neighbours instead of the whole list moving as one. A plain
    // scroll view has no index path, so the subview order stands in for the row.
    NSInteger row = 0;
    if ([list isKindOfClass:[UITableView class]]) {
        NSIndexPath *indexPath = [(UITableView *)list indexPathForCell:(UITableViewCell *)self];
        if (indexPath != nil) {
            row = indexPath.section * 4096 + indexPath.row;
        }
    } else if ([list isKindOfClass:[UICollectionView class]]) {
        NSIndexPath *indexPath = [(UICollectionView *)list indexPathForCell:(UICollectionViewCell *)self];
        if (indexPath != nil) {
            row = indexPath.section * 4096 + indexPath.item;
        }
    } else {
        NSUInteger index = [list.subviews indexOfObjectIdenticalTo:self];
        row = (index == NSNotFound) ? 0 : (NSInteger)index;
    }

    objc_setAssociatedObject(self, &axs_glassify_sbez_listKeyLastEffectAt, @(now),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakCell = self;
    // Deferred like Cask does it: lists add cells from inside their own layout pass,
    // and starting the animation there invites a layout fight. The async hop still
    // lands before the frame is committed, so there is no flash at rest.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *cell = weakCell;
        if (cell == nil || cell.superview == nil) {
            return;
        }
        [cell axs_glassify_sbez_playEffect:effect row:row];
    });
}

- (void)axs_glassify_sbez_playEffect:(NSInteger)effect row:(NSInteger)row {
    // Recorded at most once per (class, effect) pair. Comparing the class directly
    // keeps this path free of string building: it runs for every cell that appears,
    // and an unconditional plist write here would mean disk IO on every scroll.
    static Class lastEffectClass = Nil;
    static NSInteger lastEffectValue = -1;
    if (lastEffectClass != [self class] || lastEffectValue != effect) {
        lastEffectClass = [self class];
        lastEffectValue = effect;
        axs_glassify_sbez_diagnosticsMerge(@{
            @"lastEffect": [NSString stringWithFormat:@"%@ 特效 %d",
                            NSStringFromClass([self class]), (int)effect],
        });
    }

    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    NSTimeInterval duration = [config axs_glassify_notify_sbezDoubleForKey:@"sbz_scroll_duration" defaultValue:0.5];
    duration = MAX(0.05, MIN(duration, 3.0));
    CGFloat amplitude = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_scroll_amplitude" defaultValue:40.0];
    CGFloat span = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_scroll_span" defaultValue:0.5];
    CGFloat variation = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_scroll_variation" defaultValue:0.5];
    if (variation < 0.0f) {
        variation = 0.0f;
    }
    if (variation > 1.0f) {
        variation = 1.0f;
    }

    uint32_t state = (uint32_t)(row * 2654435761u) + 0x9E3779B9u;
    CGFloat magnitudeScale = 1.0f - variation * 0.5f * axs_glassify_sbez_randomUnit(&state);
    CGFloat rateScale = 1.0f - variation * 0.3f * axs_glassify_sbez_randomUnit(&state);

    CGSize size = self.bounds.size;
    CGFloat riseDistance = (size.height * 0.6f + 30.0f) * magnitudeScale;
    CGFloat slideDistance = size.width * magnitudeScale;

    CAAnimation *animation = axs_glassify_sbez_effectAnimation(effect,
                                                             self.layer.transform,
                                                             (CGFloat)self.layer.opacity,
                                                             slideDistance,
                                                             riseDistance,
                                                             amplitude * magnitudeScale,
                                                             span,
                                                             rateScale,
                                                             duration);
    if (animation == nil) {
        return;
    }

    [self.layer removeAnimationForKey:@"axs_glassify_sbez_cell_effect"];
    [self.layer addAnimation:animation forKey:@"axs_glassify_sbez_cell_effect"];
}

@end
