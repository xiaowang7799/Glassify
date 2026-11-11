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
// 决定横向摆多少、拐到波峰/波谷时缩多少、并顺轨迹切线微微倾转。静止定格，
// 滚动时整列沿 S 流动。一次滚动事件只合并成一趟 pass，只写 cell layer 的
// presentation transform —— 绝不写 frame / model 以外的布局状态，避免重蹈
// 旧版「每帧改 model transform 把设备卡死」的覆辙。
- (void)axs_glassify_sbez_serpPassQueued;
- (void)axs_glassify_sbez_serpPassNow;
@end

#pragma mark - S 形蜿蜒排列（自由函数，ListEntrance.m 实现）

// 该 view 是否正被蜿蜒排版占用 transform —— 玻璃引擎的每帧 transform 写手必须
// 让位，否则两个所有权互相顶掉。非蜿蜒 cell 返回 NO，热路径只是读一个关联对象。
BOOL axs_glassify_sbez_viewSerpDisplaced(UIView *view);

// 面板保存后调用：刷新快速门控镜像；关闭或被重新调参时把已排版的 cell 恢复直线。
void axs_glassify_sbez_serpPreferencesChanged(void);

// 权威谓词 -> static 镜像。NotifyConfig reload 后与每趟 pass 开始时调用。
void axs_glassify_sbez_serpUpdateGate(void);

// Shared by UITableViewCell, UICollectionViewCell and — because the lock screen
// list is really a plain UIScrollView — any view added into a *Notification* list.
// Implemented once on UIView so every entry point shares one code path.
@interface UIView (AxsGlassifySBezierCellEntrance)
- (void)axs_glassify_sbez_cellDidMoveToSuperview;
- (void)axs_glassify_sbez_viewDidMoveToSuperview;
- (void)axs_glassify_sbez_applyFromList:(UIScrollView *)list;
- (void)axs_glassify_sbez_playEffect:(NSInteger)effect row:(NSInteger)row;
@end
