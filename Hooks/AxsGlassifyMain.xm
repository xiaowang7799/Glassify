#import <UIKit/UIKit.h>
#import <math.h>
#import <dispatch/dispatch.h>
#import "AxsGlassifyConfig.h"
#import "AxsGlassifyGlass.h"
#import "AxsGlassifyPreferences.h"

// Resolve the SpringBoard key window the glass layer attaches to.
// UIApplication.windows is deprecated since iOS 15, so walk the connected scenes instead.
static UIWindow *axs_glassify_mainWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
        if (!fallback) {
            fallback = windowScene.windows.firstObject;
        }
    }
    return fallback;
}

static double axs_glassify_configDouble(AxsGlassifyConfig *config, NSString *key, double fallback) {
    id value = [config axs_glassify_valueForKey:key defaultValue:@(fallback)];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

static BOOL axs_glassify_configBool(AxsGlassifyConfig *config, NSString *key, BOOL fallback) {
    id value = [config axs_glassify_valueForKey:key defaultValue:@(fallback)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

// Apply the current snapshot to the SpringBoard main window. Safe to call repeatedly.
static void axs_glassify_applyCurrent(void) {
    AxsGlassifyConfig *config = [AxsGlassifyConfig axs_glassify_shared];
    BOOL enabled = [config axs_glassify_isEnabled];
    double strength = axs_glassify_configDouble(config, @"strength", 0.35);
    BOOL dark = axs_glassify_configBool(config, @"dark", NO);
    [AxsGlassifyGlass axs_glassify_updateGlassInWindow:axs_glassify_mainWindow()
                                              enabled:enabled
                                             strength:strength
                                                 dark:dark];
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    if (![[AxsGlassifyConfig axs_glassify_shared] axs_glassify_isEnabled]) {
        return;
    }
    // The key window may not exist yet this early; retry shortly after launch.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        axs_glassify_applyCurrent();
    });
}

%end

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [AxsGlassifyConfig axs_glassify_shared];

        // Re-apply live whenever the settings panel saves a new snapshot.
        [[NSNotificationCenter defaultCenter] addObserverForName:AxsGlassifyPreferencesChanged
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            axs_glassify_applyCurrent();
        }];

        // Attach once the SpringBoard main window actually becomes key.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if (note.object == axs_glassify_mainWindow()) {
                axs_glassify_applyCurrent();
            }
        }];
    }
}
