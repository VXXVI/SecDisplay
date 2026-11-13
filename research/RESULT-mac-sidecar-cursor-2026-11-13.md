# Mac 侧诊断：Sidecar 镜像后 iPad 光标放大

> 日期：2026-11-13
> 范围：只读诊断。未改任何源码，未提交。
> 结论口径：区分「实测」与「推断」，推断处明确标注。

## 一、结论

iPad 上那个「一动就放大」的光标是 **macOS 自己的系统光标**，由 WindowServer 在镜像集里合成后经 AirPlay 送到 iPad。它和 SecDisplay 的 0x05 位图没有任何关系（0x05 只走 TCP 到 Windows 接收端）。

放大的根因是**同一个镜像集里混了两种 backing scale**：SecDisplay 虚拟屏是 `Scale=1`（1600x1000 逻辑点 = 1600x1000 像素），Sidecar 是 `Scale=2`（1149x802 点 = 2298x1604 像素）。镜像集只能有一份帧缓冲，光标位图按 2x 选取、却按 1x 的坐标空间落位，移动时切到合成路径就跳成 2x 大小。

系统辅助功能的光标放大与晃动定位**都没有开启**，已用 defaults 排除。

风险等级：中。影响可用性，不损坏数据。修法是「不让虚拟屏进镜像集」，不改系统光标设置。

## 二、判定：iPad 上显示的是哪种光标

### 2.1 代码路径：0x05 位图只有一条出口，且不经过任何屏幕

- 采集配置 `c.showsCursor = false`（`prototype/mac/Sources/main.swift:791`）。送进编码器的视频帧里**本来就不含光标**，Windows 端看到的指针完全由本地绘制。
- 光标位图由 `CursorImageTracker`（`main.swift:1529-1624`）产生，出口只有 `sender.sendCursorImage(...)`（`main.swift:1621`），最终落到 `c.send(content: packet, ...)`（`main.swift:1233`），其中 `c` 是 `conn: NWConnection`（`main.swift:925`），也就是连进来的 Windows 接收端（`main.swift:1786` `sender.listen(port:)`）。
- 全仓 `prototype/mac/Sources/` 里没有任何 `NSCursor.set`、`CGDisplayHideCursor`、`CGDisplayShowCursor`、`CGWarpMouseCursor`，也没有把位图画进虚拟屏内容的窗口。虚拟屏上不存在「我们画的光标」。

结论：0x05 位图的消费端只有 Windows。iPad 那条链路（WindowServer → AirPlay → iPad）里没有任何一行我们的代码。

### 2.2 现象特征也支持系统光标

| 特征 | 0x05 位图 | 系统光标 | 用户现象 |
|---|---|---|---|
| 尺寸行为 | 位图固定 28x40 像素，只在形状变化时重发（`main.swift:1611` 指纹判重 + `main.swift:1613` 0.25s 限流） | 随所在屏的 scale 选 1x/2x 位图 | 静止正常，一动就跳大 |
| 触发时机 | 只能由形状变化触发 | 随光标移动、跨屏、镜像合成路径切换 | 跟「动」强相关 |
| 形状 | 只能是我们主动采到的系统形状 | 与前台应用完全一致 | 与系统一致 |

0x05 路径从机制上做不出「一动就放大」：它没有位移驱动的尺寸变化，只有形状指纹变化。这条可以确定排除。

## 三、实测数据

### 3.1 NSScreen / CGDisplayMode（本机实测，2026-11-13 12:5x）

测量时 SecDisplay 虚拟屏**不在线**（进程未运行），所以第三行取自 WindowServer 持久化的显示配置 `/Library/Preferences/com.apple.windowserver.displays.plist`（mtime 2026-11-13 12:39），那份记录正好是用户描述的三屏布局。

| 屏 | displayID | NSScreen frame（AppKit 坐标，左下原点） | backingScaleFactor | CGDisplayMode w×h | pixelWidth×pixelHeight | plist Scale | Depth | Hz | vendor / model |
|---|---|---|---|---|---|---|---|---|---|
| 内建 Color LCD | 1 | (0,0) 1512×982 | **2.0** | 1512×982 | 3024×1964 | 2 | 8 | 120 | 0x610 / 0xa04f |
| Sidecar (AirPlay) | 29 | (-1149,180) 1149×802 | **2.0** | 1149×802 | 2298×1604 | 2 | 4 | 60 | 0x6161706c / 0x69506164 |
| SecDisplay 虚拟屏 | 未在线 | (1512,0) 1600×1000 | **1.0**（推定） | 1600×1000 | 1600×1000 | 1 | 4 | 60 / 90 | 0xEEEE / 0x5344 |

补充事实：

- `CGDisplayBounds(29) = (-1149,0,1149,802)`，`CGDisplayMirrorsDisplay(29) = 0`，当前 Sidecar 未镜像。`CGDisplayMirrorsDisplay(1) = 0`。
- NSScreen.frame 与 CGDisplayBounds 的 y 不同（180 与 0），因为前者是 AppKit 左下原点、后者是 CG 左上原点，混用会算错坐标，别拿两者互相校验。
- `system_profiler SPDisplaysDataType` 独立印证 Sidecar：`Resolution: 2298 x 1604`，`UI Looks like: 1149 x 802 @ 60.00Hz`，即 2x。

### 3.2 虚拟屏是 1x 还是 2x：判定为 1x

三条独立证据：

1. plist 里这块屏（`OriginX=1512, Wide=1600, High=1000`）的 `Scale => 1`，同一份配置里内建与 Sidecar 都是 `Scale => 2`。这是 WindowServer 自己的记录，比任何 API 推断都硬。
2. 创建代码的 hiDPI 判据：`settings.setValue(cfg.logicalWidth * 2 <= cfg.width, forKey: "hiDPI")`（`main.swift:156`）。用户跑的是 `SECDISPLAY_W=1600 / H=1000`，而 `main.swift:1681` 把 logical 默认成 `w/2 = 800`。若 hiDPI 生效，plist 里应该是 800x500 + Scale 2；实际是 1600x1000 + Scale 1，说明这次是显式把 logical 设成 1600x1000（`main.swift:1688-1692` 的分支），走的是「干净的 1x」路线。
3. 同一份 plist 里还留着历史对照：`UUID 3452EA1D` 是 `1440x900 Scale=2`（2880x1800 默认档、logical=1440），`UUID 69FB7C19` 是 `1280x800 Scale=1`。所以 CGVirtualDisplay 的 hiDPI 在部分档位能生效，1x 是参数选择的结果，不是 API 失效。

同一份 plist 的 config 2 完整记录了三屏并存且互不镜像：

```
0: 37D8832A  1512x982  Scale=2  Origin=(0,0)     Hz=120  Depth=8   (内建)
1: 252DF1EE  1600x1000 Scale=1  Origin=(1512,0)  Hz=90   Depth=4   (SecDisplay)
2: E2D35E82  1149x802  Scale=2  Origin=(-1149,0) Hz=60   Depth=4   (Sidecar)
```

这证明「扩展布局」本身是可以稳定存在的，三块屏并存不需要镜像。

### 3.3 光标自身的位图规格（实测）

```
NSCursor.currentSystem.image.size = (28.0, 40.0) 点
cgImage                          = 56 x 80 像素
hotSpot                          = (5.0, 5.0) 点
```

也就是说系统光标 1x 是 28x40 像素，2x 是 56x80 像素。这是后面算尺寸的基准。当前光标停在内建屏（2x），拿到的是 2x 位图，符合预期。

## 四、「一动就放大」的机制分析

先把候选逐条过一遍，再给最可能的完整解释。

### a. 镜像关系下 WindowServer 把 1x 光标按 2x 缩放绘制：**支持，且是主因**

镜像集（mirror set）只有一份合成帧缓冲，光标要么合成进这份缓冲，要么走独立的硬件光标平面。两条路径的位图选法不同：

- 静止时走硬件光标平面，按「光标所在屏」的 scale 取位图，Sidecar 上取 2x，尺寸正确。
- 移动时切到合成路径，位图按镜像集里 2x 的那块屏选取（56x80 像素），却落进 1x 的 1600x1000 主缓冲。相对桌面元素它就变成了 2 倍大。

算一遍就对上现象了。设虚拟屏是镜像主屏，iPad 侧内容缩放系数 `min(1149/1600, 802/1000) = 0.718`：

| 合成时用的位图 | iPad 上宽度（像素） | iPad 上宽度（点） | 相对正确值 |
|---|---|---|---|
| 1x（28x40） | 28 × 0.718 × 2 = 40 | 20 点 | 0.72x，偏小 |
| 2x（56x80） | 56 × 0.718 × 2 = 80 | 40 点 | **1.43x，明显偏大** |
| 正确 | 56 | 28 点 | 1.0 |

两条路径之间正好差 2 倍，所以体感是「一动就跳大」，不是「一直很大」。这个 2 倍跳变是判定 a 的关键特征，也解释了为什么静止时看着还行。

### b. 两边 backingScaleFactor 不一致导致尺寸跳变：**支持，与 a 是同一个根因的两面**

`Scale=1` 与 `Scale=2` 同处一个镜像集，是 a 能发生的前提。没有这个不一致，两条路径取到的是同一张位图，跳变消失。所以 b 不是独立机制，是根因描述。修的时候按 b 修（消除 scale 不一致或消除镜像），a 的现象自然消失。

### c. 辅助功能的光标大小 / 晃动放大：**排除**

见第五节，`cursorScale` 与 `shakeToLocate` 都不存在（等于默认：大小 1.0、晃动定位关闭）。且这两项一旦开启是全局生效，内建屏上也会变大，与「只在 iPad 上出现」矛盾。

### d. 虚拟屏 mode 尺寸/缩放给错，被当成低分屏补偿：**部分支持，但它是现象的必要条件而非充分条件**

虚拟屏确实是 1x（低分屏），这是事实。但 1x 屏单独存在时光标正常（内建 2x + 虚拟屏 1x 双屏并存是日常状态，用户没报过放大）。只有在镜像集里与 2x 屏混在一起才出问题。所以「1x」不是 bug，「1x 与 2x 进同一个镜像集」才是 bug。把虚拟屏改成 2x 能缓解，但代价见 5.3。

### 4.1 最可能的完整链路（推断，标注为推断）

1. Sidecar 接入后系统按上次保存的配置把它镜像到当时唯一的外接目标，也就是 SecDisplay 虚拟屏（`main.swift:209-211` 的注释记录了这种「Sidecar 抢镜像目标」的形态）。
2. 镜像集主屏是 1x 的虚拟屏（1600x1000），Sidecar 作为 slave 被塞进同一份帧缓冲。
3. 光标静止时由 Sidecar 侧的硬件光标平面呈现，尺寸正确。
4. 光标移动时改走合成路径，位图按 2x 选取、按 1x 坐标落位，iPad 上放大到约 40 点宽。
5. 1600x1000（1.6）与 1149x802（1.433）宽高比不同，镜像后 iPad 上应该能看到上下黑边。**这是判断镜像主从方向最快的肉眼判据**：有黑边说明虚拟屏是主屏，铺满说明 Sidecar 是主屏。

第 1 步到第 4 步是推断，没有 WindowServer 内部证据。第 5 步的黑边判据和第六节的截图测量可以把它坐实或推翻。

### 4.2 一个重要的时间线事实

`/Library/Preferences/com.apple.windowserver.displays.plist` 的 mtime 是 **12:39**，而 `MirrorGuard`（强制解除镜像）是 **12:49** 的提交 `633d746` 才进的代码（`main.swift:213-280`）。用户看到镜像现象时，那份自动解镜像的代码很可能还没生效。所以第一步应该是用当前构建复现一次，看日志里有没有 `解除镜像(...)`，再决定要不要加代码。

## 五、系统光标相关设置核查

`defaults read com.apple.universalaccess` 里与光标有关的键只有三个：

```
hoverTextCustomCursorColor   （悬停文本的自定义光标颜色，与指针尺寸无关）
mouseDriverCursorSize = "1.295101642608643"
switchSweepingCursorSpeed = 5     （切换控制扫描，与指针无关）
```

判读：

- `cursorScale` **不存在**，等于默认值 1.0，系统光标没有被调大。
- `shakeToLocate` **不存在**，晃动放大定位处于关闭状态。
- `mouseDriverCursorSize = 1.295` 看起来可疑，但同域的 `mouseDriver = 0`、`headMouseEnabled = 0`，说明「头部指针」功能没启用，这个尺寸值不参与渲染。
- `com.apple.Accessibility` 里没有任何 cursor / shake / pointer 相关键。

结论：c 候选可以硬排除。**不要**为了这个现象去改 `cursorScale`，改了会让内建屏和 Sidecar 一起变大，反而更糟。

## 六、修复方案

按「改动面 / 有效性」排序，推荐只做 F1。

### F1（推荐，唯一必做）：保证虚拟屏永不进入镜像集

代码里已经有 `MirrorGuard`（`main.swift:213-280`），但有两个口子要补：

1. **缺周期性兜底**。现在只在建屏后（`main.swift:1768`）和显示重配置回调（`main.swift:287`）时检查。如果 `CGCompleteDisplayConfiguration` 失败一次，而之后不再有重配置事件，就没有第二次机会。建议在已有的 2 秒定时器里（`main.swift:2020`）加一行 `MirrorGuard.release("周期检查")`，代价是一次 `CGDisplayMirrorsDisplay` 查询，可以忽略。
2. **失败没有可见反馈**。`release` 里 `CGCompleteDisplayConfiguration` 返回非 `.success` 时只写了一行日志（`main.swift:267-269`）。Sidecar 的镜像关系由 AirPlay 子系统管，CG 有可能拒绝。建议把 `CGError` 记进菜单栏状态或弹一次通知，让用户知道「系统不让解镜像」，而不是静默失败。

配套的用户侧约束（写进 README 或启动日志提示）：Sidecar 选「扩展显示器」，并在「排列」里把 iPad 矩形拖到虚拟屏矩形之外，两块不要重叠。重叠即镜像，这是系统行为，改代码绕不过去。

### F2（若确实需要镜像，才考虑）：让两边 scale 一致

三个可选参数组，都不推荐，列出来是为了说明代价：

| 方案 | SECDISPLAY_W/H | LOGICAL_W/H | 结果 | 代价 |
|---|---|---|---|---|
| 2x 同尺寸 | 1600x1000 | 800x500 | Scale=2，与 Sidecar 一致 | 桌面只有 800x500 点，窗口放不下，等于半屏 |
| 2x 双倍像素 | 3200x2000 | 1600x1000 | Scale=2，桌面空间不变 | 视频变 3200x2000，45fps 下约 100 Mbps，M1 Pro 的 H.264 硬编在 2880x1800 就已经顶到 46fps 左右（`main.swift:94-103` 的实测），这条路会掉帧 |
| 维持 1x | 1600x1000 | 1600x1000 | 现状 | 就是当前 bug |

也就是说「对齐 scale」在 1600x1000 这个视频尺寸上无解：要么桌面太小，要么码率和编码器吃不消。所以正确方向是 F1，不是 F2。

### F3（不建议）：调系统光标大小

把 `cursorScale` 调小会让所有屏的光标一起变小，包括内建屏。这是用一个全局副作用掩盖一个局部配置错误，不做。

### F4（可选，低优先）：刷新率对齐

用户那次运行虚拟屏是 `Hz=90`（plist config 2），Sidecar 是 60。镜像集里两块屏刷新率不整除会让光标在移动时抖，不是放大，但会加重「看着别扭」。如果保留镜像场景，把虚拟屏刷新率设成 60（`SECDISPLAY_REFRESH=60`）能减少抖动。

### F5（可选，代码卫生）：`.permanently` 污染显示配置库

`main.swift:266` 用 `CGCompleteDisplayConfiguration(cfg, .permanently)` 写盘。虚拟屏的 UUID 每次运行都变（plist 里已经攒了 `252DF1EE`、`FC567628`、`27135CE8`、`18EFF143` 等多份死配置），这些永远不会再出现的条目一直留在 `DisplayAnyUserSets` 里。解除镜像这类临时操作建议改成 `.forSession`。影响面小，但属于「只增不减」的垃圾积累。

## 七、验证步骤

按顺序做，每步都有明确判据。

### V0 先确认当前构建有没有自动解镜像（2 分钟）

```bash
# 启动 SecDisplay（用户自己的启动方式），保持 Sidecar 已连接
# 然后看日志里有没有这两行
grep -E "镜像守护|解除镜像" <日志>
```

判据：出现 `解除镜像(显示重配置)` 且没有 `解除镜像未生效`，说明 F1 已经生效，问题应该不复现。若一行都没有，说明镜像事件没触发回调，需要 F1 的周期性兜底。

### V1 现场取证：镜像状态与 scale（1 分钟）

不落盘，直接管道执行：

```bash
echo 'import CoreGraphics
import AppKit
for s in NSScreen.screens {
  let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  let m = CGDisplayCopyDisplayMode(id)
  print("id=\(id) \(s.localizedName) frame=\(s.frame) scale=\(s.backingScaleFactor) mode=\(m?.width ?? 0)x\(m?.height ?? 0) px=\(m?.pixelWidth ?? 0)x\(m?.pixelHeight ?? 0) mirrorOf=\(CGDisplayMirrorsDisplay(id)) vendor=0x\(String(CGDisplayVendorNumber(id),radix:16))")
}' | swift -
```

判据：Sidecar 的 `mirrorOf` 非 0，或虚拟屏的 `mirrorOf` 非 0，即镜像成立。同时记录两边的 `scale`。

### V2 量化光标尺寸（决定性实验，5 分钟）

镜像成立时，分别截静止态和移动态：

```bash
# 静止：把光标停在 iPad 画面中央不动，等 2 秒
screencapture -C -x -D <Sidecar的displayID> /tmp/cursor-idle.png

# 移动：用脚本持续移动光标，同时截图
```

移动脚本（一次性，不落盘）：

```bash
echo 'import CoreGraphics
for i in 0..<200 { CGWarpMouseCursorPosition(CGPoint(x: 600 + i % 20, y: 400)); usleep(20000) }' | swift - &
sleep 1; screencapture -C -x -D <Sidecar的displayID> /tmp/cursor-move.png
```

判据（用预览或 Python/PIL 量光标包围盒宽度）：

| 移动态宽度（像素） | 结论 |
|---|---|
| 约 56 | 与静止一致，说明放大发生在 iPad 客户端，改镜像策略即可 |
| 约 80 | 证实第四节 a 的「2x 位图落进 1x 空间」，缩放系数 1.43 对上 |
| 约 112 | 2x 位图按点直接绘制（2 倍整），机制同上但幅度更大 |

同时看 `/tmp/cursor-idle.png` 有没有上下黑边，判定镜像主从方向（有黑边 = 虚拟屏是主屏）。

### V3 修完复测

1. 镜像解除后，iPad 光标应为 28 点宽（2x 屏上 56 像素），静止与移动一致。
2. Windows 端光标按窗口 DPI 缩放后应约等于桌面元素比例，与 0x05 位图的 28x40 基准一致。
3. 三屏排列在 `check` 输出里 `mirrorOf` 全为 0，且断开重连 Sidecar 两次后仍然全 0。

## 八、未确认项

- WindowServer 内部到底在哪一步把 2x 位图放进 1x 缓冲，没有内部证据。第四节的链路是根据「静止正常 / 移动跳大 / 跳变约 2 倍 / 只随镜像出现」四个现象反推的，V2 的截图测量可以证实或推翻。
- 用户当时运行的构建是否已包含 `633d746`（12:49 提交），从 plist 的 12:39 mtime 看不出来，需要看用户实际启动时间。若早于该提交，F1 可能已经解决问题，不需要再加代码。
- `Depth=4`（虚拟屏与 Sidecar）与 `Depth=8`（内建）的差异没有深究，与光标无关，但如果后续出现色带可以回来查。
