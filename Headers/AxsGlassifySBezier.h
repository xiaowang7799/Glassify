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
@end

// Shared by UITableViewCell, UICollectionViewCell and — because the lock screen
// list is really a plain UIScrollView — any view added into a *Notification* list.
// Implemented once on UIView so every entry point shares one code path.
@interface UIView (AxsGlassifySBezierCellEntrance)
- (void)axs_glassify_sbez_cellDidMoveToSuperview;
- (void)axs_glassify_sbez_viewDidMoveToSuperview;
- (void)axs_glassify_sbez_applyFromList:(UIScrollView *)list;
- (void)axs_glassify_sbez_playEffect:(NSInteger)effect row:(NSInteger)row;
@end
