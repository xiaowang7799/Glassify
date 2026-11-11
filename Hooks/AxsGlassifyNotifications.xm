#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>
#import "AxsGlassifyLiquid.h"
#import "AxsGlassifyNotifyAnimator.h"
#import "AxsGlassifyNotifyConfig.h"
#import "AxsGlassifyNotifications.h"
#import "AxsGlassifyPreferences.h"
// UIView (AxsGlassifySBezier)：合并后横幅 S 入场由本文件的同一组 hook 驱动。
#import "AxsGlassifySBezier.h"

// 锁屏 / 通知中心卡片：一套 hook 同时驱动两个引擎
//   AxsGlassifyLiquid        —— 卡片底材（玻璃 / iOS 26 UIGlassEffect）
//   AxsGlassifyNotifyAnimator —— 渐变、游鱼、粒子、出现动画、缩放/倾斜
// 合并前这是两个 dylib 各自 hook 同一个类，现在只有一个 hook 点。

static BOOL axs_glassify_contains_short_look(UIView *view, NSUInteger depth) {
    if (depth > 3) {
        return NO;
    }
    for (UIView *subview in view.subviews) {
        // 热路径（每次 cell 布局）：用 C 字符串比较，不建 NSString。
        const char *name = class_getName(object_getClass(subview));
        if (name != NULL && strstr(name, "ShortLook") != NULL) {
            return YES;
        }
        if (axs_glassify_contains_short_look(subview, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

static void axs_glassify_notify_applyToView(UIView *view) {
    [AxsGlassifyLiquid axs_glassify_applyToPlatter:view];
    [[AxsGlassifyNotifyAnimator axs_glassify_notify_shared] axs_glassify_notify_refreshForView:view];
}

#pragma mark - 时段自动切换（白天 [7,19) 用 day 预设名，其余 night 预设名）

static NSArray<NSString *> *axs_glassify_notify_presetKeys(void) {
    return @[@"enabled", @"notify_scale",
             @"gradient_on", @"gradient_hue1", @"gradient_hue2",
             @"gradient_speed", @"gradient_opacity",
             @"color_source", @"dark_dim",
             @"burst_on", @"burst_intensity", @"dissolve_on",
             @"appear_mode", @"elastic_intensity", @"touch_glow_on", @"touch_haptic",
             @"fish_on", @"fish_count", @"fish_size", @"fish_png",
             @"bubble_size", @"bubble_opacity",
             @"particle_on", @"particle_png", @"particle_density",
             @"particle_size", @"particle_dir",
             @"charge_fx", @"charge_size", @"low_power_guard",
             @"title_color_on", @"title_hue", @"title_glow",
             @"icon_corner", @"icon_scale", @"icon_glow",
             @"corner_radius", @"notify_opacity", @"shadow_intensity",
             @"tilt_intensity", @"notify_width", @"s_curve_amp",
             @"sbz_entrance_enabled", @"sbz_decoration_enabled", @"sbz_decoration_style", @"sbz_debug_log",
             @"sbz_serp_enabled", @"sbz_serp_amp", @"sbz_serp_wavelength",
             @"sbz_serp_shrink", @"sbz_serp_tilt_deg",
             @"sbz_scroll_effect", @"sbz_scroll_duration", @"sbz_scroll_amplitude",
             @"sbz_scroll_span", @"sbz_scroll_variation",
             @"sbz_duration", @"sbz_amplitude", @"sbz_frequency",
             @"sbz_phase", @"sbz_width", @"sbz_opacity", @"sbz_hue",
             @"auto_schedule", @"schedule_day", @"schedule_night"];
}

static void axs_glassify_notify_applyScheduledPreset(void) {
    AxsGlassifyNotifyConfig *config = [AxsGlassifyNotifyConfig axs_glassify_notify_shared];
    if (![config axs_glassify_notify_autoSchedule]) return;
    NSDictionary *all = axs_glassify_readPreferences();
    NSArray *presets = [all[@"custom_presets"] isKindOfClass:[NSArray class]] ? all[@"custom_presets"] : nil;
    if (presets.count == 0) return;
    NSInteger hour = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    BOOL isDay = (hour >= 7 && hour < 19);
    NSString *want = isDay ? [config axs_glassify_notify_scheduleDayName]
                           : [config axs_glassify_notify_scheduleNightName];
    if (want.length == 0) return;
    for (NSDictionary *preset in presets) {
        if (![[preset objectForKey:@"name"] isKindOfClass:[NSString class]]) continue;
        if ([[preset objectForKey:@"name"] isEqualToString:want]) {
            NSDictionary *settings = [preset objectForKey:@"settings"];
            if ([settings isKindOfClass:[NSDictionary class]]) {
                NSError *error = nil;
                for (NSString *key in axs_glassify_notify_presetKeys()) {
                    id v = settings[key];
                    if (v) axs_glassify_writePreference(key, v, &error);
                }
            }
            break;
        }
    }
}

#pragma mark - 快捷看板（ShortLook，iOS 15–18 锁屏横幅）

%group AxsGlassifyShortLook

%hook NCNotificationShortLookView

- (void)didMoveToWindow {
    %orig;
    AxsGlassifyNotifyAnimator *animator = [AxsGlassifyNotifyAnimator axs_glassify_notify_shared];
    if (self.window) {
        [animator axs_glassify_notify_attachToView:(UIView *)self];
    } else {
        [animator axs_glassify_notify_detachView:(UIView *)self];
        // 离开窗口意味着横幅消失或被回收：把 S 入场的观察者和装饰层一起清掉，
        // 下次出现才能重新认领、重新播一次。
        [self axs_glassify_sbez_cleanup];
    }
    if (!self.window) {
        [AxsGlassifyLiquid axs_glassify_removeFromPlatter:(UIView *)self];
    }
}

- (void)layoutSubviews {
    %orig;
    axs_glassify_notify_applyToView((UIView *)self);
    [self axs_glassify_sbez_applyEntranceIfNeeded];
}

- (void)dealloc {
    [self axs_glassify_sbez_cleanup];
    %orig;
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (!newWindow) {
        [[AxsGlassifyNotifyAnimator axs_glassify_notify_shared]
            axs_glassify_notify_dissolveForView:(UIView *)self];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    [[AxsGlassifyNotifyAnimator axs_glassify_notify_shared]
        axs_glassify_notify_touchGlowForView:(UIView *)self];
}

// 拖动不再用 -touchesMoved:（会被列表滚动手势取消），
// 改由 AxsGlassifyNotifyAnimator 在 attach 时挂的 UIPanGestureRecognizer 驱动。

%end

%end

#pragma mark - 展开态

%group AxsGlassifyLongLook

%hook NCNotificationLongLookView

- (void)didMoveToWindow {
    %orig;
    AxsGlassifyNotifyAnimator *animator = [AxsGlassifyNotifyAnimator axs_glassify_notify_shared];
    if (self.window) {
        [animator axs_glassify_notify_attachToView:(UIView *)self];
    } else {
        [animator axs_glassify_notify_detachView:(UIView *)self];
        [self axs_glassify_sbez_cleanup];
    }
}

- (void)layoutSubviews {
    %orig;
    axs_glassify_notify_applyToView((UIView *)self);
    [self axs_glassify_sbez_applyEntranceIfNeeded];
}

- (void)dealloc {
    [self axs_glassify_sbez_cleanup];
    %orig;
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (!newWindow) {
        [[AxsGlassifyNotifyAnimator axs_glassify_notify_shared]
            axs_glassify_notify_dissolveForView:(UIView *)self];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    [[AxsGlassifyNotifyAnimator axs_glassify_notify_shared]
        axs_glassify_notify_touchGlowForView:(UIView *)self];
}

%end

%end

#pragma mark - 列表卡片（iOS 16+，没有 ShortLook 子视图时兜底）

%group AxsGlassifyListCell

%hook NCNotificationListCell

- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    // iOS 16+ 可见卡片是 cell 里的短看视图，两边都上玻璃会叠两层。
    if (axs_glassify_contains_short_look(cell, 0)) {
        return;
    }
    axs_glassify_notify_applyToView(cell);
    // S 形横幅入场**不**挂到这里：这张 cell 属于列表，滚动入场 hook 已经在同一个
    // layer 上放了一条 transform 动画，两条并存会互相顶掉。原工程也只 hook 横幅宿主。
}

%end

%end

%ctor {
    @autoreleasepool {
        [AxsGlassifyNotifyConfig axs_glassify_notify_shared];

        if (NSClassFromString(@"NCNotificationShortLookView")) {
            %init(AxsGlassifyShortLook);
        }
        if (NSClassFromString(@"NCNotificationLongLookView")) {
            %init(AxsGlassifyLongLook);
        }
        if (NSClassFromString(@"NCNotificationListCell")) {
            %init(AxsGlassifyListCell);
        }

        // 时段自动切换：启动后应用一次，此后每小时检查。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            axs_glassify_notify_applyScheduledPreset();
            NSTimer *hourly = [NSTimer scheduledTimerWithTimeInterval:3600.0 repeats:YES
                block:^(NSTimer *t) {
                axs_glassify_notify_applyScheduledPreset();
            }];
            [NSRunLoop.mainRunLoop addTimer:hourly forMode:NSRunLoopCommonModes];
        });
    }
}
