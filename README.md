# 液态玻璃（Glassify）

一个 iOS 越狱插件，6.0.0 起合并了原 `Notification-Beautification`（液态通知），6.7.0 起再合并原 `SBezierNoti`（S 形贝塞尔通知）：

- **玻璃部分**：把系统里本来就有毛玻璃的界面（控制中心、通知中心、文件夹、Dock、App 切换器…）重绘成更明显的"液态玻璃"。
- **通知部分**：锁屏 / 通知中心的通知卡片换成自带玻璃底板 + 流动渐变 + 游鱼 / 泡泡 / 粒子 + 出现动画 + 尺寸圆角光影。
- **S 形贝塞尔部分**：通知滚动进入视野时的 S 滑动等 12 种入场特效，以及横幅弹出时的 S 形入场 + 装饰曲线。

> 注意：玻璃部分**不会**给整个桌面盖一层模糊。桌面/图标本身没有毛玻璃层，所以保持清晰；
> 只有系统原本就带模糊的控件会被增强。

## 功能

### 玻璃

- **启用/关闭**：开关控制是否增强系统毛玻璃；关闭时恢复系统原有材质。
- **玻璃强度**：0.0–1.0，映射到系统材质 UltraThin → Thick。
- **强制深色玻璃**：关闭时用自适应材质（跟随系统深浅色）；打开后强制深色。
- **液态玻璃通知**：给通知卡片换成本插件自己的玻璃底板（顶部柔光 + 左右边缘色散 + 45° 镜面描边）。
- **动态高光**：45° 镜面描边的亮边跟随设备倾斜移动（10 Hz 陀螺仪采样，只在有高光层时开启）。
- **文件夹 / Dock / 通知中心**：这些界面本来就有模糊，叠同一套顶柔光 + 边缘色散 + 镜面描边（只改图层，不动视图层级）。

> 控制中心不处理。试过 hook `CCUIContentModuleBackgroundView` 换模块材质，但模块尺寸/圆角差异太大、
> 无法在无真机的情况下保证不破相，已在 6.3.1 移除。

### 通知美化

- **通知大小 / 宽度 / 圆角 / 透明度 / 投影 / 3D 倾斜**。
- **流动渐变背景**：双色相 + 速度 + 透明度；可跟随应用图标或壁纸取色。
- **鱼缸游鱼**：数量 / 大小 / 自定义 PNG（多张用 `;` 分隔）/ 吐泡泡。
- **粒子特效**：图片导入、密度、大小、方向（下落 / 上飘 / 横飘）。
- **出现动画**：果冻弹跳 / 除雾渐显 / 挤压拉伸 / 凝胶膨胀；到达粒子爆发、划走溶解。
- **S 曲线滑动**：拖动通知时整张卡片沿 S 形轨迹横向摆动——先摆向一侧、过中线再摆向另一侧，起手和拖到底都回到中线；摆动时带一点朝运动方向的倾转（60pt ≈ 4°），松手带轻微弹簧过冲回正。幅度 0–60pt 可调（默认 0 = 关），拖满一张卡的高度走完整条 S；上滑 / 下滑镜像对称，位移叠加在缩放 / 3D 倾斜之上。
- **触摸发光**：按下时高光脉冲 + 微挤压，跟手渐变；可叠加轻段震动反馈。
- **文字与图标**：标题颜色/发光、图标圆角/大小/光晕。
- **情境**：充电蝴蝶（亮晶晶、大小可调、会扇翅膀飘起）、低电量自动降载、按时段自动切换预设、自定义预设保存/应用。
- 设置保存后实时生效，无需重启 SpringBoard。

### S 形贝塞尔入场（6.7.0 合并自 SBezierNoti）

1. **滚动入场特效**（主力）—— 锁屏与通知中心里，每条通知滚动进入视野时沿自己的 S 轨迹滑入落位。机制照搬 [Cask](https://github.com/rpetrich/Cask)：在单元格被创建来显示的那一刻播**一次**动画，**不是每帧计算偏移**。面板「特效类型」共 13 档（0 关闭、1 淡入、2 缩放、3 横向展开、4 侧滑、5 上浮、6 翻转、7 S 滑动、8–12 各种带透视的旋转/翻转组合）。
2. **横幅 S 形入场轨迹**（`sbz_entrance_enabled`）—— 横幅弹出时沿 S 轨迹滑入落位。只驱动 `transform`，落位即归零，停留时无残留。
3. **S 形装饰曲线**（`sbz_decoration_enabled` + `sbz_decoration_style`）—— 横幅下缘画出的一条 S 波形线（`strokeEnd` 生长出来）。这是**静态的线**，和上面那条运动轨迹几何上不是一回事：轨迹是 x(时间)、线是 y(横向位置)，只是都像 S。`sbz_decoration_style` 决定线进场后「常驻停留」(0，画满停住，原插件的签名观感) 还是「淡出消失」(1，画满后收回)。

**S 形蜿蜒排列（新增功能，和上面三个都不是一回事）**

前三个效果都是"进场那一刻播完就归零"；这个不是动画，是**排版形变**：通知列的"中心线"本身就是一条蜿蜒的 S——静止定格时屏幕上的通知就是 S 形排列，滚动时整列像沿滑道流动。**任何一张卡都不回正**：摆到拐弯（波峰/波谷）的卡片缩到最小，穿越中线的卡片同样保持缩小（0.35·shrink 的"穿越态"）——整屏任何时候看都是一条连续的蛇形，不会有一排全尺寸居中的"正常卡片"。三个参数（摆幅/波长/拐处缩小）独立可调，开关 `sbz_serp_enabled`。

实现要点（v8；前三版在这里连续踩坑，逐条记录，别再走回头路）：

- **v6 的教训：不要跟系统抢 `layer.transform`。** 位移写成 model transform，真机结果是"静止仍整齐 + 卡片持续闪现"：锁屏给每张卡片挂着 transform 动画，Core Animation 的呈现值优先于 model，我们写的值上不了屏；清掉系统动画后又会在下一次布局被写回并重挂，每拍最多两次可见跳变 = 闪烁。
- **v7 的教训：事后覆盖也慢一步。** 改在列表 `layoutSubviews` 的 `%orig` 之后写 cell.frame —— 不闪了，但摆幅/缩小拉满仍纹丝不动（真机录屏确认）。因为摆卡片的不是列表自己，是外层容器（锁屏封面/RootLockPage），它在我们之后还会再写一次 frame。任何"事后覆盖"都要跟一个看不见的写者赛跑。
- **v8 = 接管写入点，不再事后。** hook 卡片自己的 `-setFrame:` 与 `-setCenter:`（`NCNotificationListCell`，诊断已确认它就是锁屏卡片类）。无论哪个布局发起者，最终都必须经过这两个咽喉 —— 系统在这里交出坐标，我们就地把它们按 y 相位弯成 S 再转交真实 setter。**写者只有一个**（弯折后的值就是系统要写的值），所以没有竞态、没有覆盖、没有闪烁。三条铁律保证不死循环（旧版卡死设备的教训）：
  1. **写入闸**：我们写 frame/center 会同步重入同一个 hook，用 `__thread` 标志挡住，重入时原样放行，绝不二次弯折。
  2. **基准只取系统交进来的那个值**（参数 `in`），绝不从 `cell.frame` 回推 —— 回推会把弯折值当基准，偏移叠进偏移。
  3. **反馈检测**：若系统下一次交进来的值 == 我们上次写出去的值，说明它把我们的输出当成了输入（回环），该卡片永久跳过弯折，诊断报 `fbk=`/`nobend=`。
- **`setFrame:` 与 `setCenter:` 都接管，计数分开**（`bentF`/`bentC`）：横向摆位分别走各自的属性；缩小统一走 `layer.transform` 均匀缩放（见下条 v12），所以两条路都有完整观感。弯折是纯函数：同一个输入永远同一个输出，系统重复摆位不会让画面变化。
- **v11/v12 的教训：缩小只能用 transform。** v10 只在 `setFrame:` 路径做了尺寸缩小，而锁屏摆卡片走的是 `setCenter:` —— 缩小从未生效（用户反馈"拐弯处没变化"）。v11 改用 `bounds` 补上，真机仍然无效：改 `bounds` 只缩外框，卡片内容（内部的 ShortLook 视图）不跟随重排，画面上看不出任何变化。v12 最终用 `layer.transform` 缩放 —— 它缩放整个渲染子树，不需要卡片配合。**安全前提**：写缩放前先检查该 layer 是否挂着"常驻不删"的 transform 动画（`removedOnCompletion == NO`），有则跳过缩放只保留摆位并计入 `skipA=` —— 这正是 v6 闪烁的成因，这次不抢也不删，只避让。缩放基准同样只记一次（首次缩放前的 model transform，可能已含玻璃的缩放/倾斜），每趟从基准重乘 `sc`，永不叠乘。恢复时**先撤缩放再比 frame**：transform 存在时 `cell.frame` 返回的是视觉矩形，顺序反了位移就恢复不掉。被缩放的卡片期间玻璃引擎的每帧 transform 写手让位（围栏 `axs_glassify_sbez_viewSerpScaled`），单一所有权。
- **减弱动态效果是 static 镜像**（`UIAccessibilityIsReduceMotionEnabled()` 是系统调用，绝不能放进每帧几十次的 `setFrame:`），与门控一起在低频点刷新；列表进窗口（每次解锁/拉通知中心）也刷新一次 —— 没有公开的"辅助功能变更"通知，这是最便宜且总在"用户下一次看锁屏"之前的时机。
- **边缘钳制（v9 打磨，真机截图反馈）**：滑条只管"想摆多远"，代码负责"最多能摆多远" —— 弯后的中心夹在 `[边距+w/2, 容器宽-边距-w/2]`，摆幅拉满也只是贴边，卡片永远不出屏。容器宽优先取 superview，退化到屏宽。
- **默认值调向"蛇"而不是"锯齿"（v9）**：波长 260→520、摆幅 28→34、缩小 0.18→0.15。卡片高约 90pt 时，260 的波长让相邻卡片相位差 ≈113°（左右对跳=锯齿）；520 让一张完整波长覆盖约 5~6 张卡片，才是连续的蛇。波长滑条范围同步改为 120–900。
- **关闭零开销**：`setFrame:` 里第一步是两个 static BOOL 读，关着时立即原样放行。列表侧的 `setContentOffset:` 信号现在只服务"关/减弱动态"一侧的恢复自愈。
- **现场可读**：面板「S 形贝塞尔诊断」的 `蜿蜒排版：on=… reduce=… lists=… cells=… inwin=… bentF=… bentC=… fbk=… nobend=… sample=(dx=… dy=… k=…)`。判读：`bentF`/`bentC` 都为 0 ⇒ 系统根本没走这两个 setter，要换接管点；`sample` 的 `dx≠0` 而肉眼仍是直线 ⇒ 外层又改写了一次，需要连外层一起接管；`nobend>0` ⇒ 反馈回环被检测到并已保护。

滚动入场特效与蜿蜒**可共存**：入场动画是挂在 layer 上的 CAAnimation（播完自动移除），蜿蜒写的是 model transform 的缩放 + frame 的横向摆位。CAAnimation 播放期间其呈现值优先，播完落回 model —— 而入场动画的关键帧正是**以当时的 model transform 为基准**生成的（见 `effectAnimation` 的 base 参数），所以卡片一边播入场动画一边已经站在自己的 S 位上，动画结束落点精确，不会把缩放拍回原尺寸。系统若给卡片挂着**常驻不删**的 transform 动画，蜿蜒会跳过缩放只保留摆位（`skipA=`），避免 v6 式对撞。

三者各自独立开关，都受总开关 `enabled` 控制。横幅侧的轨迹与装饰线在 6.7.0 拆分前共用一个 `entranceEnabled`，旧值迁移时同时点亮两者、并把样式钉成「常驻」，完全复刻升级前观感。列表识别、一次性动画、`tableView.window` 守卫、「减弱动态效果」尊重、诊断自报告（面板「S 形贝塞尔诊断」分组直接显示真实类名，不用开系统日志）等行为与原插件一致；调试日志的标签变为 `[Glassify-SBez]`。

**合并后的两处仲裁**（这是两个项目功能真正重叠的地方）：

| 冲突 | 处理 |
|---|---|
| 横幅 S 入场**轨迹**（整条 `transform`） vs 出现动画 `appear_mode`（`transform.scale`） | **互斥，轨迹优先**。`sbz_entrance_enabled` 打开时，`AxsGlassifyNotifyAnimator` 的 attach 路径把 appear_mode 视作 0，不再挂 scale 动画。**装饰线不参与这条仲裁** —— 它只动 `strokeEnd`，不碰 transform，可与任意出现动画共存。 |
| 入场 / 特效动画落位 vs 玻璃的 `notify_scale` / `tilt` model transform | 所有入场档位改成**以 layer 当前 transform 为基准**起落（终点 = 基准值），动画移除时不再从缩放态跳回原尺寸；淡入同理落到 `layer.opacity`。 |

`NCNotificationShortLookView` / `NCNotificationLongLookView` 在合并前是两个 dylib 各自 `%hook` 同一批方法；现在只剩 `Hooks/AxsGlassifyNotifications.xm` 一处 hook，玻璃底板、动画引擎和 S 入场在同一次 `layoutSubviews` 里按序驱动。`SBUICNotificationView`（旧系统横幅）仍只在 S 贝塞尔的 hook 组里。

## 合并后的结构

一个 dylib、一个偏好域（`com.axs.glassify`）、一套 hook：

| 文件 | 职责 |
|---|---|
| `Hooks/AxsGlassifyMain.xm` | 系统毛玻璃（`_UIBackdropViewSettings` / `UIVisualEffectView`） |
| `Hooks/AxsGlassifyNotifications.xm` | 通知卡片：**一个** hook 点同时驱动下面三个引擎（含合并后的 S 入场入口） |
| `Hooks/AxsGlassifySBezier.xm` | 旧系统横幅 `SBUICNotificationView` + 列表滚动入场 hook 组（`UIScrollView` / cell / `UITableView` 私有触发） |
| `Sources/AxsGlassifyLiquid.*` | 玻璃底板：iOS 26+ 用 `UIGlassEffect`，低版本回退 chrome 材质 + 高光/色散 |
| `Sources/AxsGlassifyNotifyAnimator.*` | 渐变 / 游鱼 / 粒子 / 出现动画 / 缩放倾斜 / 溶解 |
| `Sources/AxsGlassifyNotifyConfig.*` | 通知部分 + S 贝塞尔部分的配置访问器（同一份快照，含互斥仲裁谓词） |
| `Sources/AxsGlassifySBezierCurve.h` | S 波几何、配色、入场 / cell 特效动画构造（仅 `static inline`，无 ObjC 类） |
| `Sources/AxsGlassifySBezierListEntrance.m` | 列表识别 + cell 出现时的一次性入场（Cask 机制） |
| `Sources/AxsGlassifySBezierDecoration.m` | 横幅 S 入场：装饰层、观察配置、播放 |
| `Sources/AxsGlassifySBezierDiagnostics.h` | 滚动入场的自报告（面板「S 形贝塞尔诊断」读取） |

合并时收敛掉的冲突：

- **圆角只有一个来源**：`corner_radius` 现在同时决定玻璃底板和渐变层的圆角，不会再出现两层半径不一致。
- **不重复找背景层**：动画引擎找卡片材质层时跳过玻璃底板，避免把刚插进去的玻璃当成系统材质再圆一次。
- **设置项立即生效**：面板保存走 `axs_glassify_writePreference`，会广播变更通知；合并前 Glassify 的面板直接走
  Preferences 默认写入，不广播，改完要等下次重建视图才看得到。
- **旧配置自动迁移**：首次打开面板时把 `com.axs.notifyliquid.plist` 里的键搬到新域（`migrated_notifyliquid` 标记，只做一次）。
- **包冲突**：`conflicts/replaces/provides: com.axs.notifyliquid`，安装时自动顶掉旧的「液态通知」，不会两个 dylib 同时 hook 同一批类。

SBezierNoti 并入时额外收敛的冲突（6.7.0）：

- **一个类只有一个 `%hook` 块**：`NCNotificationShortLookView` / `NCNotificationLongLookView` 原来被两个 dylib 各自 hook
  `layoutSubviews` / `didMoveToWindow`，加载顺序决定谁赢。现在这两个类只在 `AxsGlassifyNotifications.xm` 里 hook 一次，
  S 入场通过 `UIView (AxsGlassifySBezier)` 分类方法被同一次布局调用；`SBUICNotificationView` 不在玻璃侧出现，仍单独成组。
- **横幅入场 vs 出现动画互斥**：S 入场**轨迹**驱动整条 `transform`，`appear_mode` 驱动 `transform.scale`，同层并存会互相顶掉。
  仲裁只看一个谓词 `axs_glassify_notify_sbezEntranceActive`：轨迹开 → 出现动画不挂；轨迹关 → 出现动画照旧。
- **轨迹与装饰线拆成两个独立开关**：原插件一个 `entranceEnabled` 同时管「滑入轨迹」和「下缘常驻的 S 线」，两者常被当成
  一回事（其实一个是 x(时间)、一个是 y(横向位置)，只是都像 S）。6.7.0 拆为 `sbz_entrance_enabled` + `sbz_decoration_enabled`，
  装饰线另有 `sbz_decoration_style`（常驻/淡出）。线改画 `strokeEnd` 关键帧且与 transform 解耦，任何出现动画都能和线共存。
- **入场终点改为基准 transform**：玻璃的 `notify_scale` / `tilt_intensity` 是写在 model transform 上的，原插件所有档位把
  终点写成 identity，动画一移除缩放就没了。现在起点/终点都以 `layer.transform` 为基准（淡入以 `layer.opacity` 为基准）。
- **配置键统一 `sbz_` 前缀**：旧域的 `duration` / `amplitude` / `width` / `opacity` / `hue` 这类裸名并入同一个 plist 后必撞名，
  现在分别是 `sbz_duration`…，滚动档位在 `sbz_scroll_effect`。旧值由面板首次打开时按固定映射表搬一次（`migrated_sbeziernoti`），
  新域已有的值优先，不会被旧值覆盖。
- **旧 `enabled` 故意不迁移**：合并后 `enabled` 是**全插件总开关**，打开会连带增强系统毛玻璃（进程级 `_UIBackdropViewSettings` hook）。
  只用过 S形贝塞尔通知 的用户升级后被静默开启玻璃等于"改了没要求改的东西"，所以只搬特效参数，总开关留给用户自己开；
  同时 `sbz_scroll_effect` 的缺省从旧插件的 7（S 滑动）改为 0（关闭），保证升级后默认惰性。
- **热 hook 门控**：`UIView didMoveToSuperview` 与 `UIScrollView didMoveToWindow` 是全进程级别的热点。诊断记录仍然保留
  （识别独立于开关，错判才能被发现），但「刚出现」标记的关联对象写入与 async 派发只在 `sbz_scroll_effect > 0` 且总开关打开时执行。
- **包冲突**：`Conflicts/Replaces` 增加 `com.axs.sbeziernoti`，装 Glassify 会顶掉旧的 S形贝塞尔通知；`Provides` 不含它，
  所以两个插件同时依赖 `com.axs.sbeziernoti` 的旧配方不会因此得到满足，需要用户自己确认。
- **旧键遗留**：`scrollEnabled` / `scrollRotation` 在原插件 5.2.0-13 起已不再读取，这次也不迁移（留着不影响）。

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
- `AxsGlassifyPrefs/`：合并后的唯一设置面板（64 个 cell），是配置文件的唯一写入方。

## 性能

锁屏 / 通知中心是高频重绘场景，6.4.0 专门砍了几处热点：

- **装饰几何记忆**：`-layoutSubviews` 在滚动时会对每个背景反复触发，之前每次都要重建
  镜面描边 + 顶柔光 + 边缘色散三条圆角 `CGPath`。现在按（尺寸, 圆角）记忆，没变直接返回。
- **显示链接按需启动**：只有渐变 / 游鱼 / 粒子 / 充电蝴蝶需要逐帧驱动，全关时 `CADisplayLink`
  直接停表（之前只要有通知在屏幕上就会 30fps 空转）。
- **transform 只在不同时写**：缩放/倾斜原来每帧无条件写一次 `layer.transform`，现在先比较再写；
  系统布局改写后会在 `-layoutSubviews` 里补一次，所以停表也不会导致“通知大小失效”。
- **电池 / 低电量查询降到 1Hz**：`batteryState` 要走 IOKit，原来每帧查一次。
- **热路径去 NSString**：类名判断改用 `class_getName` + `strstr`，每次布局少建几个 NSString。
- 鱼 / 爆发 sprite 全进程只渲染一次（6.2.0）。

6.4.1 针对“发热 / 掉电快”又加固了一轮：

- **动态高光默认关闭**。这项要常驻姿态采样，代价比纯静态装饰高得多；需要时在「玻璃外观」里自己打开。
- **姿态没变就不写图层**。之前是 10Hz 无条件写 `startPoint/endPoint`，而 CA 不做值比较——
  赋同样的值也会重新提交、重绘，手机静止放桌上也一直在烧 GPU。现在变化小于 0.004 直接跳过。
- **装饰层不再用 `CAShapeLayer` 遮罩**。带 mask 的图层会强制离屏合成，而顶柔光/边缘色散铺在每个背景上；
  改用渐变层自己的 `cornerRadius + masksToBounds`，省掉一层离屏 pass。
- **电池监听按需开启**。之前 `batteryMonitoringEnabled = YES` 常开；现在只在「充电特效」打开时才开。
- **只有渐变时降到 15fps**（颜色本来就只有 10Hz 级变化），有鱼/粒子/蝴蝶才回到 30fps。

6.5.3 把轨迹改成真正的 S：

- 横向偏移原来是 `3u²-2u³`，在 0→1 上单调递增，卡片只会朝一侧偏，形似 C 而不是 S。
- 现在用 `sin(πu)·sin(2πu)` 归一化：起手居中 → 约 30% 处摆到 +幅度 → 一半处过中线
  → 约 70% 处摆到 −幅度 → 拖到底回正，上下拖动镜像对称，轨迹是一条完整的 S。
- 两端按 u² 起势，手势刚识别时不会横向跳。

6.5.2 修了「S 曲线看不见」的问题：

- 拖动改由挂在卡片上的 `UIPanGestureRecognizer` 驱动。通知列表是 `UIScrollView`，
  它一滚动就会给卡片发 `touchesCancelled`，原来靠 `-touchesMoved:` 只能拿到开头十几点位移。
- 位移改成「相对手指起点的增量」，不再用触点相对卡片中心的位置（原来按下瞬间就会跳一下）。
- 满幅距离按卡片高度归一（约 0.9 倍卡高，最少 70pt），拖出一张卡的距离就到最大摆幅。
- 拖动期间强制显示链接保持运行，系统布局改写 `transform` 时逐帧把 S 位移补回去。

6.5.1 全量审查后又收了一轮分配与热路径：

- **效果层按需创建**。以前每张通知都会建 8 个鱼层 + 爆发 / 粒子两个发射器，哪怕开关全关着；
  现在默认配置下只留渐变层，鱼 / 爆发 / 粒子在第一次打开时现建。自定义鱼图也从
  「每张卡读一次盘」改成按路径缓存。
- **图标取色按需采样**。只有「跟随应用图标」才画那张 16×16 平均色位图。
- **布局重刷用配置代次判断**。`-layoutSubviews` 原先每次都要读 11 个配置键拼样式签名，
  现在只在「配置变过 / 卡片尺寸变过 / 父视图宽度变过」时才整段重刷。
- **设置面板一次解析**。面板每行 specifier 都要读配置，打开时会解析 plist 六十多次；
  改为按文件 mtime 缓存。
- **热路径去 NSString**：找通知背景层改用 `class_getName` + `strstr`。
- 顺手加固：玻璃底板与卡片状态共用同一个关联键，取值现在按类型判断，
  不会把 `@YES` 标记当成状态对象解引用。

## 观感细节

- **拖动反馈**：卡片横向位移时带同向倾转（像被“甩”出去），同时卡片左右边缘的色散光
  随摆幅变亮（平时完全不可见，不污染静止画面），松手淡出。
- **回位**：阻尼弹簧，回到中线时约 6% 的过冲再归零。
- **玻璃底板入场**：第一次装上时从 0.97 轻微放大并淡入，不再硬切。
- **深色内阴影**：强制深色或系统深色时，玻璃上缘压一道暗边，卡片看起来有厚度。
- **图标光晕跟主色**：开了「图标光晕」会采样应用图标主色，光晕不再一律发白。
- **快捷方案**：面板里可用「一键省电」/「一键炫酷」整套切换配置。

## 设置面板

「关于我们」只保留一行署名：**搞机群友三叶草**。

「快捷方案」分组里有两个按钮：「一键省电」只保留玻璃本体（关掉渐变 / 游鱼 / 粒子 / 爆发 / 溶解 / 触摸发光 / 动态高光）；「一键炫酷」打开渐变、游鱼、到达爆发、溶解、触摸发光、S 曲线 35pt、圆角 22、轻倾斜与图标光晕，都取中间值。

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
