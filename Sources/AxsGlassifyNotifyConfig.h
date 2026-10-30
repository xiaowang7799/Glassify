#pragma once

#import <Foundation/Foundation.h>

@interface AxsGlassifyNotifyConfig : NSObject
+ (instancetype)axs_glassify_notify_shared;
- (BOOL)axs_glassify_notify_isEnabled;
// 通知缩放（0.6–1.5）。
- (double)axs_glassify_notify_notifyScale;
// 流动渐变背景。
- (BOOL)axs_glassify_notify_gradientOn;
- (double)axs_glassify_notify_gradientHue1;
- (double)axs_glassify_notify_gradientHue2;
- (double)axs_glassify_notify_gradientSpeed;
- (double)axs_glassify_notify_gradientOpacity;
// 出现动画（liquid_glass_widgets 风格）：0=关 1=果冻弹跳 2=除雾渐显 3=挤压拉伸 4=凝胶膨胀。
- (NSInteger)axs_glassify_notify_appearMode;
- (double)axs_glassify_notify_appearIntensity;
// 触摸发光（touch glow）：触摸通知时渐变闪一下 + 微挤压。
- (BOOL)axs_glassify_notify_touchGlowOn;
// 触摸震动反馈（轻段触感）。
- (BOOL)axs_glassify_notify_touchHaptic;
// 鱼缸游鱼：每条通知背景里游动的小鱼（数量/大小可调）。
- (BOOL)axs_glassify_notify_fishOn;
- (NSInteger)axs_glassify_notify_fishCount;
- (double)axs_glassify_notify_fishSize;
// 自定义鱼图片（多张 ; 分隔，留空用手绘小鱼）。
- (NSString *)axs_glassify_notify_fishPng;
// 泡泡样式：大小倍数、透明度。
- (double)axs_glassify_notify_bubbleSize;
- (double)axs_glassify_notify_bubbleOpacity;
// 粒子方向：0=下落 1=上飘 2=横飘。
- (NSInteger)axs_glassify_notify_particleDir;
// 充电特效（⚡金色火花）。
- (BOOL)axs_glassify_notify_chargeFx;
// 充电蝴蝶大小（0.6–2.0）。
- (double)axs_glassify_notify_chargeSize;
// 低电量保护（自动降载）。
- (BOOL)axs_glassify_notify_lowPowerGuard;
// 时段自动切换（白天/夜间预设名）。
- (BOOL)axs_glassify_notify_autoSchedule;
- (NSString *)axs_glassify_notify_scheduleDayName;
- (NSString *)axs_glassify_notify_scheduleNightName;
// 配色来源：0=手动双色 1=跟随应用图标 2=跟随壁纸。
- (NSInteger)axs_glassify_notify_colorSource;
// 深色模式自动压暗。
- (BOOL)axs_glassify_notify_darkDim;
// 到达粒子爆发 / 消失消散。
- (BOOL)axs_glassify_notify_burstOn;
- (double)axs_glassify_notify_burstIntensity;
- (BOOL)axs_glassify_notify_dissolveOn;
// 粒子特效（图片文件导入）：开关、图片路径（多张用 ; 分隔）、数量（密度）、大小。
- (BOOL)axs_glassify_notify_particleOn;
- (NSString *)axs_glassify_notify_particlePng;
- (double)axs_glassify_notify_particleDensity;
- (double)axs_glassify_notify_particleSize;
// 爆发图片路径（找不到回退白色光点）。
- (NSString *)axs_glassify_notify_burstPng;
// 文字与图标：标题颜色/发光、图标圆角/大小/发光。
- (BOOL)axs_glassify_notify_titleColorOn;
- (double)axs_glassify_notify_titleHue;
- (double)axs_glassify_notify_titleGlow;
- (double)axs_glassify_notify_iconCorner;
- (double)axs_glassify_notify_iconScale;
- (double)axs_glassify_notify_iconGlow;
// 布局光影：圆角/透明度/投影/倾斜/宽度（0 = 保持系统默认）。
- (double)axs_glassify_notify_cornerRadius;
- (double)axs_glassify_notify_notifyOpacity;
- (double)axs_glassify_notify_shadowIntensity;
- (double)axs_glassify_notify_tiltIntensity;
- (double)axs_glassify_notify_notifyWidth;
// Generic accessors.
- (id)axs_glassify_notify_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_glassify_notify_reload;
@end
