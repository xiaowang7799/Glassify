#pragma once

#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>

// 自定义文本输入 Cell（PSTextFieldCell 在 iOS 14+ 不渲染输入框，自绘 UITextField 取代）。
@interface AxsGlassifyNotifyTextFieldCell : PSTableCell
@end
