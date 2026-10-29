#import <UIKit/UIKit.h>
#import "AxsGlassifyConfig.h"
#import "AxsGlassifyGlass.h"
#import "AxsGlassifyPreferences.h"

// Restyle every blur effect the system creates (control center, notifications,
// folders, dock, app switcher, ...). The home screen has no blur effect over its
// icons, so it stays sharp instead of being covered by a full-screen overlay.
%hook UIVisualEffectView

- (instancetype)initWithEffect:(UIVisualEffect *)effect {
    effect = [AxsGlassifyGlass axs_glassify_transformIncoming:effect forView:self];
    return %orig(effect);
}

%end

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [AxsGlassifyConfig axs_glassify_shared];

        // Re-apply / restore live whenever the settings panel saves a new snapshot.
        [[NSNotificationCenter defaultCenter] addObserverForName:AxsGlassifyPreferencesChanged
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            [AxsGlassifyGlass axs_glassify_refreshAllWindows];
        }];
    }
}
