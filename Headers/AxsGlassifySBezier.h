#pragma once

#import <UIKit/UIKit.h>

// Banner hosts for the S-shaped entrance. NCNotificationShortLookView and
// NCNotificationLongLookView are already declared in AxsGlassifyNotifications.h:
// after the merge they are hooked from there, in the same single hook block as
// the glass platter, so one class never has two competing %hook definitions per
// selector. Only the legacy host needs declaring here. A name absent at runtime
// is never hooked, so a wrong entry stays inert instead of crashing.
@interface SBUICNotificationView : UIView
@end

// Implemented once on UIView so every banner host shares one code path. The
// merged hook block in Hooks/AxsGlassifyNotifications.xm drives these.
@interface UIView (AxsGlassifySBezier)
// Runs once per banner appearance, after the view has real bounds.
- (void)axs_glassify_sbez_applyEntranceIfNeeded;
// Creates/refreshes the decorative S wave layer from the current config snapshot.
- (void)axs_glassify_sbez_installDecoration;
- (void)axs_glassify_sbez_refreshDecoration;
// Plays the S shaped Bezier entrance animation.
- (void)axs_glassify_sbez_animateEntrance;
// Drops the observer and layer, and re-arms the one-shot guard.
- (void)axs_glassify_sbez_cleanup;
@end

// The lock screen and Notification Center share one scrolling notification list,
// but its concrete class changes between iOS versions. The list is therefore
// identified at runtime instead of guessed by name, and the entrance is driven by
// the cells the list itself creates, which is how Cask does it.
@interface UIScrollView (AxsGlassifySBezierList)
- (BOOL)axs_glassify_sbez_isNotificationList;
// Records what this list actually is, once per list, into the report the settings
// panel displays; also logs it when 调试日志 is on. Independent of the effect
// switches so a wrong guess stays diagnosable.
- (void)axs_glassify_sbez_recordList;
// Arms the "just appeared" guard and records.
- (void)axs_glassify_sbez_noteAppeared;
// ── S 形蜿蜒排列 ──
// 通知列表的排版形变（不是进场动画）：每张卡片按它纵向位置落在 S 的哪个相位，
// 决定横向摆多少、拐到波峰/波谷时缩多少。静止定格也是 S 形，滚动时整列沿
// 轨迹流动。v8：弯折发生在卡片自己的 setFrame:/setCenter:（见下面两个自由
// 函数），列表侧的 pass 只负责"关/减弱动态"一侧的恢复自愈。
- (void)axs_glassify_sbez_serpPassQueued;
- (void)axs_glassify_sbez_serpPassNow;
@end

#pragma mark - S 形蜿蜒排列（自由函数，ListEntrance.m 实现）

// The .xm hooks compile as C++ (.mm) under Theos; these plain-C functions live
// in a .m, so without extern "C" the linker looks for a mangled name and fails.
#ifdef __cplusplus
extern "C" {
#endif

// 面板保存后调用：刷新快速门控镜像；关闭或被重新调参时把已排版的 cell 恢复直线。
void axs_glassify_sbez_serpPreferencesChanged(void);

// 权威谓词 -> static 镜像。NotifyConfig reload 后与每趟 pass 开始时调用。
void axs_glassify_sbez_serpUpdateGate(void);

// v8 接管卡片 setter：系统交出坐标 -> 就地弯成 S。
// 返回 YES 表示调用方应当 %orig(out)；NO = 原样放行。
BOOL axs_glassify_sbez_serpBendFrame(UIView *cell, CGRect in, CGRect *out);
BOOL axs_glassify_sbez_serpBendCenter(UIView *cell, CGPoint in, CGPoint *out);

// 写入闸：我们自己那次 %orig 必须包起来，防止重入二次弯折。
void axs_glassify_sbez_serpWriteBegin(void);
void axs_glassify_sbez_serpWriteEnd(void);

// v12：该 view 的 transform 正被蜿蜒缩放占用 —— 玻璃引擎的每帧 transform
// 写手必须让位，否则两个写手互相顶就是抖动（v6 教训）。
BOOL axs_glassify_sbez_viewSerpScaled(UIView *view);

#ifdef __cplusplus
}
#endif

// Shared by UITableViewCell, UICollectionViewCell and — because the lock screen
// list is really a plain UIScrollView — any view added into a *Notification* list.
// Implemented once on UIView so every entry point shares one code path.
@interface UIView (AxsGlassifySBezierCellEntrance)
- (void)axs_glassify_sbez_cellDidMoveToSuperview;
- (void)axs_glassify_sbez_viewDidMoveToSuperview;
- (void)axs_glassify_sbez_applyFromList:(UIScrollView *)list;
- (void)axs_glassify_sbez_playEffect:(NSInteger)effect row:(NSInteger)row;
@end
