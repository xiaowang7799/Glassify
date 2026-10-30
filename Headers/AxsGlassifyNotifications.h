#pragma once

#import <UIKit/UIKit.h>

// SpringBoard 的锁屏 / 通知中心卡片类。只声明用到的几何能力，
// 其余全部通过 UIView 访问；类不存在时对应的 hook 组不会安装。
@interface NCNotificationShortLookView : UIView
@end

@interface NCNotificationLongLookView : UIView
@end

@interface NCNotificationListCell : UIView
@end
