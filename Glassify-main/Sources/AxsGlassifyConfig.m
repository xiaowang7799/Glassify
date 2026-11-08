#import "AxsGlassifyConfig.h"
#import "AxsGlassifyPreferences.h"

@interface AxsGlassifyConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_glassify_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsGlassifyConfig *config = (__bridge AxsGlassifyConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_glassify_reload];
    });
}

@implementation AxsGlassifyConfig

+ (instancetype)axs_glassify_shared {
    static AxsGlassifyConfig *instance;
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
        [self axs_glassify_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_glassify_preferencesDidChange,
            (__bridge CFStringRef)AxsGlassifyPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_glassify_reload]; });
    }
    return self;
}

- (void)axs_glassify_reload {
    self.snapshot = axs_glassify_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsGlassifyPreferencesChanged object:self];
    });
}

- (id)axs_glassify_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_glassify_isEnabled {
    id value = [self axs_glassify_valueForKey:@"enabled" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
