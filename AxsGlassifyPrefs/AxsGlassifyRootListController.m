#import "AxsGlassifyRootListController.h"
#import "AxsGlassifyPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "AxsGlassifySliderCell.h"

// 合并后的唯一根面板：玻璃外观 + 锁屏通知美化共用一套偏好域 com.axs.glassify。
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

#pragma mark - 列表

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        [self axs_glassify_migrateLegacyPreferences];
        NSMutableArray *items = [[self loadSpecifiersFromPlistName:@"AxsGlassifyRoot"
                                                           target:self] mutableCopy];
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
    return axs_glassify_readPreferences()[key] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return;
    NSError *error = nil;
    if (!axs_glassify_writePreference(key, value, &error)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存"
            message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [self reloadSpecifiers];
    }
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
             @"tilt_intensity", @"notify_width",
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
                NSError *error = nil;
                for (NSString *key in axs_glassify_presetKeys()) {
                    id v = settings[key];
                    if (v) axs_glassify_writePreference(key, v, &error);
                }
                [self reloadSpecifiers];
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
