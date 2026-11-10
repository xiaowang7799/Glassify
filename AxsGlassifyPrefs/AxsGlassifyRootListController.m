#import "AxsGlassifyRootListController.h"
#import "AxsGlassifyPreferences.h"
#import "AxsGlassifySBezierDiagnostics.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "AxsGlassifySliderCell.h"

// 合并后的唯一根面板：玻璃外观 + 锁屏通知美化 + S 形贝塞尔入场共用一套偏好域 com.axs.glassify。
@interface AxsGlassifyRootListController () <AxsGlassifySliderCellHandler>
@end

@implementation AxsGlassifyRootListController

#pragma mark - 旧版「液态通知」偏好迁移

// 合并前通知美化用独立域 com.axs.notifyliquid。升级用户第一次打开面板时把旧值搬过来。
static NSString *axs_glassify_legacyPreferencesPath(void) {
    NSString *modern = axs_glassify_preferencesPath();
    return [[modern stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"com.axs.notifyliquid.plist"];
}

- (void)axs_glassify_migrateLegacyPreferences {
    NSDictionary *current = axs_glassify_readPreferences();
    if (current[@"migrated_notifyliquid"]) {
        return;
    }
    NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:axs_glassify_legacyPreferencesPath()];
    if (![legacy isKindOfClass:[NSDictionary class]] || legacy.count == 0) {
        return;
    }
    NSError *error = nil;
    for (NSString *key in legacy) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if (current[key]) continue;   // 新域已有的值优先
        axs_glassify_writePreference(key, legacy[key], &error);
    }
    axs_glassify_writePreference(@"migrated_notifyliquid", @YES, &error);
}

#pragma mark - 旧版「S 形贝塞尔通知」偏好迁移

// 旧域 com.axs.sbeziernoti 用的是裸名（duration / amplitude / width / opacity / hue /
// scrollEffect …），合并后统一加 sbz_ 前缀，否则会和新键撞名。旧值仍要保住，
// 所以这里显式列出「旧键 -> 新键」的对应表。
//
// 注意：**故意不搬旧插件的 `enabled`**。合并后 `enabled` 是全插件总开关，一开就连带
// 增强系统毛玻璃（`_UIBackdropViewSettings` 级别的进程内 hook）。只用过 S形贝塞尔通知的
// 用户升级后被静默打开玻璃，属于「改了没要求我改的东西」，所以这里只搬特效参数，
// 总开关留给用户自己打开（面板对应分组的 footerText 会说明）。
static NSDictionary<NSString *, NSString *> *axs_glassify_sbez_migrations(void) {
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"entranceEnabled": @"sbz_entrance_enabled",
            @"debugLog":        @"sbz_debug_log",
            @"scrollEffect":    @"sbz_scroll_effect",
            @"scrollDuration":  @"sbz_scroll_duration",
            @"scrollAmplitude": @"sbz_scroll_amplitude",
            @"scrollSpan":      @"sbz_scroll_span",
            @"scrollVariation": @"sbz_scroll_variation",
            @"duration":        @"sbz_duration",
            @"amplitude":       @"sbz_amplitude",
            @"frequency":       @"sbz_frequency",
            @"phase":           @"sbz_phase",
            @"width":           @"sbz_width",
            @"opacity":         @"sbz_opacity",
            @"hue":             @"sbz_hue",
        };
    });
    return map;
}

// 只做一次（migrated_sbeziernoti 标记）。已经在本域里存在的新键优先，
// 旧值不覆盖用户可能在合并后已经调过的设置。
- (void)axs_glassify_migrateSBezierPreferences {
    NSDictionary *current = axs_glassify_readPreferences();
    if (current[@"migrated_sbeziernoti"]) {
        return;
    }
    NSString *modern = axs_glassify_preferencesPath();
    NSString *legacyPath = [[modern stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"com.axs.sbeziernoti.plist"];
    NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
    NSError *error = nil;
    if ([legacy isKindOfClass:[NSDictionary class]] && legacy.count > 0) {
        // 旧插件的开关语义是「enabled 打开才生效」，和合并后一致，所以直接搬。
        NSDictionary *map = axs_glassify_sbez_migrations();
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSString *oldKey in map) {
            id v = legacy[oldKey];
            NSString *newKey = map[oldKey];
            if (v == nil || current[newKey] != nil) continue;   // 缺键或新域已有值：不动
            values[newKey] = v;
        }
        if (values.count > 0) {
            axs_glassify_writePreferences(values, &error);
        }
    }
    axs_glassify_writePreference(@"migrated_sbeziernoti", @YES, &error);
}

#pragma mark - 列表

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        [self axs_glassify_migrateLegacyPreferences];
        [self axs_glassify_migrateSBezierPreferences];
        NSMutableArray *items = [[self loadSpecifiersFromPlistName:@"AxsGlassifyRoot"
                                                           target:self] mutableCopy];
        // S 形贝塞尔部分保留了原插件的自报告：dylib 是唯一写入方，这里只读，
        // 打开本页就能看到它有没有跑起来、读到什么配置、认出了哪些列表。
        NSString *report = axs_glassify_sbez_diagnosticsReport();
        for (PSSpecifier *specifier in items) {
            if ([[specifier propertyForKey:@"axsSBezierDiagnostics"] boolValue]) {
                [specifier setProperty:report forKey:@"footerText"];
            }
        }
        [items addObject:[PSSpecifier preferenceSpecifierNamed:@"关于我们" target:self
                     set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [items addObject:[PSSpecifier preferenceSpecifierNamed:@"搞机群友三叶草"
                                                        target:nil
                                                           set:nil
                                                           get:nil
                                                        detail:nil
                                                          cell:PSTitleValueCell
                                                          edit:nil]];
        _specifiers = items;
    }
    return _specifiers;
}

#pragma mark - 读写（唯一写入方，写完广播变更通知）

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return nil;
    return axs_glassify_cachedPreferences()[key] ?: [specifier propertyForKey:@"default"];
}

- (void)axs_glassify_presentWriteError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存"
        message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return;
    NSError *error = nil;
    if (!axs_glassify_writePreference(key, value, &error)) {
        [self axs_glassify_presentWriteError:error];
        [self reloadSpecifiers];
    }
}

#pragma mark - 快捷方案（一次写多个键，只重写文件 / 广播一次）

- (void)axs_glassify_applyQuickScheme:(NSDictionary *)values {
    NSError *error = nil;
    if (!axs_glassify_writePreferences(values, &error)) {
        [self axs_glassify_presentWriteError:error];
        return;
    }
    [self reloadSpecifiers];
}

// 省电：只留玻璃本体，所有逐帧特效关掉，低电量自动降载保持开启。
- (void)axs_glassify_applyPowerSaver:(id)sender {
    [self axs_glassify_applyQuickScheme:@{
        @"gradient_on": @NO,
        @"fish_on": @NO,
        @"particle_on": @NO,
        @"charge_fx": @NO,
        @"burst_on": @NO,
        @"dissolve_on": @NO,
        @"touch_glow_on": @NO,
        @"motion_highlight": @NO,
        @"low_power_guard": @YES,
        @"sbz_entrance_enabled": @NO,
        @"sbz_scroll_effect": @0,
    }];
}

// 炫酷：渐变 + 游鱼 + 到达爆发 + 拖动 S 曲线 + 轻倾斜，都取中间值，避免一上来就拉满。
- (void)axs_glassify_applyShowcase:(id)sender {
    [self axs_glassify_applyQuickScheme:@{
        @"gradient_on": @YES,
        @"gradient_opacity": @0.35,
        @"gradient_speed": @0.30,
        @"fish_on": @YES,
        @"fish_count": @3,
        @"fish_size": @1.0,
        @"burst_on": @YES,
        @"burst_intensity": @1.0,
        @"dissolve_on": @YES,
        @"touch_glow_on": @YES,
        @"touch_haptic": @YES,
        @"s_curve_amp": @35,
        @"corner_radius": @22,
        @"tilt_intensity": @0.40,
        @"icon_glow": @0.60,
        @"low_power_guard": @YES,
        // S 形贝塞尔：滚动列表用轻一档的「上浮」，横幅 S 入场留给横幅自己。
        // 注意 appear_mode 会被 sbz_entrance_enabled 互斥顶掉，这里显式归零避免歧义。
        @"sbz_scroll_effect": @5,
        @"sbz_entrance_enabled": @YES,
        @"appear_mode": @0,
    }];
}

#pragma mark - 滑条

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([PSListController instancesRespondToSelector:_cmd]) {
        [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    }
    if ([cell isKindOfClass:[AxsGlassifySliderCell class]]) {
        AxsGlassifySliderCell *sliderCell = (AxsGlassifySliderCell *)cell;
        sliderCell.handler = self;
        [sliderCell axs_glassify_reloadState];
    }
}

- (double)axs_glassify_sliderValueForSpecifier:(PSSpecifier *)specifier {
    id value = [self readPreferenceValue:specifier];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.0;
}

- (void)axs_glassify_setSliderValue:(double)value specifier:(PSSpecifier *)specifier {
    double minimum = [[specifier propertyForKey:@"min"] doubleValue];
    double maximum = [[specifier propertyForKey:@"max"] doubleValue];
    if (!isfinite(minimum)) minimum = 0.0;
    if (!isfinite(maximum) || maximum <= minimum) maximum = minimum + 1.0;
    if (!isfinite(value)) value = minimum;
    [self setPreferenceValue:@(fmax(minimum, fmin(maximum, value))) specifier:specifier];
}

#pragma mark - 素材文件夹

// 打开素材文件夹（不存在则创建），跳 Filza。素材放这里，
// 路径填 /var/mobile/Documents/Glassify/文件名.png 即可。
- (void)axs_glassify_openAssetsFolder:(id)sender {
    NSString *dir = @"/var/mobile/Documents/Glassify";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSURL *url = [NSURL URLWithString:[@"filza://" stringByAppendingString:dir]];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark - 自定义预设（保存 / 应用 / 删除）

static NSArray<NSString *> *axs_glassify_presetKeys(void) {
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
             @"sbz_entrance_enabled", @"sbz_debug_log",
             @"sbz_scroll_effect", @"sbz_scroll_duration", @"sbz_scroll_amplitude",
             @"sbz_scroll_span", @"sbz_scroll_variation",
             @"sbz_duration", @"sbz_amplitude", @"sbz_frequency",
             @"sbz_phase", @"sbz_width", @"sbz_opacity", @"sbz_hue",
             @"auto_schedule", @"schedule_day", @"schedule_night"];
}

- (void)axs_glassify_savePreset:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存预设"
        message:@"给当前配置起个名字" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"例如：星空夜";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *act) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (name.length == 0) return;
        NSDictionary *all = axs_glassify_readPreferences();
        NSMutableDictionary *settings = [NSMutableDictionary dictionary];
        for (NSString *key in axs_glassify_presetKeys()) {
            id v = all[key];
            if (v) settings[key] = v;
        }
        NSArray *existing = [all[@"custom_presets"] isKindOfClass:[NSArray class]] ? all[@"custom_presets"] : @[];
        NSMutableArray *presets = [existing mutableCopy];
        [presets addObject:@{@"name": name, @"settings": settings}];
        NSError *error = nil;
        axs_glassify_writePreference(@"custom_presets", presets, &error);
        [self reloadSpecifiers];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)axs_glassify_managePresets:(id)sender {
    NSDictionary *all = axs_glassify_readPreferences();
    NSArray<NSDictionary *> *presets = [all[@"custom_presets"] isKindOfClass:[NSArray class]] ? all[@"custom_presets"] : @[];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"已存预设"
        message:presets.count ? nil : @"还没有保存的预设" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *preset in presets) {
        NSString *name = [preset objectForKey:@"name"] ?: @"未命名";
        [sheet addAction:[UIAlertAction actionWithTitle:[@"应用：" stringByAppendingString:name]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            NSDictionary *settings = [preset objectForKey:@"settings"];
            if ([settings isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *values = [NSMutableDictionary dictionary];
                for (NSString *key in axs_glassify_presetKeys()) {
                    id v = settings[key];
                    if (v) values[key] = v;
                }
                [self axs_glassify_applyQuickScheme:values];
            }
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:[@"删除：" stringByAppendingString:name]
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
            NSMutableArray *next = [presets mutableCopy];
            [next removeObject:preset];
            NSError *error = nil;
            axs_glassify_writePreference(@"custom_presets", next, &error);
            [self reloadSpecifiers];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
