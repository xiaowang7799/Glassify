#import <UIKit/UIKit.h>
#import "AxsGlassifyNotifyConfig.h"
#import "AxsGlassifySBezierDiagnostics.h"
#import "AxsGlassifySBezier.h"

// Declared only so the runtime check below can name the selector without a
// compiler warning; the method itself is private to UITableView.
@interface UITableView (AxsGlassifySBezierPreparedCellSelector)
- (id)_createPreparedCellForGlobalRow:(NSInteger)globalRow
                        withIndexPath:(NSIndexPath *)indexPath
                           willDisplay:(BOOL)willDisplay;
@end

// The banner hosts (NCNotificationShortLookView / NCNotificationLongLookView)
// are NOT hooked here. After the merge they are driven from the single existing
// hook block in Hooks/AxsGlassifyNotifications.xm, which calls
// -axs_glassify_sbez_applyEntranceIfNeeded alongside the glass platter: two
// %hook definitions for the same selector in one dylib would leave only one of
// them installed. This file keeps only the hooks the glass side never touches.

%group AxsGlassifySBezierLegacyBanner
%hook SBUICNotificationView

- (void)layoutSubviews {
    %orig;
    [self axs_glassify_sbez_applyEntranceIfNeeded];
}

- (void)didMoveToWindow {
    %orig;
    if (self.window == nil) {
        [self axs_glassify_sbez_cleanup];
    }
}

- (void)dealloc {
    [self axs_glassify_sbez_cleanup];
    %orig;
}

%end
%end

%group AxsGlassifySBezierListEntrance

// Every scroll view records itself once and gets the "just appeared" guard, which
// stops the initial fill of a list animating every row at once. UIScrollView is
// public and always present, so this is safe to hook unconditionally; whether a
// given one is the notification list is decided at runtime.
%hook UIScrollView
- (void)didMoveToWindow {
    %orig;
    [self axs_glassify_sbez_noteAppeared];
}

// v8：弯折在卡片自己的 setFrame:/setCenter: 里完成（见 AxsGlassifyNotifications.xm
// 的 NCNotificationListCell 组），列表侧不再事后覆盖 —— v7 那种
// "layoutSubviews 之后改写"实测被外层容器再覆盖一次，摆幅拉满也看不见。
// 下面两个滚动信号只服务"关/减弱动态"那一侧的恢复自愈。
// setContentOffset: 是单向信号；不挂 setBounds:（原插件 v5.2.0-12 前的
// 反馈回路来源）。一趟 pass 每 runloop 至多一次。
- (void)setContentOffset:(CGPoint)contentOffset {
    %orig;
    [self axs_glassify_sbez_serpPassQueued];
}

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    %orig;
    [self axs_glassify_sbez_serpPassQueued];
}

%end

// The list may be a table or a collection, so both cell kinds are hooked. Cells are
// added from inside the list's own layout pass, so the effect is only scheduled here
// and started after an async hop; nothing is mutated during layout, and only a
// CAAnimation is ever attached - never the cell's model transform.
%hook UITableViewCell
- (void)didMoveToSuperview {
    %orig;
    [self axs_glassify_sbez_cellDidMoveToSuperview];
}
%end

%hook UICollectionViewCell
- (void)didMoveToSuperview {
    %orig;
    [self axs_glassify_sbez_cellDidMoveToSuperview];
}
%end

// The lock screen list turned out to be NCNotificationListView, a plain UIScrollView,
// so its entries are not table/collection cells at all. Any view added straight into
// a *Notification* scroll view is therefore treated as a cell too. The name test is a
// strstr over the class name, so this stays cheap despite being a very hot hook.
%hook UIView
- (void)didMoveToSuperview {
    %orig;
    [self axs_glassify_sbez_viewDidMoveToSuperview];
}
%end

%end

// The same trigger Cask uses. It is private, so the group is only initialised when
// the selector actually exists on this iOS version; a missing method would leave
// %orig with nothing to call.
%group AxsGlassifySBezierPreparedCell

%hook UITableView
- (id)_createPreparedCellForGlobalRow:(NSInteger)globalRow
                        withIndexPath:(NSIndexPath *)indexPath
                           willDisplay:(BOOL)willDisplay {
    id cell = %orig;
    if (willDisplay && cell != nil) {
        [cell axs_glassify_sbez_cellDidMoveToSuperview];
    }
    return cell;
}
%end

%end

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
        // 蜿蜒排列门控：首次镜像一次，之后每次配置保存刷新 + 处理关→恢复。
        // serpPreferencesChanged 内部已含 updateGate，一个观察者足够。
        axs_glassify_sbez_serpUpdateGate();
        [[NSNotificationCenter defaultCenter] addObserverForName:AxsGlassifyPreferencesChanged
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            axs_glassify_sbez_serpPreferencesChanged();
        }];

        // A fresh self-report per launch, so a stale one can never be mistaken for
        // this run's. The settings panel reads it back.
        axs_glassify_sbez_diagnosticsReset();
        axs_glassify_sbez_diagnosticsMerge(@{
            @"loadedAt": axs_glassify_sbez_diagnosticsTimestamp(),
            @"process": [NSProcessInfo processInfo].processName ?: @"?",
            @"config": @"(还没有读到)",
        });

        // UITableView and UITableViewCell always exist, so the list group is
        // unconditional; the notification list itself is identified at runtime.
        %init(AxsGlassifySBezierListEntrance);

        // Cask's private trigger, only when the method is really there.
        if ([UITableView instancesRespondToSelector:
             @selector(_createPreparedCellForGlobalRow:withIndexPath:willDisplay:)]) {
            %init(AxsGlassifySBezierPreparedCell);
        } else {
            axs_glassify_sbez_diagnosticsMerge(@{@"preparedCellHook": @"不可用"});
        }

        // The modern banner hosts come up with the glass hook block instead.
        if (NSClassFromString(@"SBUICNotificationView") != nil) {
            %init(AxsGlassifySBezierLegacyBanner);
        }
    }
}
