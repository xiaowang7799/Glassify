#pragma once

#import <UIKit/UIKit.h>

// ControlCenterUI 的模块背景面板（每个控制中心模块一块）。
// 类只在 ControlCenterUI.framework 里，见 Hooks/AxsGlassifyControlCenter.xm 的加载处理。
@interface CCUIContentModuleBackgroundView : UIView
@end
