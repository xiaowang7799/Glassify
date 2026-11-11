#import "AxsGlassifyNotifyConfig.h"
#import "AxsGlassifyPreferences.h"
#import <math.h>

@interface AxsGlassifyNotifyConfig ()
@property (atomic, copy) NSDictionary *snapshot;
// 每次重新加载 +1：界面据此判断“配置有没有变过”，比逐项比较 20 多个键便宜。
@property (atomic, assign) NSUInteger generation;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_glassify_notify_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsGlassifyNotifyConfig *config = (__bridge AxsGlassifyNotifyConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_glassify_notify_reload];
    });
}

@implementation AxsGlassifyNotifyConfig

+ (instancetype)axs_glassify_notify_shared {
    static AxsGlassifyNotifyConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.axs.glassify.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_glassify_notify_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_glassify_notify_preferencesDidChange,
            (__bridge CFStringRef)AxsGlassifyPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_glassify_notify_reload]; });
    }
    return self;
}

- (void)axs_glassify_notify_reload {
    // 只更新自己的快照。AxsGlassifyConfig 已经在同一个 Darwin 通知上广播
    // AxsGlassifyPreferencesChanged，这里再发一次会让“遍历窗口树 + 刷新所有卡片”白跑两遍。
    self.snapshot = axs_glassify_readPreferences();
    self.generation = self.generation + 1;
}

- (NSUInteger)axs_glassify_notify_generation {
    return self.generation;
}

- (id)axs_glassify_notify_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_glassify_notify_isEnabled {
    id value = [self axs_glassify_notify_valueForKey:@"enabled" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

// ── 访问器（全部带钳制与缺省） ──
static double axs_glassify_notify_clamped(id value, double def, double lo, double hi) {
    if (![value isKindOfClass:[NSNumber class]]) return def;
    double d = [value doubleValue];
    if (!isfinite(d)) return def;
    return fmax(lo, fmin(hi, d));
}
static BOOL axs_glassify_notify_bool(id value, BOOL def) {
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : def;
}

- (double)axs_glassify_notify_notifyScale {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"notify_scale" defaultValue:nil], 1.0, 0.6, 1.5);
}
- (BOOL)axs_glassify_notify_gradientOn {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"gradient_on" defaultValue:nil], NO);
}
- (double)axs_glassify_notify_gradientHue1 {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"gradient_hue1" defaultValue:nil], 0.5, 0.0, 1.0);
}
- (double)axs_glassify_notify_gradientHue2 {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"gradient_hue2" defaultValue:nil], 0.85, 0.0, 1.0);
}
- (double)axs_glassify_notify_gradientSpeed {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"gradient_speed" defaultValue:nil], 0.3, 0.02, 2.0);
}
- (double)axs_glassify_notify_gradientOpacity {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"gradient_opacity" defaultValue:nil], 0.35, 0.05, 1.0);
}
// 出现动画模式（旧键 elastic_on 兼容：1=果冻弹跳）。
- (NSInteger)axs_glassify_notify_appearMode {
    id v = [self axs_glassify_notify_valueForKey:@"appear_mode" defaultValue:nil];
    if (![v isKindOfClass:[NSNumber class]]) {
        return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"elastic_on" defaultValue:nil], NO) ? 1 : 0;
    }
    return (NSInteger)axs_glassify_notify_clamped(v, 1.0, 0.0, 4.0);
}
- (double)axs_glassify_notify_appearIntensity {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"elastic_intensity" defaultValue:nil], 1.0, 0.2, 2.0);
}
- (BOOL)axs_glassify_notify_touchGlowOn {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"touch_glow_on" defaultValue:nil], NO);
}
- (BOOL)axs_glassify_notify_touchHaptic {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"touch_haptic" defaultValue:nil], YES);
}
- (BOOL)axs_glassify_notify_fishOn {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"fish_on" defaultValue:nil], NO);
}
- (NSInteger)axs_glassify_notify_fishCount {
    double d = axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"fish_count" defaultValue:nil], 3.0, 1.0, 8.0);
    return (NSInteger)d;
}
- (double)axs_glassify_notify_fishSize {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"fish_size" defaultValue:nil], 1.0, 0.5, 2.0);
}
- (NSString *)axs_glassify_notify_fishPng {
    id v = [self axs_glassify_notify_valueForKey:@"fish_png" defaultValue:nil];
    return [v isKindOfClass:[NSString class]] ? v : @"";
}
- (double)axs_glassify_notify_bubbleSize {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"bubble_size" defaultValue:nil], 1.0, 0.5, 2.0);
}
- (double)axs_glassify_notify_bubbleOpacity {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"bubble_opacity" defaultValue:nil], 0.9, 0.1, 1.0);
}
- (NSInteger)axs_glassify_notify_particleDir {
    double d = axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"particle_dir" defaultValue:nil], 0.0, 0.0, 3.0);
    return (NSInteger)d;
}
- (BOOL)axs_glassify_notify_chargeFx {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"charge_fx" defaultValue:nil], NO);
}
- (double)axs_glassify_notify_chargeSize {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"charge_size" defaultValue:nil],
                                       1.0, 0.6, 2.0);
}
- (BOOL)axs_glassify_notify_lowPowerGuard {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"low_power_guard" defaultValue:nil], YES);
}
- (BOOL)axs_glassify_notify_autoSchedule {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"auto_schedule" defaultValue:nil], NO);
}
- (NSString *)axs_glassify_notify_scheduleDayName {
    id v = [self axs_glassify_notify_valueForKey:@"schedule_day" defaultValue:nil];
    return [v isKindOfClass:[NSString class]] ? v : @"";
}
- (NSString *)axs_glassify_notify_scheduleNightName {
    id v = [self axs_glassify_notify_valueForKey:@"schedule_night" defaultValue:nil];
    return [v isKindOfClass:[NSString class]] ? v : @"";
}
- (NSInteger)axs_glassify_notify_colorSource {
    double d = axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"color_source" defaultValue:nil], 0.0, 0.0, 2.0);
    return (NSInteger)d;
}
- (BOOL)axs_glassify_notify_darkDim {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"dark_dim" defaultValue:nil], NO);
}
- (BOOL)axs_glassify_notify_burstOn {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"burst_on" defaultValue:nil], NO);
}
- (double)axs_glassify_notify_burstIntensity {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"burst_intensity" defaultValue:nil], 1.0, 0.2, 2.0);
}
- (BOOL)axs_glassify_notify_dissolveOn {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"dissolve_on" defaultValue:nil], NO);
}
- (BOOL)axs_glassify_notify_particleOn {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"particle_on" defaultValue:nil], NO);
}
- (double)axs_glassify_notify_particleSize {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"particle_size" defaultValue:nil], 1.0, 0.5, 2.0);
}
- (double)axs_glassify_notify_particleDensity {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"particle_density" defaultValue:nil], 1.0, 0.5, 3.0);
}
- (NSString *)axs_glassify_notify_particlePng {
    id v = [self axs_glassify_notify_valueForKey:@"particle_png" defaultValue:nil];
    // 默认值必须与设置面板 default 一致（未手动编辑时偏好文件里没有该键）。
    return [v isKindOfClass:[NSString class]] ? v : @"/var/mobile/Documents/Glassify/particle.png";
}
- (NSString *)axs_glassify_notify_burstPng {
    id v = [self axs_glassify_notify_valueForKey:@"burst_png" defaultValue:nil];
    return [v isKindOfClass:[NSString class]] ? v : @"/var/mobile/Documents/Glassify/burst.png";
}

// ── 文字与图标 ──
- (BOOL)axs_glassify_notify_titleColorOn {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:@"title_color_on" defaultValue:nil], NO);
}
- (double)axs_glassify_notify_titleHue {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"title_hue" defaultValue:nil], 0.55, 0.0, 1.0);
}
- (double)axs_glassify_notify_titleGlow {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"title_glow" defaultValue:nil], 0.0, 0.0, 1.0);
}
- (double)axs_glassify_notify_iconCorner {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"icon_corner" defaultValue:nil], 0.0, 0.0, 24.0);
}
- (double)axs_glassify_notify_iconScale {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"icon_scale" defaultValue:nil], 1.0, 0.7, 1.5);
}
- (double)axs_glassify_notify_iconGlow {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"icon_glow" defaultValue:nil], 0.0, 0.0, 1.0);
}

// ── 布局光影（0 = 保持系统默认） ──
- (double)axs_glassify_notify_cornerRadius {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"corner_radius" defaultValue:nil], 0.0, 0.0, 40.0);
}
- (double)axs_glassify_notify_notifyOpacity {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"notify_opacity" defaultValue:nil], 1.0, 0.3, 1.0);
}
- (double)axs_glassify_notify_shadowIntensity {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"shadow_intensity" defaultValue:nil], 0.0, 0.0, 1.0);
}
- (double)axs_glassify_notify_tiltIntensity {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"tilt_intensity" defaultValue:nil], 0.0, 0.0, 1.0);
}
- (double)axs_glassify_notify_notifyWidth {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"notify_width" defaultValue:nil], 1.0, 0.6, 1.0);
}
- (double)axs_glassify_notify_sCurveAmp {
    return axs_glassify_notify_clamped([self axs_glassify_notify_valueForKey:@"s_curve_amp" defaultValue:nil], 0.0, 0.0, 60.0);
}

// ── S 形贝塞尔通知（合并自 com.axs.sbeziernoti） ──
// 与原工程一致：缺键、类型不对、非有限值都回落到代码内默认，
// 默认值必须与 AxsGlassifyRoot.plist 里各行的 default 保持同步。
- (BOOL)axs_glassify_notify_sbezBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    return axs_glassify_notify_bool([self axs_glassify_notify_valueForKey:key defaultValue:nil], defaultValue);
}

- (double)axs_glassify_notify_sbezDoubleForKey:(NSString *)key defaultValue:(double)defaultValue {
    id value = [self axs_glassify_notify_valueForKey:key defaultValue:nil];
    if (![value isKindOfClass:[NSNumber class]]) return defaultValue;
    double d = [value doubleValue];
    return isfinite(d) ? d : defaultValue;
}

- (BOOL)axs_glassify_notify_sbezEntranceEnabled {
    return [self axs_glassify_notify_sbezBoolForKey:@"sbz_entrance_enabled" defaultValue:NO];
}

- (BOOL)axs_glassify_notify_sbezDecoEnabled {
    return [self axs_glassify_notify_sbezBoolForKey:@"sbz_decoration_enabled" defaultValue:NO];
}

- (BOOL)axs_glassify_notify_sbezDecoFadeStyle {
    return [self axs_glassify_notify_sbezBoolForKey:@"sbz_decoration_style" defaultValue:NO];
}

// 互斥仲裁的唯一真相：S 入场**轨迹**生效时，动画引擎不得再往同一 layer 上挂
// transform.scale 的出现动画 —— 整条 transform 与它的子键路径同层并存时，
// Core Animation 的表现层只会留下一份，观感就是抖动和落位错乱。
// 装饰线只动 strokeEnd，不在这条仲裁里。
- (BOOL)axs_glassify_notify_sbezEntranceActive {
    return [self axs_glassify_notify_isEnabled] && [self axs_glassify_notify_sbezEntranceEnabled];
}

- (BOOL)axs_glassify_notify_sbezDecoActive {
    return [self axs_glassify_notify_isEnabled] && [self axs_glassify_notify_sbezDecoEnabled];
}

// 滚动入场没有独立开关：特效档位 0 即「关闭」。
- (BOOL)axs_glassify_notify_sbezScrollActive {
    if (![self axs_glassify_notify_isEnabled]) return NO;
    return [self axs_glassify_notify_sbezDoubleForKey:@"sbz_scroll_effect" defaultValue:0.0] > 0.0;
}

// 蜿蜒排列的独立开关。振幅/波长/收缩/倾转在 ListEntrance 里读，
// 缺省必须与 AxsGlassifyRoot.plist 各行的 default 保持一致。
- (BOOL)axs_glassify_notify_sbezSerpActive {
    if (![self axs_glassify_notify_isEnabled]) return NO;
    return [self axs_glassify_notify_sbezBoolForKey:@"sbz_serp_enabled" defaultValue:NO];
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
