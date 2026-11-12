# RESULT：Duet Display 4.0.526 依赖盘点与 SecDisplay 差距分析

> 日期：2026-11-12
> 方法：只读汇总既有逆向报告，未挂载 dmg（`/Volumes` 下已无 Duet 卷），全部证据以报告为准
> 输入：`RESULT-duet-mac-static.md`、`RESULT-duet-mac-encode-deep.md`、`RESULT-duet-mac-proto-deep.md`、`RESULT-duet-win-static.md`、`RESULT-duet-win-deep-2026-11-12.md`、`REVERSE-DUET-4.0.526.md`
> 现状核对：`prototype/mac/Sources/ScreenSender.swift`（1807 行）、`prototype/windows/SecDisplayReceiver.cpp`（2506 行）import / include 实测
> 证据分级沿用：观察 / 推断 / 未知

## 一、Duet Mac 端依赖清单（观察）

| 依赖 | 链接方式 | 作用 |
|---|---|---|
| CoreGraphics | 强 | CGDisplayStream 旧系统采集回退、CGVirtualDisplay、CGEvent 输入注入 |
| ScreenCaptureKit | 弱（LC_LOAD_WEAK_DYLIB） | 运行时优先采集，闸门为 macOS ≥ 14.3 且 `SCStream` 类存在（encode-deep §3 已修正方向） |
| VideoToolbox | 强 | H.264/HEVC 硬编，RealTime + 禁重排 + GOP 10s + 双窗口 DataRateLimits |
| CoreMedia / CoreVideo / IOSurface / Metal / QuartzCore / Accelerate | 强 | CMSampleBuffer / CVPixelBuffer、零拷贝帧传递、图像缩放 |
| IOKit / IOBluetooth | 强 | USB / 蓝牙设备发现 |
| libavcodec.61 / libavformat.61 / libswscale.8 | 自带 | FFmpeg 7.x 软编软解与缩放后备 |
| Qt 6.7.2 + QtWebSockets + QtNetwork | 自带 | UI、云中继 WebSocket 传输 |
| OpenSSL | 静态链接 | 直连 mTLS（InitClientmTLS / InitHostmTLS）+ 应用层 PKI/PBKDF 包级加密，AES256 |
| Sparkle | 自带 framework 目录 | 自动更新 |
| AWDL 特权助手 | `/Library/PrivilegedHelperTools/com.kairos.awdltool.xpc` | 拉起 awdl0 接口做 Apple P2P 直连 |
| NSURLSessionWebSocketTask | 系统 | 信令/中继通道 |
| protobuf（描述符内嵌） | 静态编译 | 8 个 proto：Input / FrameStats / ClientSettings / Clipboard / FileTransfer / KMS / RDP / Annotation |

## 二、Duet Windows 端依赖清单（观察）

| 依赖 | 作用 |
|---|---|
| FFmpeg 4.x（avcodec-58 / avformat-58 / swscale-5） | 客户端软解码（Qt QGraphicsView pixmap 呈现，非 D3D11 交换链） |
| Qt（qwindows.dll、D3Dcompiler_47.dll） | 客户端窗口与视图 |
| IddCx 1.2 UMDF 驱动 + duetbus.sys（KMDF 1.15 静态总线） | Windows 当 host 时的虚拟显示器 |
| Apple Mobile Device Support（usbaapl64.sys / AOA / netaapl64.cat） | iOS USB 通道 |
| Media Foundation（`DuetLastEncoder=MFHardware_VEN_8086`） | Windows 当 host 时的硬编 |
| D3D11 / DXGI | host 侧采集（Duet_DXGIDuplicateDesktop 等）与呈现辅助 |
| protobuf | 同 Mac 端协议族 |

## 三、SecDisplay 现状（代码实测）

- Mac 端（`ScreenSender.swift:22-30`）：仅系统框架 Foundation / CoreGraphics / CoreVideo / VideoToolbox / ScreenCaptureKit / Network / AppKit / Darwin。零第三方依赖，单文件 swiftc 编译。
- Windows 端（`SecDisplayReceiver.cpp:28-71`）：Win32 + winsock2 + D3D11 + DXGI + Media Foundation（mfplat/mfreadwrite），MSVC/MinGW 原生编译。无 Qt、无 OpenSSL、无 FFmpeg。
- 协议：自定义二进制（0x01 帧、0x03/0x05 光标、0x04 输入、0x07 帧统计反馈），单 TCP 9922，雷电直连。

## 四、差距表

| 能力 | Duet 做法 | SecDisplay 现状 | 结论 | 最小路径 |
|---|---|---|---|---|
| 采集 API | SCK 优先（≥14.3）+ CG 回退，QueueDepth=5，MinimumFrameTime=1/fps | SCK 单路，queueDepth 默认 3（`ScreenSender.swift:594`），有 captureHz | 不需要补回退，可选补浅队列参数与显式最小帧间隔 | SCK 配置一处，约 0.5 人日；先实测 QD=3 与 5 的差异再定 |
| 编码参数 | RealTime/禁重排/GOP 10s+ForceKeyFrame/双窗口 DataRateLimits/709+sRGB | 已有 RealTime、ExpectedFrameRate、ABR+DataRateLimits 联动（v2 已修同步硬上限） | 基本对齐；可选补按需 ForceKeyFrame 与静止 IDR 退避已有 | 1 人日内 |
| 自适应码率 | 三档 {40%,8M}{30%,6M}{20%,4M}，2Mbps 地板，RTT 环缓冲 11 样本，avg≥last+150ms 触发，降档 10s 冷却 | v2 已实现 0x07 反馈 + 健康度 + 8s 试探回退，待真机验证 | 必须补的只剩真机验证，算法不必照抄 | 0 编码工作，跑 motionloader + --feedback 闭环 1 人日 |
| 帧统计 | FrameStats 8 段 checkpoint（CAPTURED→PRESENTED）+ Clock 域 + RTT，线上 dsts 包 | 0x07 有 6 字段（presentP95/sourceP95/decodeFps/presentDrop/pacedDrop），本地有源/上屏间隔统计 | 可选：补 send 段与 RTT 单向打点，日志对齐更易归因 | 0x07 扩 4 字节 + Mac/Win 各一处打点，约 1 人日 |
| 光标 | NSCursor 真实图像 + 热点 + 独立 tag 通道，硬件鼠标事件 | 0x05 图像 + 0x03 位置 + 事件驱动跟随已做 | 已对齐 | 无 |
| 传输加密 | 直连 mTLS + 应用层 PKI/PBKDF 双层（走中继时中继不可读） | 无加密，明文 TCP | 不需要（当前场景）；见专项评估 1 | 若做：Network.framework TLS + 预置自签证书 pinning，约 2 人日 |
| 剪贴板 | Clipboard.proto，仅 TEXT=0 | 无 | 可选 | 文本剪贴板一条小消息，两侧各约 0.5 人日 |
| 文件传输 / 注释 / 手势 | FileTransfer / Annotation / Gesture proto | 无 | 不需要 | 单用户副屏场景用不上 |
| 多链路（AWDL / USB AOA / 云中继） | AWDL helper + usbaapl + WebSocket 中继 | 雷电 TCP 单链路，ping 0.76ms | 不需要 | 直连链路已最优，中继与无线通道与目标无关 |
| UI 框架 | Qt 6.7.2 | 无 GUI（托盘 + 日志） | 不需要 | 保持零依赖 |
| 自动更新 | Sparkle | 无 | 不需要 | 手工分发阶段无意义 |
| Windows 解码呈现 | FFmpeg 软解 + Qt pixmap | MF 硬解 + D3D11 flip 交换链 | 不需要，且我们的路径更低延迟；Duet 的 Qt pixmap 路径反而落后 | 无 |
| IddCx 虚拟屏 | IddCx 1.2 + KMDF 总线，Windows 当 host | 无（Mac 侧 CGVirtualDisplay 承担） | 不需要（方向 B 暂缓） | 见专项评估 5 |

## 五、专项评估

### 1. 传输加密（mTLS 或应用层 E2E）
观察：Duet 是双层，直连 TCP 上 mTLS，中继场景再加应用层 PKI/PBKDF，让中继读不到明文（proto-deep §五）。
建议：当前目标是点对点雷电直连、单用户、链路物理私有，窃听面接近零，加密投入产出很低。列一个触发条件：一旦监听地址从 9922 放开到局域网或加中继，先补 TLS。最小路径用 Network.framework 的 NWProtocolTLS + 自签证书 pinning，两端各约 1 人日；应用层 AES-GCM 属于过度设计，不推荐现在做。结论：不需要，标记为触发式可选。

### 2. 帧统计反馈（与 0x07 呼应）
观察：Duet 用 8 段 checkpoint + Clock 域 + RTT，靠 dsts 包回传，host 据此调码率。
建议：0x07 已实现且方向与 Duet 同构，当前缺口在真机闭环验证（RESULT-adaptive-bitrate-v2 §三：Mac 旧二进制未含 0x07 解析，--feedback 仍关）。可选增强是补 RTT 单向时间戳与 send 段，便于把延迟拆到 capture/encode/send/decode/present 五段，与 Duet 报告对齐。结论：必须补的是验证，不是结构。

### 3. 自适应质量三档是否需要 Windows 侧配合
观察：Duet 的三档降档发生在 host 编码端（encode-deep §4），依据是 host 侧 RTT 采样与编码管线统计；Windows 侧只有 FrameStats 回传参与。
建议：不需要 Windows 新增配合。0x07 已经携带 winQueueMs 与 presentDrop，这正是 Windows 侧的全部职责。三档逻辑全部落在 Mac 的 setBitrate 路径，v2 的健康度控制律已覆盖等价语义。结论：不需要。

### 4. Windows 端是否换 FFmpeg
观察：Duet Windows 客户端是 FFmpeg 4.x 软解 + Qt QGraphicsView pixmap 上屏，未确认走 D3D11VA 硬解（win-static §二标未知）。
建议：不换。SecDisplay 的 MF 硬解 + D3D11 flip 交换链在 present 路径上优于 Duet 的 pixmap 路径，换 FFmpeg 等于降级并引入第三方依赖。结论：不需要。

### 5. IddCx 方向 B 投入产出
观察：Duet 用 IddCx 1.2 UMDF + KMDF 静态总线，服务 Windows 当 host 的虚拟显示器（win-deep §一）。
建议：当前目标 Mac 当 host，Windows 只是接收端窗口，IddCx 完全用不上。投入面大：UMDF 驱动开发 + 总线枚举 + 测试签名/WHQL + EDID 与模式管理，估 10 人日以上，还要处理驱动签名分发。唯一收益场景是未来把 Windows 当 host 给 Mac 投，与当前优先级冲突。结论：不需要，挂起至方向 B 立项。

## 六、优先级排序与理由

1. **0x07 真机闭环验证（必须，0 编码）**：自适应码率的价值全押在反馈环上，Mac 重编译后开 --feedback 跑 motionloader，确认降档、回退、静止回升三条路径。这是唯一阻塞项。
2. **Mac 端按需 ForceKeyFrame + GOP 对齐（可选，约 1 人日）**：丢包或降档后恢复画面质量依赖关键帧，配合静止 IDR 退避已有逻辑，改动小收益直接。
3. **帧统计补 RTT 与 send 段（可选，约 1 人日）**：延迟归因需要五段拆分，遥测仪表盘（latency_dashboard.py）直接受益。
4. **文本剪贴板（可选，约 1 人日）**：单用户副屏高频需求，Duet 也只做了 TEXT。
5. **SCK QueueDepth/MinimumFrameTime 微调（可选，0.5 人日）**：先实测 QD=3 与 5 的 p95 差异，有差异再改。
6. **加密（触发式）**：监听面扩大前不做。

明确不做：Windows 换 FFmpeg、IddCx 方向 B、AWDL/USB AOA/云中继、Qt、Sparkle、手势/注释/文件传输协议。

## 七、边界

- 全部 Duet 结论来自静态逆向报告，未运行 Duet（需账号登录），dmg 未挂载。
- 未复制 Duet 代码，未改 SecDisplay 任何源文件。
- 工作量均为粗估，按当前单人节奏。
