# 液态玻璃（Glassify）

一个 iOS 越狱插件，6.0.0 起合并了原 `Notification-Beautification`（液态通知）：

- **玻璃部分**：把系统里本来就有毛玻璃的界面（控制中心、通知中心、文件夹、Dock、App 切换器…）重绘成更明显的"液态玻璃"。
- **通知部分**：锁屏 / 通知中心的通知卡片换成自带玻璃底板 + 流动渐变 + 游鱼 / 泡泡 / 粒子 + 出现动画 + 尺寸圆角光影。

> 注意：玻璃部分**不会**给整个桌面盖一层模糊。桌面/图标本身没有毛玻璃层，所以保持清晰；
> 只有系统原本就带模糊的控件会被增强。

## 功能

### 玻璃

- **启用/关闭**：开关控制是否增强系统毛玻璃；关闭时恢复系统原有材质。
- **玻璃强度**：0.0–1.0，映射到系统材质 UltraThin → Thick。
- **强制深色玻璃**：关闭时用自适应材质（跟随系统深浅色）；打开后强制深色。
- **液态玻璃通知**：给通知卡片换成本插件自己的玻璃底板（顶部柔光 + 左右边缘色散 + 45° 镜面描边）。
- **动态高光**：45° 镜面描边的亮边跟随设备倾斜移动（10 Hz 陀螺仪采样，只在有高光层时开启）。

### 通知美化

- **通知大小 / 宽度 / 圆角 / 透明度 / 投影 / 3D 倾斜**。
- **流动渐变背景**：双色相 + 速度 + 透明度；可跟随应用图标或壁纸取色。
- **鱼缸游鱼**：数量 / 大小 / 自定义 PNG（多张用 `;` 分隔）/ 吐泡泡。
- **粒子特效**：图片导入、密度、大小、方向（下落 / 上飘 / 横飘）。
- **出现动画**：果冻弹跳 / 除雾渐显 / 挤压拉伸 / 凝胶膨胀；到达粒子爆发、划走溶解。
- **触摸发光**：按下时高光脉冲 + 微挤压，跟手渐变；可叠加轻段震动反馈。
- **文字与图标**：标题颜色/发光、图标圆角/大小/光晕。
- **情境**：充电火花、低电量自动降载、按时段自动切换预设、自定义预设保存/应用。
- 设置保存后实时生效，无需重启 SpringBoard。

## 合并后的结构

一个 dylib、一个偏好域（`com.axs.glassify`）、一套 hook：

| 文件 | 职责 |
|---|---|
| `Hooks/AxsGlassifyMain.xm` | 系统毛玻璃（`_UIBackdropViewSettings` / `UIVisualEffectView`） |
| `Hooks/AxsGlassifyNotifications.xm` | 通知卡片：**一个** hook 点同时驱动下面两个引擎 |
| `Sources/AxsGlassifyLiquid.*` | 玻璃底板：iOS 26+ 用 `UIGlassEffect`，低版本回退 chrome 材质 + 高光/色散 |
| `Sources/AxsGlassifyNotifyAnimator.*` | 渐变 / 游鱼 / 粒子 / 出现动画 / 缩放倾斜 / 溶解 |
| `Sources/AxsGlassifyNotifyConfig.*` | 通知部分的配置访问器（同一份快照） |

合并时收敛掉的冲突：

- **圆角只有一个来源**：`corner_radius` 现在同时决定玻璃底板和渐变层的圆角，不会再出现两层半径不一致。
- **不重复找背景层**：动画引擎找卡片材质层时跳过玻璃底板，避免把刚插进去的玻璃当成系统材质再圆一次。
- **设置项立即生效**：面板保存走 `axs_glassify_writePreference`，会广播变更通知；合并前 Glassify 的面板直接走
  Preferences 默认写入，不广播，改完要等下次重建视图才看得到。
- **旧配置自动迁移**：首次打开面板时把 `com.axs.notifyliquid.plist` 里的键搬到新域（`migrated_notifyliquid` 标记，只做一次）。
- **包冲突**：`conflicts/replaces/provides: com.axs.notifyliquid`，安装时自动顶掉旧的「液态通知」，不会两个 dylib 同时 hook 同一批类。

## 通知玻璃的实现

`Hooks/AxsGlassifyNotifications.xm` 挂 `NCNotificationShortLookView`（快捷看板）、`NCNotificationLongLookView`（展开态）、
`NCNotificationListCell`（iOS 16+ 兜底，仅在内部没有 ShortLook 时生效，避免叠两层玻璃）。类不存在时该 hook 组不安装。

每张卡片上做三件事：

1. 找到卡片自带的底材（MaterialKit 的 `MTMaterialView`，旧系统是 `_UIBackdropView`）并临时隐藏。只认几乎铺满整张卡片、
   且原本完全可见的那个，避免把按钮之类的小底材一起藏掉；关闭开关时逐个还原；
2. 在 index 0 插入一个 `UIVisualEffectView` 作为卡片底板，圆角跟随 `corner_radius`（未设置时用原卡片圆角，兜底 22pt）；
3. 在底板上叠加装饰层：顶部 55% 的白色柔光、左右 5% 的边缘色散、以及 `AxsGlassifyGlass` 统一加的 45° 镜面描边。

流动渐变层挂在玻璃底板的 `contentView` 上——在模糊之上、文字之下，也因此自动被玻璃圆角裁切；
玻璃开关关掉时退回卡片的材质层，位置同样在文字之下。

材质分两条路径：

- **iOS 26+**：直接使用系统的 `UIGlassEffect`（`+effectWithStyle:`，`regular` 样式），这就是 Apple 自己的 Liquid Glass，
  带真实的透镜折射与高光。因为构建用的 16.5 SDK 里没有这个类，全部通过 `NSClassFromString` + `objc_msgSend` 动态调用，
  其它系统版本上自动跳过。
- **iOS 15–18**：UIKit 不向第三方开放背景纹理，拿不到真实折射，退回 `UIBlurEffectStyleSystemChromeMaterial`
  （系统给 platter 用的那档材质）再叠加上述高光/色散近似。

## 其他实现要点

- `Hooks/AxsGlassifyMain.xm`：
  - 钩住私有 `_UIBackdropViewSettings -setDefaultValues`，直接调 `blurRadius` / `saturationDeltaFactor` /
    `grayscaleTint*` —— **控制中心、通知中心、文件夹、Dock 背景实际由 `_UIBackdropView` 渲染，靠这里才生效**。
    所有私有 setter 都用 `-respondsToSelector:` 保护，不同 iOS 版本缺方法时自动跳过。
    同时在 `setBlurRadius:` / `setSaturationDeltaFactor:` 里做强制下限，避免 iOS 17 在默认值之后又写回原值。
  - 钩 `_UIBackdropView -layoutSubviews`，在圆角足够大的 backdrop 上叠加 45° 白色边缘高光，对应参考库里的 specular highlight。
  - 同时钩 `UIVisualEffectView -initWithEffect:`，覆盖使用公开毛玻璃的界面。
- `Sources/AxsGlassifyGlass.{h,m}`：把 `UIBlurEffect` 重映射为目标强度/深浅的材质；用关联对象记住原始 effect，
  关闭时精确还原；`axs_glassify_refreshAllWindows` 在设置变更时遍历窗口树实时更新/还原。
- `Sources/AxsGlassifyConfig.*`：配置快照；只读，不在 `%ctor` 里写默认值。
- `AxsGlassifyPrefs/`：合并后的唯一设置面板（61 个 cell），是配置文件的唯一写入方。

## 构建

需要可用的 Theos 工具链与约定的 SDK（16.5），最低 iOS 15。

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
- 新增配置项时，在 `AxsGlassifyRoot.plist` 声明默认值，并在消费端给出一致的缺键回退；
  如果它属于通知预设的一部分，同时加进 `axs_glassify_presetKeys()`（面板）与 `axs_glassify_notify_presetKeys()`（时段切换）。

## 说明

视觉参数参考了 Kyant0/AndroidLiquidGlass（Apache-2.0）与 zzsj0928/luci-theme-liquid 的玻璃 token：
模糊 26、饱和 1.6、白色 tint 0.42、白色描边 0.8、内高光 0.95。
代码是独立用 UIKit/CoreAnimation 实现的，未拷贝其 Kotlin/AGSL 或 CSS 代码。
真正的折射/透镜（lens）与色散依赖 GPU shader 实时采样背景。iOS 26 起系统通过 `UIGlassEffect` 提供了这层能力，
本插件在 26+ 上直接复用它；iOS 15–18 上 SpringBoard 的私有 backdrop 不开放背景纹理，无法做真实折射，
只能做到模糊 + 饱和度 + 色调 + 边缘高光/色散的近似。
`_UIBackdropView` 是私有 API，不同 iOS 版本的方法集合会变化，代码已做 `-respondsToSelector:` 保护；
若某个界面仍无变化，说明该界面走了别的渲染路径，需要按设备版本再定位对应类。
静态检查与 CI 编译通过不代表真机视觉验收。
