#import <UIKit/UIKit.h>
#import "AxsGlassifyLiquid.h"
#import "AxsGlassifyNotifications.h"

// Lock screen / notification center platters. The classes below only exist inside
// SpringBoard, so each hook group is installed only when its class is present.

static BOOL axs_glassify_contains_short_look(UIView *view, NSUInteger depth) {
    if (depth > 3) {
        return NO;
    }
    for (UIView *subview in view.subviews) {
        if ([NSStringFromClass([subview class]) containsString:@"ShortLook"]) {
            return YES;
        }
        if (axs_glassify_contains_short_look(subview, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

%group AxsGlassifyShortLook

%hook NCNotificationShortLookView

- (void)layoutSubviews {
    %orig;
    [AxsGlassifyLiquid axs_glassify_applyToPlatter:(UIView *)self];
}

%end

%end

%group AxsGlassifyListCell

%hook NCNotificationListCell

- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    // On iOS 16+ the visible card is a short look view inside the cell; styling
    // both would stack two glass layers.
    if (axs_glassify_contains_short_look(cell, 0)) {
        return;
    }
    [AxsGlassifyLiquid axs_glassify_applyToPlatter:cell];
}

%end

%end

%ctor {
    if (NSClassFromString(@"NCNotificationShortLookView")) {
        %init(AxsGlassifyShortLook);
    }
    if (NSClassFromString(@"NCNotificationListCell")) {
        %init(AxsGlassifyListCell);
    }
}
