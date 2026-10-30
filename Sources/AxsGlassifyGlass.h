#pragma once

#import <UIKit/UIKit.h>

// Enhances the system's existing blurred surfaces (control center, notifications,
// folders, dock, app switcher) instead of covering the whole screen. Surfaces that
// are not already blurred — including the home screen icons — are left untouched.
@interface AxsGlassifyGlass : NSObject
// Called from the UIVisualEffectView hook. Remembers the original effect so it can
// be restored when the tweak is disabled, and returns the restyled effect to apply.
+ (UIVisualEffect *)axs_glassify_transformIncoming:(UIVisualEffect *)effect
                                           forView:(UIVisualEffectView *)view;
// Re-apply (or restore) every existing effect view, e.g. after a settings change.
+ (void)axs_glassify_refreshAllWindows;
// Adds a 45-degree specular rim to a private backdrop view (liquid-glass highlight);
// removes it when disabled. Safe to call from -layoutSubviews repeatedly.
+ (void)axs_glassify_decorateBackdropView:(UIView *)view;
// 动态高光：按设备姿态移动镜面描边的亮边方向。只在高光层存在且开关打开时
// 才会开启陀螺仪采样，没有高光层就自动停表。
+ (void)axs_glassify_syncMotionHighlight;
@end
