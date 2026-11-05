# SecDisplay 调研阶段一：Duet 原理拆解与本机验证

日期：2026-11-05
环境：MacBook Pro M1 Pro / 16GB / macOS 27.2 (26B123) / arm64

---

## 0. 一句话结论

Duet 的实现没有任何"魔法链路"。它是三件成熟技术的组合：

1. 让操作系统相信有一块真实显示器插着（虚拟显示器）
2. 用 GPU 硬件编码器把这块屏的画面压成视频（VideoToolbox / NVENC / Intel VPL / AMD）
3. 用一条不排队的传输通道把视频送到对端，对端硬解后直接上屏

你之前用的开源方案差，差的不是这套架构，而是三个地方做得糙：色度抽样用 4:2:0（文字糊）、走 TCP 但没有调拥塞和缓冲（延迟堆积）、没有走硬件编码器的高优先级路径。这三点后面会逐个拆开讲。

---

## 1. 从 Duet 官方发布记录反推的架构

Duet Windows/macOS 4.0.x 的更新日志里散落着大量实现细节，这些是它自己写出来的，比任何测评都可靠。

### 1.1 虚拟显示器层

| 线索 | 出处 | 推断 |
|---|---|---|
| `DuetBus.sys` / `duetbus.inf` | 安装目录文件清单 | 自建总线枚举设备，用于让虚拟显示器像"真的插上了一台显示器" |
| `DuetDisplayDriver.dll` / `DuetDisplayDriver.inf`，设备类型 GUID `{4D36E968-E325-11CE-BFC1-08002BE10318}` | 驱动包元信息 | 「显示适配器」类，是 IddCx 的 indirect display 的用户态 UMDF 驱动 |
| "Resolved a display driver crash occurring within the DXGI desktop duplication update loop" | Windows 发布记录 | 走 DXGI Desktop Duplication 取帧，作为镜像模式的抓取路径 |
| "Fixed an issue in the display driver path that could throttle the actual frame rate to half of the selected setting" | Windows 发布记录 | 驱动路径里就有帧率控制，说明节流在驱动侧实现 |
| "New Display Driver to improve mouse input latency" | Windows 发布记录 | 硬件光标由驱动层提供，不是画进视频里 |
| "Preloaded the Duet Display driver for improved performance" | Windows 发布记录 | 常驻驱动避免每次连接重新加载 |

Windows 侧走的是 **IddCx**，微软给远程显示场景设计的正规用户态驱动模型。这是关键：虚拟屏是操作系统一等公民，拖动窗口、吸附、菜单栏、独立刷新率全都正常，跟插了根 HDMI 线没区别。

macOS 侧对应物是私有 API `CGVirtualDisplay`（BetterDisplay、DeskPad、Chromium 的虚拟屏功能都用它）。

### 1.2 编码层

| 线索 | 推断 |
|---|---|
| "Add HEVC Encoding for NVidia GPUs" | 至少对 NVIDIA 支持 HEVC |
| "Optimized HEVC video encoding and streaming performance"（2026-10） | HEVC 是当前主推路径 |
| "Added a new video encoder utilizing the Intel Video Processing Library (VPL)" | 每个 GPU 厂商一套独立编码后端，说明是直接调各家的硬件编码 API |
| "Added a dedicated hardware video encoder for Snapdragon Adreno GPUs on ARM64 Windows devices" | 同上，ARM64 也单独适配 |
| "Added the ability to choose the discrete NVidia GPU on dual AMD/NVidia systems" | 需要手动指定编码 GPU，是驱动级控制的特征 |
| "Fixed a memory leak with the Nvidia Encoder, which occurred when changing the resolution" | 直接持有 NVENC 会话 |
| "Resolved an issue with the Nvidia encoder getting stuck during flushing" | 用到编码器的 flush 语义，说明有关键帧请求和重建逻辑 |
| "Fixed decoder crash that happens when the decoder is rebuilt (e.g., when host resolution changes)" | 接收端在分辨率变化时重建硬解器，不是软件解码 |

结论：Duet 不用 FFmpeg 做编码（FFmpeg 解码库 `avcodec-58.dll` 只在部分内部处理用到），编码全程走厂商硬件编码器，每个后端单独调优。这就是它比通用开源方案省电、延迟低的第一层原因。

### 1.3 传输层

| 线索 | 推断 |
|---|---|
| "Resolved an application crash occurring during SSL TCP data transfers" | 走 TCP，带 TLS |
| "Improved wired connections could get stuck on the 'Launching Duet' screen" | 有线走 USB 网络或虚拟网卡 |
| "Resolved an issue where wired USB connections could get stuck" | USB 是独立通道 |
| "Added an expert setting to manually adjust the nominal video bitrate" | 码率是显式控制的 |
| "Implemented target bitrate settings on the Mac client" | 同上 |
| "Prevent Mixpanel analytics overload by reducing reports of encoder errors to 1 per minute" | 有编码错误上报，说明运行时监控编码健康度 |
| "Enhanced latency calculations" | 它有端到端延迟测量，不是拍脑袋 |
| "Bitrate optimizations for Duet Air to reduce latency" | 码率直接用于控制延迟 |

"Redesigning its network protocol from the ground up"（2022 年 CEO 原话）之后，它做的是**应用层自定义协议跑在 TCP 上**，关键点在于：
- TCP 保证帧完整，不需要在应用层再做纠错
- 但必须自己控制"发送队列深度"，否则 TCP 缓冲区一堆积，延迟就是几百毫秒
- 每帧带时间戳，接收端可以判断"这帧已经过期了就别等了"

### 1.4 历史原点：2014 年的逆向分析

Dean McNamee 在 Duet 2014 年首发时做过完整的二进制比对，结论至今有效：

- 虚拟屏是**内存后备帧缓冲**，不是 DisplayLink 那种带硬件的真显示通路
- 画面走 **PeerTalk**（逆向自 iTunes 的 usbmuxd）经 USB 传输，本质是 TCP over USB
- 编码借用了 **CocoaSplit** 的 GLSL 片元着色器做 420v 格式转换
- 用 **GPUImage** 做 OpenGL 图像处理

那份分析的原话是"这本质上就像 VNC over TCP over UDP"，并且直言它宣传的"零延迟"和"60帧"有夸大成分。注意这里是 2014 年，当时确实是软件编码，CPU 占用大。这十几年它做的事情就是不断把软件编码换成硬件编码、把 VNC 式协议换成按帧定制的低延迟协议。

**这一点很重要：Duet 早年就是"高级 VNC"，现在不是了。**

---

## 2. 为什么开源方案感觉差

按影响程度排序，这是实际体验差距的主要来源。

### 2.1 色度抽样：文字糊的头号原因（影响最大）

H.264/HEVC 默认用 **YUV 4:2:0**：亮度保留全分辨率，色度水平和垂直各砍一半（相当于色度只有 1/4 分辨率）。

对照片和电影，人眼感觉不到。对桌面文字，这是灾难：
- 黑字白底，字边缘的过渡像素本来靠色度信息，砍掉后就变成彩色毛边或灰边
- 细线条、彩色图标边缘出现"糊边"和"彩虹纹"

Duet 的对策：提高码率 + 高 Profile，让编码器把有限的色度预算花在刀刃上。更好的做法是 **4:4:4**（色度全分辨率），RDP 的 AVC444 模式就是干这个的，代价是带宽约翻 2~3 倍。

**2400x1600@60fps 桌面文字场景，4:2:0 大约需要 30~60 Mbps 才有"够看"的观感，4:4:4 需要 100~200 Mbps。千兆有线完全吃得下。**

### 2.2 编码器选型：硬编 vs 软编

| | 硬编 | 软编（x264 veryfast） |
|---|---|---|
| 1080p60 延迟 | 3~15 ms | 10~30 ms |
| CPU 占用 | 几乎为 0 | 1~3 个核满载 |
| 功耗 | 低 | 高，风扇起转 |
| 画质（同码率） | 略低 | 略高 |

开源方案常见的坑：用 FFmpeg 默认参数软编，CPU 单核跑满后帧就掉了，掉帧再补，体验就崩了。

### 2.3 队列深度：延迟堆积的真凶

这是最容易被忽略、但体感最直接的一项。

用 TCP 传视频时，如果发送端比接收端快：
```
发送端: 帧1 帧2 帧3 帧4 帧5 帧6 ...
TCP 缓冲: [帧1 帧2 帧3 帧4 帧5]  ← 堆积在这里
接收端: 还在解码帧1
```
用户在副屏上看到的永远是**几百毫秒前**的画面，而且是持续滞后的，鼠标一动要等半秒才响应。

正确做法：
- 发送端限制"在途帧数"（比如最多 2 帧），满了就丢新帧
- 关键帧（IDR）定期或按需重发，保证丢帧后能恢复
- 关闭 Nagle（`TCP_NODELAY`），小包立即发

实测数据（社区项目 Mirage 的公开测试）：2880x1800@60fps，端到端 **中位 19ms，p95 27ms**。这说明二十毫秒级完全做得到。

### 2.4 传输通道

| 通道 | 典型单程延迟 | 带宽 | 稳定性 |
|---|---|---|---|
| 千兆有线（USB 网卡/雷电网卡） | 0.2~0.5 ms | 940 Mbps | 极高 |
| 雷电桥接 | 0.1~0.3 ms | 10~20 Gbps | 极高 |
| 5GHz Wi-Fi 6 | 2~10 ms，抖动大 | 300~800 Mbps | 一般 |
| Wi-Fi 7 | 1~5 ms | 1~3 Gbps | 较好 |

你说可以走有线，那延迟预算里网络只占 1ms 以内，剩下的全是编码和解码，这是最好的情况。

### 2.5 缩放

如果虚拟屏的逻辑分辨率和你实际显示的不一致，系统会做一次缩放，再经编码器压一次，文字二次糊。正确做法是虚拟屏的像素尺寸和 Windows 屏幕的物理像素严格 1:1。

---

## 3. 本机验证结果

### 3.1 验证项 1：CGVirtualDisplay 私有 API

实测代码：`prototype/mac/VirtualDisplayProbe.swift`

结果：
```
OK: 私有类存在（CGVirtualDisplay / Descriptor / Mode / Settings 都在）
FAIL: -[VirtualDisplayClient pluginWithOptions:]: spawnProxy message error kr=0x5((os/kern) failure)
FAIL: CGVirtualDisplay 初始化失败
```

`spawnProxy` 失败，意思是它无法拉起 `DMProxy` 辅助进程。

### 3.2 验证项 2：绕过封装直调 CoreDisplay 的 C 接口

实测代码：`prototype/mac/CDVirtualDisplayProbe.swift`

反汇编 `CDVirtualDisplayCreateWithOptions` 得到的真实签名：
```
CDVirtualDisplayCreateWithOptions(uuid, options, settings, bool, &outDisplayID) -> display*
CDVirtualDisplayApplySettingsDictionary(display, settings) -> bool
CDVirtualDisplayDestroy(display)
```
`CGXVirtualDisplayCreate/Apply/SetOptions` 在本机**全部缺失**，说明 CoreGraphics 的封装层已经改了内部走法。

直调结果：仍然在 `-[VirtualDisplayClient initWithOptions:queue:terminationHandler:context:]` 处抛异常。这条路和封装层走到的是同一个卡点。

### 3.3 卡点定位

从 CoreDisplay 的字符串常量里挖到了完整链路：
```
com.apple.CoreDisplay.XPCService          ← 虚拟屏的实际创建者
com.apple.Display.VirtualDisplayMetrics
com.apple.VirtualDisplayListener
/System/Library/Frameworks/CoreGraphics.framework/Resources/DMProxy
CGError run_dmproxy(const char *, CGXCredentials)
  "%s: posix_spawn => %d"
```
所以 macOS 26/27 上的虚拟屏是**跨进程**的：你的 App 只是客户端，真正的显示器由 CoreDisplay 的 XPC 服务和 DMProxy 子进程创建。

在 macOS 27.2 上用裸 `swiftc` 编出来的无签名可执行文件被拒绝了。这需要进一步确认是不是签名/权限问题。

### 3.4 更正：虚拟屏可用，之前的失败是我自己的 bug

先说结论：**虚拟屏在 macOS 27.2 上完全可用，已稳定复现。**

之前的误判来自两个自己写错的地方，必须如实记录，避免以后再被误导：

**错误一：用 `perform` 调用返回 BOOL 的方法**

```swift
// 错误写法：把 BOOL 返回值当成对象指针 retain，直接 SIGSEGV
disp.perform(NSSelectorFromString("applySettings:"), with: settings)?
    .takeUnretainedValue() as? Bool

// 正确写法
let applySel = NSSelectorFromString("applySettings:")
typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
let ok = unsafeBitCast(disp.method(for: applySel), to: ApplyFn.self)(disp, applySel, settings)
```

崩溃栈落在 `swift_unknownObjectRetain`，我一开始误以为是 CoreDisplay 内部出错，实际是 Swift 桥接问题。

**错误二：判定逻辑写反**

```swift
// 错误：outID 在 init 阶段就是有效值，且显示器同步上线
if found == 0 { print("FAIL: 设置被接受但显示器未上线") }
```

`applySettings` 返回 true 时显示器立刻就在线（等待 0 ms），代码却仍然走了失败分支。

**关于 `spawnProxy kr=0x5` 那条日志**

它确实会打印，但**不影响创建结果**。`initWithDescriptor:` 内部会尝试拉起 CoreDisplay 的 XPC 服务并失败，然后走一条进程内的本地路径兜底，照样把显示器建出来。所以这条错误日志是噪音，不能作为“系统拦截”的判断依据。

同样，`bootstrap_look_up` 查 `com.apple.CoreDisplay.XPCService` 返回 1102 也是真实的，但这个服务只在需要跨进程代理时才用，本地路径不需要它。

### 3.5 稳定复现结果

```
$ ./fullcreate 2560 1600 60
创建 2560x1600 @60.0Hz
init 成功, displayID 属性 = 20
模式: 1280x800 @60
applySettings -> true
上线: true 等待 0 ms
  bounds (1512.0, 0.0, 2560.0, 1600.0)
  像素 2560x1600
  NSScreen SecDisplay id=20 scale=1.0
```

连续 4 次全部成功。裸 `swiftc` 编译、无签名、无 App bundle 都能跑。

### 3.6 HiDPI 的正确配置

HiDPI 的触发条件不是 `settings.hiDPI` 这个开关，而是 **`maxPixelsWide/High` 要设为背板像素，模式请求逻辑尺寸**：

```
描述符 maxPixelsWide/High = 5120 x 3200   （背板）
模式 width/height          = 2560 x 1600   （逻辑）
结果：当前模式 2560x1600 背板 5120x3200     ← 这就是 2x
```

对照实验：
| 背板 | 逻辑 | 结果 |
|---|---|---|
| 2560x1600 | 2560x1600 | scale=1.0，1:1，无 HiDPI |
| 2560x1600 | 1280x800 | 系统忽略请求，回落到 1:1 |
| 5120x3200 | 2560x1600 | **scale=2.0，真正的 Retina** |

**但这里有个重要取舍**：你的 Windows 屏要跟虚拟屏像素严格 1:1 才不糊。所以分两种情况：
- Windows 屏是 2560x1600 → 背板 2560x1600，逻辑 2560x1600（scale 1.0），这是**正确的**，不要开 HiDPI
- Windows 屏是 1280x800 → 背板 2560x1600，逻辑 1280x800，scale 2.0，UI 更大更清晰

具体用哪种，取决于 Windows 机器的屏幕分辨率和缩放设置。

### 3.7 兜底方案不再需要，方向保持原计划

虚拟屏既然可用，**你原本的目标（MacBook 主屏 + Windows 副屏）就是可行的**，不需要把角色反过来。

保留记录：如果以后 macOS 升级把这条路彻底关掉，退路是让 Windows 侧用 IddCx 建虚拟屏。IddCx 是微软公开的正规驱动模型，长期稳定性比 macOS 私有 API 好。

---

## 4. 下一步计划

按你确认的方向推进管线原型：

1. **Mac 端**
   - 用 `VDCreate.swift` 里验证过的逻辑创建虚拟屏，尺寸跟 Windows 屏幕物理像素对齐
   - ScreenCaptureKit 的 `SCStream` 绑定到这块虚拟屏
   - VideoToolbox 低延迟硬编：`EnableLowLatencyRateControl`、无 B 帧、420v
   - TCP_NODELAY 发送，在途帧数上限 2，超了就丢

2. **Windows 端**
   - 接收 → Media Foundation 硬解 → 全屏置顶无边框窗口
   - 用 `Present` 直接上屏，跳过普通窗口合成

3. **先跑通再优化**
   - 第一步只求跑通，量出端到端延迟
   - 再逐项调：分辨率、码率、色度格式、关键帧策略

4. **有线通道**
   - 优先用 USB 网卡或雷电桥接的静态 IP
   - 实测 ping RTT 作为基线

---

## 附：本目录文件

```
dumps/
  DuetDisplay-4-0-521.exe     Duet Windows 安装包（74MB，已下载）
  extract.py / cab.py / ...   解包尝试脚本（SFX 内嵌载荷，解压格式非标准，未成功）
  sfx_info.py                 安装包结构分析（资源表、分区、熵值）
research/
  REPORT-01-duet-architecture.md   本文
prototype/mac/
  VirtualDisplayProbe.swift   虚拟屏验证
  CDVirtualDisplayProbe.swift 绕过封装直调
  ScanImage.swift             运行时扫私有 framework 字符串
```
