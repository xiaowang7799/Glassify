#pragma once

#import <UIKit/UIKit.h>

// 锁屏通知液态效果引擎：
// 流动渐变背景 / 液态玻璃高光 / 波浪边缘 / 弹性出现动画 / 通知缩放（布局自愈）。
@interface AxsGlassifyNotifyAnimator : NSObject
+ (instancetype)axs_glassify_notify_shared;
// 通知视图出现在窗口时挂载效果。
- (void)axs_glassify_notify_attachToView:(UIView *)view;
// 通知视图离开窗口时清理。
- (void)axs_glassify_notify_detachView:(UIView *)view;
// 系统重新布局后调用（刷新层帧 + 重施缩放，带自愈）。
- (void)axs_glassify_notify_refreshForView:(UIView *)view;
// 触摸发光（touch glow）：高光脉冲 + 微挤压。
- (void)axs_glassify_notify_touchGlowForView:(UIView *)view;
// 消失消散：划走/清除时液态溶解（willMoveToWindow:nil 时调用）。
- (void)axs_glassify_notify_dissolveForView:(UIView *)view;
// 滑动拖尾：拖动时渐变跟手 / 松手回位。
- (void)axs_glassify_notify_dragGradientForView:(UIView *)view translationY:(CGFloat)dy;
- (void)axs_glassify_notify_endDragForView:(UIView *)view;
@end
