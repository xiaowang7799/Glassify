#pragma once

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "AxsGlassifyPaths.h"

static NSString * const AxsGlassifyPreferencesDomain = @"com.axs.glassify";
static NSString * const AxsGlassifyPreferencesChanged = @"com.axs.glassify.preferences-changed";

static inline NSDictionary *axs_glassify_readPreferences(void) {
    NSString *path = axs_glassify_preferencesPath();
    NSDictionary *values = path.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if ([values isKindOfClass:[NSDictionary class]]) {
        return values;
    }
    // Compatibility fallback, not a second writable file location.
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AxsGlassifyPreferencesDomain];
    [defaults synchronize];
    return [defaults persistentDomainForName:AxsGlassifyPreferencesDomain] ?: @{};
}

// 设置面板的批量读取：每行 specifier 都要读一次配置，直接走 readPreferences
// 会在打开面板时把 plist 解析 60 多次。按文件修改时间缓存，写盘后 mtime 变了自然失效。
static inline NSDictionary *axs_glassify_cachedPreferences(void) {
    static NSDictionary *cached = nil;
    static NSTimeInterval cachedStamp = -1.0;
    NSString *path = axs_glassify_preferencesPath();
    NSDate *modified = nil;
    if (path.length > 0) {
        NSDictionary *attributes = [[NSFileManager defaultManager]
            attributesOfItemAtPath:path error:nil];
        modified = attributes[NSFileModificationDate];
    }
    NSTimeInterval stamp = modified ? [modified timeIntervalSinceReferenceDate] : -1.0;
    if (cached && stamp == cachedStamp) {
        return cached;
    }
    cached = axs_glassify_readPreferences();
    cachedStamp = stamp;
    return cached;
}

// The PreferenceBundle is the only caller allowed to write.
static inline BOOL axs_glassify_writePreference(NSString *key, id value, NSError **error) {
    NSString *path = axs_glassify_preferencesPath();
    if (key.length == 0 || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:AxsGlassifyPreferencesDomain code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid preference path or key"}];
        }
        return NO;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableDictionary *values;
    if ([manager fileExistsAtPath:path]) {
        NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:error];
        id decoded = existing ? [NSPropertyListSerialization propertyListWithData:existing
                         options:NSPropertyListMutableContainers format:NULL error:error] : nil;
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            if (error && !*error) {
                *error = [NSError errorWithDomain:AxsGlassifyPreferencesDomain code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Preferences are not a dictionary"}];
            }
            return NO;
        }
        values = [decoded mutableCopy];
    } else {
        values = [axs_glassify_readPreferences() mutableCopy];
    }
    if (value) values[key] = value;
    else [values removeObjectForKey:key];
    if (![manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:values
                         format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AxsGlassifyPreferencesDomain];
    // Mirror the whole snapshot so cfprefsd cannot flush stale unrelated keys.
    [defaults setPersistentDomain:values forName:AxsGlassifyPreferencesDomain];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)AxsGlassifyPreferencesChanged, NULL, NULL, true);
    return YES;
}
