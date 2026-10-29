#import "AxsGlassifySliderCell.h"
#import <UIKit/UIKit.h>

@interface AxsGlassifySliderCell ()
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *valueLabel;
@end

@implementation AxsGlassifySliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier specifier:specifier];
    if (self) {
        _slider = [[UISlider alloc] initWithFrame:CGRectZero];
        [_slider addTarget:self action:@selector(axs_glassify_sliderMoved:)
          forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(axs_glassify_sliderCommitted:)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [self.contentView addSubview:_slider];
        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.adjustsFontSizeToFitWidth = YES;
        _valueLabel.minimumScaleFactor = 0.6;
        [self.contentView addSubview:_valueLabel];
        self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        [self axs_glassify_reloadState];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self axs_glassify_reloadState];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.handler = nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    CGFloat available = MAX(0.0, width - 32.0);
    CGFloat valueWidth = MIN(52.0, available * 0.25);
    CGFloat titleWidth = MIN(110.0, available * 0.32);
    CGFloat sliderX = 16.0 + titleWidth + 8.0;
    CGFloat valueX = MAX(sliderX, width - 16.0 - valueWidth);
    self.textLabel.frame = CGRectMake(16.0, 0, titleWidth, height);
    self.slider.frame = CGRectMake(sliderX, MAX(0.0, (height - 31.0) / 2.0),
                                  MAX(0.0, valueX - 8.0 - sliderX), 31.0);
    self.valueLabel.frame = CGRectMake(valueX, 0, valueWidth, height);
}

- (void)axs_glassify_reloadState {
    self.textLabel.text = self.specifier.name ?: @"";
    self.slider.accessibilityLabel = self.textLabel.text;
    double minimum = [[self.specifier propertyForKey:@"min"] doubleValue];
    double maximum = [[self.specifier propertyForKey:@"max"] doubleValue];
    if (!isfinite(minimum)) minimum = 0.0;
    if (!isfinite(maximum) || maximum <= minimum) maximum = minimum + 1.0;
    self.slider.minimumValue = minimum;
    self.slider.maximumValue = maximum;
    id initial = [self.specifier propertyForKey:@"default"];
    double value = self.handler ? [self.handler axs_glassify_sliderValueForSpecifier:self.specifier]
                               : [initial doubleValue];
    if (!isfinite(value)) value = minimum;
    self.slider.value = fmax(minimum, fmin(maximum, value));
    [self axs_glassify_updateLabel];
}

- (void)axs_glassify_updateLabel {
    NSString *value = [NSString stringWithFormat:@"%.1f", self.slider.value];
    self.valueLabel.text = value;
    self.slider.accessibilityValue = value;
}

- (void)axs_glassify_sliderMoved:(UISlider *)sender {
    [self axs_glassify_updateLabel];
    // VoiceOver adjustments do not necessarily emit touch-up events.
    if (UIAccessibilityIsVoiceOverRunning()) {
        [self axs_glassify_sliderCommitted:sender];
    }
}

- (void)axs_glassify_sliderCommitted:(UISlider *)sender {
    [self axs_glassify_updateLabel];
    [self.handler axs_glassify_setSliderValue:sender.value specifier:self.specifier];
}

@end
