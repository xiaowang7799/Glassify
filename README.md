# 液态玻璃（Glassify）

一个原创的 iOS 越狱插件：把系统里**本来就有毛玻璃**的界面（控制中心、通知中心、文件夹、Dock、App 切换器…）重绘成更明显的"液态玻璃"材质。
使用公开的 `UIVisualEffectView` / `UIBlurEffect` 实现，不依赖逆向或第三方私有二进制。

> 注意：它**不会**给整个桌面盖一层模糊。桌面/图标本身没有毛玻璃层，所以保持清晰；
> 只有系统原本就带模糊的控件会被增强。

## 功能

- **启用/关闭**：开关控制是否增强系统毛玻璃；关闭时恢复系统原有材质。
- **玻璃强度**：0.0–1.0，映射到系统材质 UltraThin → Thick。
- **强制深色玻璃**：默认关闭时使用自适应材质（跟随系统深浅色）；打开后强制深色材质。
- 设置保存后实时生效（遍历现有控件并重设材质），无需重启 SpringBoard。

## 实现要点

- `Hooks/AxsGlassifyMain.xm`：钩住 `UIVisualEffectView -initWithEffect:`，在系统创建模糊视图时改写其效果。
  因为只作用于"已经模糊"的视图，桌面不受影响。
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

本工程是独立原创实现，与任何第三方付费插件无代码或逆向关系。
静态检查与 CI 编译通过不代表真机视觉验收；不同 iOS 版本的控件实现可能不同，需按设备微调。
