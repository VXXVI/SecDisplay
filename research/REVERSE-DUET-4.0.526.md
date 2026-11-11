# Duet Display 4.0.526 逆向分析（REA + 静态证据）

分析日期：2026-11-09
目标：官方安装包，非第三方转载版
- Mac：`https://duetdownload.com/Mac/v4.0.526/DuetDisplay-4-0-526.dmg`（132,983,119 字节）
- Windows：`https://duetdownload.com/Windows/v4.0.526/DuetDisplay-4-0-526.exe`（179,225,824 字节，SHA256 `9b25f9e62bd86b941f75d755da211be68fd999397e54256ab3e59c6124394f55`）

方法：REA（`open_binary` / `inspect_macho` / `inspect_analysis_view`）+ `lipo` / `plutil` / `hdiutil` / `cabextract` / `pylibmspack` / 二进制字符串分组。
证据分级：**观察**（二进制里直接存在）、**推断**（由观察组合得出）、**未知**（静态分析看不到运行行为）。

---

## 一、总体架构（观察）

Mac 端主程序 `duet.app/Contents/MacOS/duet`：61MB，universal（x86_64 + arm64），Qt 6.7.2 界面 + C++ 核心。

REA `inspect_macho` 依赖表（arm64 slice，SHA256 `8c2786ba…`）：

| 框架 | 链接方式 | 用途推断 |
|---|---|---|
| CoreGraphics | 强 | CGDisplayStream / CGVirtualDisplay / CGEvent |
| ApplicationServices | 强 | 旧显示与光标 API |
| VideoToolbox | 强 | H.264/HEVC 硬编 |
| CoreMedia / CoreVideo | 强 | CMSampleBuffer / CVPixelBuffer |
| IOSurface / Metal / QuartzCore / Accelerate | 强 | 零拷贝帧传递、图像缩放 |
| IOKit / IOBluetooth | 强 | USB/蓝牙设备发现 |
| **ScreenCaptureKit** | **弱（LC_LOAD_WEAK_DYLIB）** | 运行时优先采集（macOS ≥14.3） |
| libavcodec.61 / libavformat.61 / libswscale.8 | 自带 | 软件编解码/缩放后备 |
| QtWebSockets / QtNetwork | 自带 | 传输 |

> **2026-11-11 更正**：下面这段「采集主力是 CGDisplayStream」的判断已被反汇编推翻。
> `GetInstance` 里 macOS ≥ 14.3 且 `SCStream` 类可用时**优先走 ScreenCaptureKit**，
> `CGDisplayStream` 只是旧系统回退。弱链接只反映部署目标，不代表运行时优先级。
> 依据见 `research/RESULT-duet-mac-encode-deep.md`。

Windows 端（从 exe 内嵌文件名和 CAB 解包，观察）：
- 接收端：`duet.exe`、`DuetDisplaySL.exe`、`DuetLaunch.exe`
- 虚拟显示驱动：`DuetDisplayDriver.dll` + `.inf` + `.cat`、`duetbus.sys`（总线）、`DuetWPDFilter.sys`（WPD 过滤）
- USB 通道：`DuetAOAP.inf`、`usbaapl64.sys`、`netaapl64.cat`、`WudfUpdate_01011.dll`（UMDF）；主 CAB 实际是 Apple Mobile Device Support 组件（AppleMobileDeviceService、MobileDevice.dll、SyncServices 等），Duet 借它做 iOS USB 通信
- 解码：`avcodec-58.dll` / `avformat-58.dll` / `swscale-5.dll`（FFmpeg 4.x）
- 呈现：`D3Dcompiler_47.dll`、`qwindows.dll`、`d3d` 相关

传输用 protobuf，协议定义文件名（观察）：`Input.proto`、`FrameStats.proto`、`ClientSettings.proto`、`Clipboard.proto`、`FileTransfer.proto`、`KMS.proto`、`RDP.proto`、`Annotation.proto`。核心消息/类：`NewVideoFrame`、`NewCursorLocation`、`NewCursorImage`、`NewCursorPosition`、`FirstVideoFrameReceived`、`GotClosePacket`；类 `Duet_EncoderPipeline`、`Duet_ApplicationEncoderPipeline`、`Duet_CursorPipeline`、`Duet_ICursorPipeline`、`Duet_VirtualDisplayManagerMac`、`Duet_Queue<…RDP::DuetRDPPacket>`。

---

## 二、延迟为什么低（回答用户问题）

Duet 的低延迟不是单一黑科技，是一整套「不给缓冲留余地」的组合。以下均为观察：

### 编码（VTCompressionSession）
导入的私有属性键：
- `kVTCompressionPropertyKey_RealTime` —— 实时模式，编码器不做前瞻缓冲
- `kVTCompressionPropertyKey_AllowFrameReordering` —— 关 B 帧重排
- `kVTCompressionPropertyKey_MaxKeyFrameInterval` / `MaxKeyFrameIntervalDuration` —— 控 GOP
- `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality` —— 速度优先
- `kVTCompressionPropertyKey_AverageBitRate` / `DataRateLimits` —— 码率上限
- `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` —— 强制硬编
- `VTCompressionSessionEncodeFrame` / `CompleteFrames` / `PrepareToEncodeFrames`

这跟我们的 VideoToolbox 配置方向一致，不是主要差距。

### 采集节奏（关键差异）
导入 `CGDisplayStream` 的属性键：`kCGDisplayStreamMinimumFrameTime`、`kCGDisplayStreamQueueDepth`、`kCGDisplayStreamShowCursor`。ObjC 侧有 `setMinimumFrameInterval:`、`setQueueDepth:`。

推断：Duet 用非常浅的队列（低 QueueDepth）和显式的最小帧间隔控制，宁可丢帧也不让帧在队列里堆积。这直接压住「积压型延迟」。

### 自适应码率（我们缺的）
字符串证据：`ApplyAdaptiveBitRateLimit`、`UpdateEffectiveBitRateLocked`、`GetOneMinuteEncoderBitRate`、`ResetBitRate`、`videoBitRateOptionsMbps`、`transmittedBitRateMbps`、`SenderDefaultBitRateMbps`、`averageLatency` / `currentLatency`、`Connection Latency Average` / `Maximum`。

推断：Duet 有一分钟窗口的码率统计 + 基于延迟的自适应限流，网络一拥塞就降码率而不是让队列膨胀。我们目前是固定 180Mbps，没有这条反馈环。

### 分辨率上限（我们缺的）
`s_MAXIMUM_ENCODING_RESOLUTION_WIDTH_DEFAULT`、`s_MAXIMUM_ENCODING_RESOLUTION_WIDTH_HEVC`、`ResolutionOption`、`displayResolutionOptions`、`ConnectionSettings/ExtendedResolution`、`Original Resolution`。

推断：Duet 默认不是无脑跑满物理分辨率，它给用户「Original Resolution」等档位，并对不同编码器设最大宽度。这与我们「Duet 可能默认分辨率更低」的猜测方向一致，但静态证据只能证明**存在上限机制**，具体默认数值要看运行配置，属于未知。

### 传输
USB 直连（usbaapl / AOA）+ AWDL（Apple Wireless Direct Link，见 `com.kairos.awdltool.xpc`）+ protobuf + 加密（`RDPPacketCrypto` / `MTLSPacketCrypto` / `PKIPacketCrypto`）。2022 年官方宣称「重设计网络协议」并「充分利用硬件加速」。USB 相比我们走的 TCP/Thunderbolt Bridge 是不同路径，但我们的雷电桥实测 ping 0.76ms，链路本身不是瓶颈。

---

## 三、鼠标指针怎么解决（回答用户问题，最重要）

这是 Duet 与我们差距最大的地方，也是用户「指针调用的是 windows 指针」「点击错位」的根因对照。

Duet 的完整方案（观察）：

| 环节 | 证据 | 作用 |
|---|---|---|
| 采集画面不含光标 | `kCGDisplayStreamShowCursor`（可配）、`CGDisplayHideCursor`、`CGDisplayShowCursor` | 视频流与光标解耦 |
| Mac 端隐藏本地光标 | `Duet_MacCursorHider`、`Duet_CursorHider`、`hideCursor`、`CursorVisibilityChanged` | 避免主屏残留 |
| 读取真实系统光标 | `currentSystemCursor`、`NSCursor`、`CGSCurrentCursorSeed`（字符串）、`cursorImage`、`cursorHotspotX/Y` | 拿到 Mac 真实光标图像和热点 |
| 独立光标通道 | `Duet_CursorPipeline`、`Duet_ICursorPipeline` | 与视频分开传输 |
| 光标消息 | `NewCursorImage`、`NewCursorLocation`、`NewCursorPosition`、`hasCursorPosition`、`cursorX/Y` | 图像 + 热点 + 位置三件套 |
| 接收端本地绘制 | 推断（Windows 侧有对应 cursor 处理） | 零延迟、无拖影 |
| 输入回传 | `sendPointerDataWithX:Y:button:scroll:`、`MACOS_CGEVENT_DATA`、`MOUSE_DOUBLE_CLICK`、`CGEventPost`、`CGEventCreate*`、`CGEventTapCreate` | 点击/滚轮/键盘回放到 Mac |

也就是说：**Duet 传输的是 Mac 真实光标图像（含箭头、工字、手型等所有形态）+ 热点 + 位置，接收端本地画出来**。所以它既没有 Windows 系统箭头的外观问题，也没有我们「用 SetCursorPos 搬本机光标和用户鼠标抢位置」的点击错位问题。

对照我们的现状：
- 我们已做到：视频剥离光标（`showsCursor=false`）、独立 `0x03` 光标包传坐标、Windows `SetCursorPos`、输入回传（`0x04` + CGEvent）、光标让位规则。
- 我们缺的：**真实光标图像与热点**。之前卡在 `CGSGetGlobalCursorData` 私有 API 签名不明不敢用。Duet 用 `currentSystemCursor` / `NSCursor` 这条路证明有更稳的公开/半公开途径可拿系统光标。

---

## 四、可直接复用的改进清单（按性价比）

1. **真实光标图像**：用 `NSCursor.currentSystemCursor`（AppKit，公开 API）取当前光标，读它的 `image` 和 `hotSpot`，序列化进光标包；Windows 端用 `CreateIconIndirect` / D3D 画出来。这是解决「Windows 箭头」和「指针外观」的正解，且避开私有 API 风险。
2. **自适应码率环**：仿 `ApplyAdaptiveBitRateLimit`，按一分钟窗口的发送速率和 RTT/延迟反馈动态调 `AverageBitRate`，拥塞时降码率而非堆积队列。
3. **浅队列 + 显式帧间隔**：我们已有 `captureHz`，但要确认队列深度是否像 Duet 一样浅，避免帧在 pipeline 里排队。
4. **分辨率档位与默认上限**：给用户 sharp/balanced/smooth/fast（已做），并设一个默认最大宽度，别默认跑满 2880x1800。
5. **延迟监控可视化**：`averageLatency` / `currentLatency` 这类指标我们已有统计行，可补充到 GUI。

## 五、明确无法从静态分析得到的（未知）

- 各档位的具体默认分辨率数值、默认码率、默认 QueueDepth
- 接收端呈现是否用垂直同步、DWM 合成还是独占全屏
- 实际运行时的帧率、抖动、端到端延迟
- 授权/服务端协议细节
- `CGSGetGlobalCursorData` 的确切签名（但 `NSCursor` 路线可绕开）

要拿到这些需要运行 Duet 并抓包/埋点，本次未做（需要账号登录与真实设备）。

## 六、结论

架构层面我们与 Duet 已经对齐（虚拟屏 + VT 硬编 + protobuf/网络 + 硬解/FFmpeg 解码 + 本地呈现）。差距集中在三处工程细节：**真实光标图像通道**、**自适应码率反馈环**、**默认分辨率/队列的保守策略**。这些不需要反编译 core 逻辑就能补齐，且第一项正好对应你反复反馈的指针问题。
