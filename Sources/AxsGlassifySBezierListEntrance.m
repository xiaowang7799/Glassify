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
// ── S 形蜿蜒排列 ──
// A cell's model transform as it was *before* the serpentine pass touched it.
// Presence of this association is also the marker "this cell is displaced", so
// turning the effect off can restore exactly the cells it had moved.
static const char axs_glassify_sbez_keySerpOriginal = 0;
// One queued pass per runloop tick: layout + setContentOffset + cell-add all
// fire several times per frame; the pass itself is idempotent, so coalescing
// is free correctness, not an optimisation.
static const char axs_glassify_sbez_listKeyPassQueued = 0;

// Fast mirror of the config verdict, refreshed on every preferences reload and
// at load. setBounds:/setContentOffset: are process-hot hooks: when the effect
// is off the path must cost ONE static read and nothing else.
static BOOL axs_glassify_sbez_serpFastOn = NO;

// Weak registry of cells the serpentine displaced, so the off-edge restore can
// reach cells already scrolled out of view. Main-thread only, like every pass.
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

static void axs_glassify_sbez_serpRepassAllKnownLists(void) {
    for (UIScrollView *list in [axs_glassify_sbez_serpLists().allObjects copy]) {
        [list axs_glassify_sbez_serpPassQueued];
    }
}

// Geometric notes (why this cannot loop the way the old per-frame version did):
// - Nothing here writes frame/bounds/contentOffset, only layer.transform of cells
//   the list itself reports as visible. The list never gets a reason to re-layout,
//   so pass -> layout -> pass cycles cannot form.
// - Every pass recomputes from the stored *original* base, so passes are
//   idempotent; coalescing several scroll events into one pass is exact.
// - While a cell is displaced the glass per-tick transform writer is fenced off
//   (see AxsGlassifyNotifyAnimator applyScale), so one owner writes each
//   cell's transform at a time; on a prefs reload the base is re-fetched, so a
//   changed notify_scale cannot go stale.
static void axs_glassify_sbez_serpGeometryForY(CGFloat y, CGFloat amplitude, CGFloat wavelength,
                                               CGFloat shrink, CGFloat tiltRad,
                                               CGFloat *outX, CGFloat *outScale, CGFloat *outRot) {
    CGFloat phase = (CGFloat)M_PI * 2.0f * y / MAX(wavelength, 60.0f);
    CGFloat s = sinf(phase);
    *outX = amplitude * s;
    // 用户定稿：不存在"回到中线就恢复整齐"。波峰/波谷（|sin|=1）缩到最大
    // (1-shrink)；穿越中线的卡片也保留 0.35·shrink 的"穿越态"缩小，并且此刻
    // 倾转恰为最大（cos=±1），所以整屏任何时候看都是一条连续的蛇形，
    // 不会有一排全尺寸居中的正常卡片。
    CGFloat a = fabs(s);
    *outScale = 1.0f - shrink * (0.35f + 0.65f * a);
    // cos is the tangent's sign - the lean follows the ribbon direction.
    *outRot = tiltRad * cosf(phase);
}

static void axs_glassify_sbez_serpRestoreCell(UIView *cell) {
    NSValue *stored = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpOriginal);
    if (stored == nil) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CATransform3D original = stored.CATransform3DValue;
    if (!CATransform3DEqualToTransform(cell.layer.transform, original)) {
        cell.layer.transform = original;
    }
    [CATransaction commit];
    objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpOriginal, nil, OBJC_ASSOCIATION_ASSIGN);
    [axs_glassify_sbez_serpDisplaced() removeObject:cell];
}

static void axs_glassify_sbez_serpRestoreAllDisplaced(void) {
    for (UIView *cell in [axs_glassify_sbez_serpDisplaced().allObjects copy]) {
        axs_glassify_sbez_serpRestoreCell(cell);
    }
}

BOOL axs_glassify_sbez_viewSerpDisplaced(UIView *view) {
    return view != nil && objc_getAssociatedObject(view, &axs_glassify_sbez_keySerpOriginal) != nil;
}

// 纯门控镜像：必须在 NotifyConfig 每次 reload 之后调用（单写读放宽：读者最坏
// 晚一个 runloop，且 pass 内部还会二次确认）。
void axs_glassify_sbez_serpUpdateGate(void) {
    axs_glassify_sbez_serpFastOn =
        [[AxsGlassifyNotifyConfig axs_glassify_notify_shared] axs_glassify_notify_sbezSerpActive];
}

// 诊断一行（面板「S 形贝塞尔诊断」可见）：为什么没效果当场可读 —— 门控、
// 减弱动态、已知列表数、当前位移中的卡片数。MergeIfChanged 内存去重，只在
// 变化时落盘，调用点全在低频路径。lists=0 说明从没识别到通知列表；
// reduce=1 说明系统「减弱动态效果」开着（设计上整体跳过）；
// on=1 moved=0 且刚保存过，说明排版跑了但没找到可见卡片。
static void axs_glassify_sbez_serpDiag(void) {
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    NSUInteger lists = axs_glassify_sbez_serpLists().allObjects.count;
    NSUInteger moved = axs_glassify_sbez_serpDisplaced().allObjects.count;
    axs_glassify_sbez_diagnosticsMergeIfChanged(@"serp",
        [NSString stringWithFormat:@"on=%d reduce=%d lists=%lu moved=%lu",
         (int)axs_glassify_sbez_serpFastOn, (int)reduce,
         (unsigned long)lists, (unsigned long)moved]);
}

// 面板保存（主线程通知）：三种触发都必须主动重排，不能"等下一个事件"——
// 用户在设置页打开开关再回锁屏时，列表早已在窗口、没有新卡片、也不会滚动，
// 没有任何被动触发源会命中（这正是真机"静止仍整齐"的根因）。
//
// 快照竞态：本通知由主配置发出；本模块用的 NotifyConfig 快照在另一条串行队列
// 重载，此刻可能还是旧值（没人再发第二条通知）。所以连拍四下（当拍 / 下一拍 /
// 0.12s / 0.4s），每拍用权威谓词重校门控；0.4s 那拍同时盖住"列表刚出现、cell
// 还没挂上"的挂载竞态。恢复-重排顺序有讲究：先恢复直线再重烘基准，反过来会把
// 旧偏移烘成新基准。
void axs_glassify_sbez_serpPreferencesChanged(void) {
    void (^tick)(void) = ^{
        axs_glassify_sbez_serpUpdateGate();
        if (axs_glassify_sbez_serpFastOn) {
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
    // 蜿蜒排列需要「刚出现就排版」：静止定格时第一眼就该是 S 形。
    if (axs_glassify_sbez_serpFastOn) {
        [self axs_glassify_sbez_serpPassQueued];
    }
}

// One pass per runloop tick at most (see keyPassQueued). The pass is idempotent
// because every target recomputes from the stored original base.
- (void)axs_glassify_sbez_serpPassQueued {
    if (!axs_glassify_sbez_serpFastOn) {
        // 关闭态：只有还欠着恢复时才继续（一次哈希 count 读），passNow 会把
        // 它们拉回直线 —— 门控镜像与快照之间的任何竞态都靠这条路兜底自愈。
        if ([axs_glassify_sbez_serpDisplaced() count] == 0) {
            return;
        }
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
    // 异步跳转之后重读一次权威谓词校正镜像：排队与执行之间面板可能已改过，
    // 一趟 pass 内只用同一组参数，不会半新半旧。
    axs_glassify_sbez_serpUpdateGate();
    // 两种"本效果不生效"的状态（关开关 / 系统减弱动态）都恢复直线：
    // 减弱动态开着时卡片也必须笔直，不能出现"开一半歪一半"。恢复幂等，
    // 之后 displaced 归零，热路径回到一次静态读的零成本。
    if (!axs_glassify_sbez_serpFastOn || UIAccessibilityIsReduceMotionEnabled()) {
        axs_glassify_sbez_serpRestoreAllDisplaced();
        return;
    }
    if (![self axs_glassify_sbez_isNotificationList]) {
        return;
    }

    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    CGFloat amp = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_amp" defaultValue:28.0];
    CGFloat wavelength = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_wavelength" defaultValue:260.0];
    CGFloat shrink = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_shrink" defaultValue:0.18];
    CGFloat tiltDeg = (CGFloat)[config axs_glassify_notify_sbezDoubleForKey:@"sbz_serp_tilt_deg" defaultValue:8.0];
    amp = MAX(0.0f, MIN(amp, 120.0f));
    wavelength = MAX(80.0f, MIN(wavelength, 800.0f));
    shrink = MAX(0.0f, MIN(shrink, 0.5f));
    tiltDeg = MAX(0.0f, MIN(tiltDeg, 20.0f));
    CGFloat tiltRad = tiltDeg * (CGFloat)M_PI / 180.0f;

    // visibleCells 现在对所有列表形态都有结果：table/collection 用系统的，
    // 普通 scroll 列表（NCNotificationListView）用子视图里的 *Notification* 视图。
    NSArray *cells = axs_glassify_sbez_visibleCells(self);
    if (cells.count == 0) {
        return;
    }

    for (UIView *cell in cells) {
        CGSize size = cell.bounds.size;
        if (size.width < 1.0f || size.height < 1.0f) {
            continue;
        }
        CGPoint centre = [cell convertPoint:CGPointMake(size.width * 0.5f, size.height * 0.5f)
                                     toView:self];
        CGFloat x, scale, rot;
        axs_glassify_sbez_serpGeometryForY(centre.y, amp, wavelength, shrink, tiltRad,
                                           &x, &scale, &rot);

        NSValue *stored = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpOriginal);

        BOOL straight = fabs(x) < 0.5f && fabs(scale - 1.0f) < 0.003f && fabs(rot) < 0.001f;
        if (straight) {
            if (stored != nil) {
                axs_glassify_sbez_serpRestoreCell(cell);
            }
            continue;
        }

        if (stored == nil) {
            // Bake the current (straight) model transform as the base exactly
            // once; glass owns this cell's transform again only after restore.
            objc_setAssociatedObject(cell, &axs_glassify_sbez_keySerpOriginal,
                                     [NSValue valueWithCATransform3D:cell.layer.transform],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [axs_glassify_sbez_serpDisplaced() addObject:cell];
            stored = objc_getAssociatedObject(cell, &axs_glassify_sbez_keySerpOriginal);
        }

        CATransform3D base = stored.CATransform3DValue;
        // base first, then scale/lean/displace around the layer anchor
        // (anchor is the card centre by default, so scaling and rotation stay
        // in place and x is measured in list coordinates).
        CATransform3D local = CATransform3DScale(CATransform3DIdentity, scale, scale, 1.0);
        local = CATransform3DRotate(local, rot, 0.0, 0.0, 1.0);
        local = CATransform3DTranslate(local, x, 0.0, 0.0);
        CATransform3D target = CATransform3DConcat(base, local);

        if (!CATransform3DEqualToTransform(cell.layer.transform, target)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            cell.layer.transform = target;
            [CATransaction commit];
        }
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
    // 蜿蜒排列：新出现的卡片也要参与排版（静止列表里刚加进来的那条不能是直的）。
    // 放在最前面，因为下面的入场特效去重与档位判断都可能提前 return。
    if (axs_glassify_sbez_serpFastOn) {
        [list axs_glassify_sbez_serpPassQueued];
    }

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
