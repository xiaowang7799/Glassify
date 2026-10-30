# 液态玻璃（Glassify）

一个原创的 iOS 越狱插件：把系统里**本来就有毛玻璃**的界面（控制中心、通知中心、文件夹、Dock、App 切换器…）重绘成更明显的"液态玻璃"材质。
使用公开的 `UIVisualEffectView` / `UIBlurEffect` 实现，不依赖逆向或第三方私有二进制。

> 注意：它**不会**给整个桌面盖一层模糊。桌面/图标本身没有毛玻璃层，所以保持清晰；
> 只有系统原本就带模糊的控件会被增强。

## 功能

- **启用/关闭**：开关控制是否增强系统毛玻璃；关闭时恢复系统原有材质。
- **玻璃强度**：0.0–1.0，映射到系统材质 UltraThin → Thick。
- **强制深色玻璃**：默认关闭时使用自适应材质（跟随系统深浅色）；打开后强制深色材质。
- **液态玻璃通知**：锁屏/通知中心的通知卡片换成本插件自己的玻璃面板（顶部柔光 + 左右边缘色散 + 45° 镜面描边）。
- 设置保存后实时生效（遍历现有控件并重设材质），无需重启 SpringBoard。

## 锁屏通知液态玻璃

`Hooks/AxsGlassifyNotifications.xm` 只挂 `NCNotificationShortLookView`（iOS 16+ 的列表卡片是
`NCNotificationListCell`，里面已经有 ShortLook 时不再重复上玻璃，避免两层玻璃叠在一起）。
每张卡片上做三件事：

1. 把卡片自带的 `_UIBackdropView` 背景临时隐藏（只隐藏类名含 `Backdrop` 且原本完全可见的子视图，关闭开关时逐个还原）；
2. 在 index 0 插入一个 `UIVisualEffectView` 作为卡片底板，圆角跟随原卡片（取不到时退回 22pt）；
3. 在底板上叠加装饰层：顶部 55% 的白色柔光、左右 5% 的边缘色散、以及 `AxsGlassifyGlass` 统一加的 45° 镜面描边。

材质本身分两条路径：

- **iOS 26+**：直接使用系统的 `UIGlassEffect`（`+effectWithStyle:`，`regular` 样式），这就是 Apple 自己的 Liquid Glass，
  带真实的透镜折射与高光。因为构建用的 16.5 SDK 里没有这个类，全部通过 `NSClassFromString` + `objc_msgSend` 动态调用，
  其它系统版本上自动跳过。
- **iOS 14–18**：UIKit 不向第三方开放背景纹理，拿不到真实折射，退回 `UIBlurEffectStyleSystemChromeMaterial`
  （系统给 platter 用的那档材质）再叠加上述高光/色散近似。

## 实现要点

- `Hooks/AxsGlassifyMain.xm`：
  - 钩住私有 `_UIBackdropViewSettings -setDefaultValues`，直接调 `blurRadius` / `saturationDeltaFactor` /
    `grayscaleTint*` —— **控制中心、通知中心、文件夹、Dock 背景实际由 `_UIBackdropView` 渲染，靠这里才生效**。
    所有私有 setter 都用 `-respondsToSelector:` 保护，不同 iOS 版本缺方法时自动跳过。
    同时在 `setBlurRadius:` / `setSaturationDeltaFactor:` 里做强制下限，避免 iOS 17 在默认值之后又写回原值。
  - 钩 `_UIBackdropView -layoutSubviews`，在圆角足够大的 backdrop 上叠加 45° 白色边缘高光（CALayer 渐变描边），
    对应参考库里的 specular highlight。
  - 同时钩 `UIVisualEffectView -initWithEffect:`，覆盖使用公开毛玻璃的界面。
- `Sources/AxsGlassifyGlass.{h,m}`：
  - 把任意 `UIBlurEffect` 重映射为目标强度/深浅的材质；
  - 用关联对象记住每个视图原始 effect，关闭时精确还原；
  - `axs_glassify_refreshAllWindows` 在设置变更时遍历窗口树，实时更新/还原。
- `Sources/AxsGlassifyConfig.*`：配置快照；只读，不在 `%ctor` 里写默认值。
- `AxsGlassifyPrefs/`：设置面板，是配置文件的唯一写入方。

## 构建

需要可用的 Theos 工具链与约定的 SDK（16.5）。

```sh
sh build.sh rootless          # rootless
sh build.sh roothide          # RootHide
sh build.sh all               # rootful + rootless + roothide
```

产物在 `packages/`；GitHub Actions 默认构建 rootless + roothide 并发布 Release。

## 自定义方向

- 想让某些**没有**模糊的界面也变玻璃（例如文件夹背景、Dock 底板），可在对应视图上
  主动插入 `UIVisualEffectView`——但要按界面精确指定，避免又变成整屏模糊。
- 想扩大到独立 App（不仅 SpringBoard），修改注入过滤器 bundle 列表并在 `UIVisualEffectView`
  钩子中确认对 App 内控件是否合适。
- 新增配置项时，在 `AxsGlassifyRoot.plist` 声明默认值，并在消费端给出一致的缺键回退。

## 说明

视觉参数参考了 Kyant0/AndroidLiquidGlass（Apache-2.0）与 zzsj0928/luci-theme-liquid 的玻璃 token：
模糊 26、饱和 1.6、白色 tint 0.42、白色描边 0.8、内高光 0.95。
代码是独立用 UIKit/CoreAnimation 实现的，未拷贝其 Kotlin/AGSL 或 CSS 代码。
真正的折射/透镜（lens）与色散依赖 GPU shader 实时采样背景。iOS 26 起系统通过 `UIGlassEffect` 提供了这层能力，
本插件在 26+ 上直接复用它；iOS 14–18 上 SpringBoard 的私有 backdrop 不开放背景纹理，无法做真实折射，
只能做到模糊 + 饱和度 + 色调 + 边缘高光/色散的近似。
`_UIBackdropView` 是私有 API，不同 iOS 版本的方法集合会变化，代码已做 `-respondsToSelector:` 保护；
若某个界面仍无变化，说明该界面走了别的渲染路径，需要按设备版本再定位对应类。
静态检查与 CI 编译通过不代表真机视觉验收。
