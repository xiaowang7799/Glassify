#pragma once

#import <UIKit/UIKit.h>

// Private UIKit backdrop classes used by SpringBoard for control center,
// notification center, folder and dock backgrounds. Method presence varies by
// iOS version, so every call site is guarded with -respondsToSelector:.
@interface _UIBackdropView : UIView
@end

@interface _UIBackdropViewSettings : NSObject
- (void)setDefaultValues;
- (void)setBlurRadius:(double)radius;
- (void)setSaturationDeltaFactor:(double)factor;
- (void)setGrayscaleTintLevel:(double)level;
- (void)setGrayscaleTintAlpha:(double)alpha;
@end

