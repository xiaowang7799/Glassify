#pragma once

#import <Foundation/Foundation.h>
#import "AxsGlassifyPreferences.h"

// A self-report the tweak leaves behind so the panel can display it. It lives in
// its own file, next to the configuration: the tweak is the only writer and the
// panel only reads, which keeps the single-writer rule for preferences intact.
//
// This exists because the alternative diagnostic (system log) is not always
// reachable: with this, opening the settings panel is enough to see whether the
// tweak is running, what configuration it actually read, and which classes it
// recognised.
static inline NSString *axs_glassify_sbez_diagnosticsPath(void) {
    NSString *configPath = axs_glassify_preferencesPath();
    if (configPath.length == 0) {
        return nil;
    }
    return [[configPath stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"com.axs.glassify.sbez.diag.plist"];
}

static inline NSDictionary *axs_glassify_sbez_diagnosticsRead(void) {
    NSString *path = axs_glassify_sbez_diagnosticsPath();
    if (path.length == 0) {
        return nil;
    }
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:path];
    return [values isKindOfClass:[NSDictionary class]] ? values : nil;
}

// Tweak side: merge into the existing record so unrelated keys survive.
static inline void axs_glassify_sbez_diagnosticsMerge(NSDictionary *update) {
    if (update.count == 0) {
        return;
    }
    NSString *path = axs_glassify_sbez_diagnosticsPath();
    if (path.length == 0) {
        return;
    }
    NSMutableDictionary *values = [axs_glassify_sbez_diagnosticsRead() mutableCopy];
    if (values == nil) {
        values = [NSMutableDictionary dictionary];
    }
    [values addEntriesFromDictionary:update];
    [values writeToFile:path atomically:YES];
}

// Tweak side: called once per SpringBoard launch so a stale report cannot be
// mistaken for a fresh one.
static inline void axs_glassify_sbez_diagnosticsReset(void) {
    NSString *path = axs_glassify_sbez_diagnosticsPath();
    if (path.length == 0) {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static inline NSString *axs_glassify_sbez_diagnosticsTimestamp(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"MM-dd HH:mm:ss";
    return [formatter stringFromDate:[NSDate date]];
}

// Tweak side, for hot paths. Keeps the last written value in memory and skips the
// file entirely when nothing changed: several of these call sites sit on a per-cell
// path, and a plist read plus an atomic write per cell would be real disk IO while
// scrolling - which is exactly what makes a tweak hot and thirsty.
static inline void axs_glassify_sbez_diagnosticsMergeIfChanged(NSString *key, NSString *value) {
    static NSMutableDictionary *written = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        written = [[NSMutableDictionary alloc] init];
    });
    if (key.length == 0 || value.length == 0) {
        return;
    }
    NSString *previous = written[key];
    if ([previous isKindOfClass:[NSString class]] && [previous isEqualToString:value]) {
        return;
    }
    written[key] = value;
    axs_glassify_sbez_diagnosticsMerge(@{key: value});
}

static inline void axs_glassify_sbez_diagnosticsNoteList(NSString *summary) {
    if (summary.length == 0) {
        return;
    }
    NSMutableArray *lists = [axs_glassify_sbez_diagnosticsRead()[@"lists"] mutableCopy];
    if (lists == nil) {
        lists = [NSMutableArray array];
    }
    if ([lists containsObject:summary]) {
        return;
    }
    [lists addObject:summary];
    while (lists.count > 8) {
        [lists removeObjectAtIndex:0];
    }
    axs_glassify_sbez_diagnosticsMerge(@{@"lists": lists});
}

// Panel side: a short report for a group footer.
static inline NSString *axs_glassify_sbez_diagnosticsReport(void) {
    NSDictionary *values = axs_glassify_sbez_diagnosticsRead();
    if (values == nil) {
        return @"没有诊断文件 —— Tweak 没有在 SpringBoard 里跑起来。\n"
                "说明 dylib 没被加载，或它的 %ctor 没有执行。";
    }

    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"载入：%@（%@）",
                      values[@"loadedAt"] ?: @"?", values[@"process"] ?: @"?"]];
    [lines addObject:[NSString stringWithFormat:@"Tweak 读到的配置：%@", values[@"config"] ?: @"?"]];

    NSArray *lists = values[@"lists"];
    if ([lists isKindOfClass:[NSArray class]] && lists.count > 0) {
        [lines addObject:[NSString stringWithFormat:@"识别到的列表（%lu）：", (unsigned long)lists.count]];
        for (NSString *entry in lists) {
            [lines addObject:[@"  · " stringByAppendingString:entry]];
        }
    } else {
        [lines addObject:@"识别到的列表：0（hook 没有在滚动视图/cell 上触发）"];
    }
    [lines addObject:[NSString stringWithFormat:@"最后一次播放：%@", values[@"lastEffect"] ?: @"（还没有）"]];
    return [lines componentsJoinedByString:@"\n"];
}
