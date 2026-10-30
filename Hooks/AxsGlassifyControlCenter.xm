#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "AxsGlassifyControlCenter.h"
#import "AxsGlassifyLiquid.h"

// 控制中心每个模块的底板。iOS 13 起模块背景是 CCUIContentModuleBackgroundView
// （里面再包一层 _UIBackdropView / MTMaterialView），内容和它是兄弟视图，
// 所以在这里换材质不会影响图标和文字。
%group AxsGlassifyControlCenter

%hook CCUIContentModuleBackgroundView

- (void)layoutSubviews {
    %orig;
    [AxsGlassifyLiquid axs_glassify_applyToSurface:(UIView *)self];
}

%end

%end

%ctor {
    // 控制中心是懒加载的：SpringBoard 启动时 ControlCenterUI 可能还没被 dlopen，
    // 先确保类存在再注册 hook，否则这次启动就完全错过控制中心。
    if (!NSClassFromString(@"CCUIContentModuleBackgroundView")) {
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI",
               RTLD_LAZY);
    }
    if (NSClassFromString(@"CCUIContentModuleBackgroundView")) {
        %init(AxsGlassifyControlCenter);
    }
}
