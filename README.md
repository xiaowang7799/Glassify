# 液态玻璃（Glassify）

一个原创的 iOS 越狱插件：在 SpringBoard 主窗口上叠加一层可调节的"液态玻璃"毛玻璃效果。
使用公开的 `UIVisualEffectView` / `UIBlurEffect` 实现，不依赖逆向或第三方私有二进制。

## 功能

- **启用/关闭**：开关控制是否挂载玻璃层。
- **玻璃强度**：0.0–1.0，映射到系统材质从最薄到最厚（UltraThin → Thick）。
- **深色玻璃**：切换浅色/深色材质族，并调整色调遮罩。
- 设置保存后实时生效，无需重启 SpringBoard。

## 实现要点

- `Sources/AxsGlassifyGlass.{h,m}`：玻璃图层工具类。同一个窗口只挂载一层（按 tag 复用），
  更新时只替换效果，关闭时移除；图层 `userInteractionEnabled = NO`，不拦截触摸。
- `Hooks/AxsGlassifyMain.xm`：在 `SpringBoard -applicationDidFinishLaunching:` 后挂载，
  并监听主窗口 `UIWindowDidBecomeKeyNotification` 与设置变更通知，实时刷新。
- `Sources/AxsGlassifyConfig.*`：配置快照；只读，不在 `%ctor` 里写默认值。
- `AxsGlassifyPrefs/`：设置面板，是配置文件的唯一写入方。

## 构建

需要可用的 Theos 工具链与本 skill 约定的 SDK（16.5）。

```sh
sh build.sh rootless          # 仅 rootless
sh build.sh rootful rootless  # 多环境
sh build.sh all               # rootful + rootless + roothide
```

产物在 `packages/`，用 `dpkg-deb -I` / `dpkg-deb -c` 核对包名、架构、注入过滤器与面板入口。
也可推送到 GitHub 触发默认 Actions 工作流构建发布。

## 自定义方向

- 想让玻璃只作用于特定界面（如控制中心、通知中心），可把 `axs_glassify_updateGlassInWindow:`
  的目标从主窗口换成对应视图，或在该视图 `didMoveToWindow` 时挂载。
- 想叠加更多视觉效果（模糊粒度、描边、高光），在 `AxsGlassifyGlass.m` 中扩展 tint 层即可。
- 新增配置项时，在 `AxsGlassifyRoot.plist` 声明默认值，并在消费端给出一致的缺键回退。

## 说明

本工程是独立原创实现，与任何第三方付费插件无代码或逆向关系。
静态检查（`doctor.py`）只覆盖结构与命名/引用一致性，不代表 Theos 编译或真机效果验证。
