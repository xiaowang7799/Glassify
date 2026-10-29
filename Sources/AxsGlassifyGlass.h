#pragma once

#import <UIKit/UIKit.h>

// Mounts (or updates, or removes) a single non-interactive frosted-glass layer
// inside the given window. Safe to call repeatedly: the layer is tagged and reused.
@interface AxsGlassifyGlass : NSObject
+ (void)axs_glassify_updateGlassInWindow:(UIWindow *)window
                                 enabled:(BOOL)enabled
                                strength:(double)strength
                                    dark:(BOOL)dark;
@end
