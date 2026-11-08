#pragma once

#import <Foundation/Foundation.h>

@interface AxsGlassifyConfig : NSObject
+ (instancetype)axs_glassify_shared;
- (BOOL)axs_glassify_isEnabled;
- (id)axs_glassify_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_glassify_reload;
@end
