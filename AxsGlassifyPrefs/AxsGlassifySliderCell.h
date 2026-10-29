#pragma once

#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#include <math.h>

@protocol AxsGlassifySliderCellHandler <NSObject>
- (double)axs_glassify_sliderValueForSpecifier:(PSSpecifier *)specifier;
- (void)axs_glassify_setSliderValue:(double)value specifier:(PSSpecifier *)specifier;
@end

@interface AxsGlassifySliderCell : PSTableCell
@property (nonatomic, weak) id<AxsGlassifySliderCellHandler> handler;
- (void)axs_glassify_reloadState;
@end
