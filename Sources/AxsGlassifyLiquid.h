#pragma once

#import <UIKit/UIKit.h>

// Liquid-glass material for lock screen / notification center platters.
//
// iOS 26 and newer expose UIGlassEffect, which renders Apple's real Liquid Glass
// (lens refraction, specular highlights, edge treatment). That path is used when
// available. On older releases UIKit gives third-party code no access to the
// backdrop texture, so the closest equivalent is the chrome material plus the
// specular rim, top highlight and edge fringe added here.
// 玻璃底板安装/移除时广播（object 为卡片视图），动画引擎据此把渐变层重新挂到正确层级。
extern NSString * const AxsGlassifyPlatterGlassChanged;

@interface AxsGlassifyLiquid : NSObject

// YES when UIKit provides UIGlassEffect (iOS 26+).
+ (BOOL)axs_glassify_hasSystemGlass;

// Installs or updates the glass background on a notification platter. Safe to
// call from -layoutSubviews: it is idempotent and ignores non-notification views.
+ (void)axs_glassify_applyToPlatter:(UIView *)platter;

// YES for the panel this class inserted, so the animation engine can skip it when
// it looks for the platter's own background view.
+ (BOOL)axs_glassify_isGlassView:(UIView *)view;

// 玻璃底板的 contentView（装在玻璃之上、文字之下的那一层）。没有玻璃时返回 nil。
+ (UIView *)axs_glassify_glassContentViewForPlatter:(UIView *)platter;

// Tears the glass background down and restores the views it suppressed.
+ (void)axs_glassify_removeFromPlatter:(UIView *)platter;

// Re-applies (or removes) the material on every live platter, e.g. after the
// settings panel saves a new snapshot.
+ (void)axs_glassify_refreshPlatters;

@end
