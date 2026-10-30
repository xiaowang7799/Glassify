#pragma once

#import <UIKit/UIKit.h>

// SpringBoard's lock screen / notification center platter classes. Only the
// geometry we touch is declared; everything else is reached through UIView.
// Method presence varies between iOS releases, so hooks are installed only when
// the class actually exists at runtime (see Hooks/AxsGlassifyNotifications.xm).
@interface NCNotificationShortLookView : UIView
@end

@interface NCNotificationListCell : UIView
@end
