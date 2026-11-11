# RESULT（Mac）：Duet Display 4.0.526 host 侧静态分析（A-Mac-1/2/3）

> 对应任务：`research/TASK-mac-duet-analysis-2026-11-11.md`
> 执行端：Mac 侧
> 日期：2026-11-11
> 分析对象：官方 `DuetDisplay-4-0-526.dmg`，132,983,119 字节
> SHA256：`09c5bda30ca50caa1e3ec3d615f3fe6f5f5954f1693cd1cab3a5015c0e04b093`
> 方法：`hdiutil` 挂载 + `otool -L/-l` + `nm -u` + `strings -a`
> 证据等级：观察（二进制里直接可见）、推断（由观察组合得出）、未知（静态看不到）

## 零、与 3.20.3.0 的结构差异

先记一笔，避免用错版本：

| 版本 | 结构 |
|---|---|
| 3.20.3.0 | 核心拆在 `DuetScreenCapture` / `DuetVideo` / `DuetConnections` / `DuetRemoteDisplay` 等独立 framework，主二进制仅 9.4MB |
| 4.0.526 | 上述核心全部并入主二进制 `duet`（61MB），framework 目录只剩 Qt 与 Sparkle 等第三方库 |

所以 4.0.526 的符号要从主二进制取，3.20 的 framework 结论不能直接套用。

---

## 一、A-Mac-1 host 采集与编码参数

### 1.1 采集 API 与切换（观察）

主二进制同时导入两套采集接口：

- `CGDisplayStreamCreateWithDispatchQueue` / `Start` / `Stop`
- `CGDisplayStreamUpdateGetRects`
- `kCGDisplayStreamMinimumFrameTime` / `kCGDisplayStreamQueueDepth` / `kCGDisplayStreamShowCursor`
- `SCStream` / `SCStreamConfiguration` / `SCContentFilter` / `SCShareableContent`
- `SCStreamFrameInfoContentRect` / `ContentScale` / `ScaleFactor` / `Status`

链接方式：

- `CoreGraphics` 强链接
- `ScreenCaptureKit` **弱链接**（`LC_LOAD_WEAK_DYLIB`）

实现类（观察）：`Duet::Video::Duet_CGDuplicateDesktop::HandleFrameUpdate(CGDisplayStreamFrameStatus, size_t, IOSurfaceRef, CGDisplayStreamUpdate const*)`

专用队列（观察）：`com.duet.cgDisplayStreamCaptureQueue`

**结论（已由 `RESULT-duet-mac-encode-deep.md` 的反汇编更正）**：运行时优先用
ScreenCaptureKit，`CGDisplayStream` 是旧系统回退。判据在 `GetInstance` 里：
macOS ≥ 14.3 且 `SCStream` 类可用时走 SCK，否则回退 CGDisplayStream。
弱链接只说明部署目标是旧系统，不代表运行时优先用它。

### 1.2 队列与帧间隔（观察）

- 有 `setQueueDepth:`、`setMinimumFrameInterval:` 两个 setter
- 传送门签名 `startWithDisplayID:showsMouseCursor:width:height:minFrameTime:queueDepth:hideDuetApp:...`（3.20 版本可见，4.0 保留了对应参数）

**默认取值：未知**。字符串里没有直接数值，需要反汇编调用点或运行时读取。

### 1.3 VideoToolbox 属性（观察）

导入的属性键：

| 属性 | 状态 |
|---|---|
| `kVTCompressionPropertyKey_RealTime` | 有 |
| `kVTCompressionPropertyKey_AllowFrameReordering` | 有 |
| `kVTCompressionPropertyKey_MaxKeyFrameInterval` | 有 |
| `kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration` | 有 |
| `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality` | 有 |
| `kVTCompressionPropertyKey_AverageBitRate` | 有 |
| `kVTCompressionPropertyKey_DataRateLimits` | 有 |
| `kVTCompressionPropertyKey_ProfileLevel` | 有 |
| `kVTCompressionPropertyKey_ColorPrimaries` | 有 |
| `kVTCompressionPropertyKey_EncoderID` | 有 |
| `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` | 有 |
| `kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder` | 有 |

对应会话 API：`VTCompressionSessionCreate` / `EncodeFrame` / `CompleteFrames` / `PrepareToEncodeFrames` / `Invalidate`。

**推断**：实时模式、禁 B 帧重排、限制 GOP、速度优先、码率上下限、强制硬编，这六件套齐全，与 SecDisplay 当前配置方向一致。

### 1.4 自适应码率（观察 + 推断）

观察到的符号与属性：

- `averageLatency` / `averageLatencyChanged`
- `currentLatency` / `currentLatencyChanged`
- `connectionAverageLatency`（Qt 属性，int）
- `connectionCurrentLatency`（Qt 属性，int）
- `transmittedBitRateMbps` / `transmittedBitRateMbpsChanged`
- `videoBitRateOptionsMbps` / `videoBitRateMbps` / `bitRateMbps`
- `setVideoBitRateMbps`
- `SenderDefaultBitRateMbps`
- `VideoBitRateMbps`

**推断**：存在「延迟反馈 + 发送码率统计」的闭环，连接平均/当前延迟和实际发送码率都是可观测状态。基线文档提到的 `ApplyAdaptiveBitRateLimit` / `OneMinuteEncoderBitRate` 在 4.0.526 主二进制里没有再命中，可能已重命名或移入未导出的内部符号，**具体调节算法未知**。

### 1.5 分辨率上限（观察 + 未知）

- `DuetClientSettingsProto_ResolutionOption`（protobuf 枚举）
- `displayResolutionOptions` / `displayResolutionOptionsChanged`
- 字符串里出现 `4096`，与 H.264 编码宽度上限一致

**推断**：分辨率通过协议由客户端声明候选项，host 侧按编码器能力设上限。具体档位数值与默认值**未知**，需运行时读取客户端设置。

---

## 二、A-Mac-2 光标管道

### 2.1 取图（观察）

- `NSCursor`、`currentSystemCursor`
- `hotSpot`、`xHotspot`、`yHotspot`
- `cursorHotspotX`、`cursorHotspotY`
- `cursorImage`
- `CGDisplayHideCursor` / `CGDisplayShowCursor`
- `Duet_MacCursorHider`
- `hideCursor`
- 字符串 `GetCursorImage should never be called on a client`，说明取图只在 host 侧执行

**结论（观察）**：host 侧用 `NSCursor.currentSystemCursor` 拿当前系统光标，读它的图像、`hotSpot`、`xHotspot`/`yHotspot`，与基线文档一致。本地光标通过 `CGDisplayHideCursor` 隐藏、`CGDisplayShowCursor` 恢复。

### 2.2 光标消息（观察）

- `NewCursorImage`
- `NewCursorLocation`
- `NewCursorPosition`
- `hasCursorPosition`
- `cursorX`
- `HideCursorKMSRequest`（`DuetKMSProto.HideCursorKMSRequest`）

对照 3.20.3.0 的 Objective-C 方法名：

- `sendCursorImageToNetworkData:hotX:hotY:displayWidth:displayHeight:`
- `sendCursorLocationToNetworkNormalizedX:normalizedY:doNotDraw:`

**推断**：光标拆成两路。图像包携带位图、热点、显示尺寸；位置包携带归一化坐标和一个「不绘制」标志。`hasCursorPosition` 表示位置字段可选。

### 2.3 与视频的关系（推断）

`kCGDisplayStreamShowCursor` 可配置，配合 `CGDisplayHideCursor`，视频流可以不带光标。光标是独立通道，不与视频帧共用节奏。

**时序与频率：未知**，需要运行时抓包或日志。

---

## 三、A-Mac-3 协议与传输

### 3.1 消息（观察）

protobuf 描述符直接嵌在二进制里（`google/protobuf/descriptor.proto`、`.placeholder.proto` 等），可见的消息名：

- `NewVideoFrame`
- `NewCursorImage`
- `NewCursorLocation`
- `NewCursorPosition`
- `FirstVideoFrameReceived`
- `GotClosePacket`
- `DuetRDPProto` / `DuetRDPProto.RDPSessionMode`
- `DuetClientSettingsProto` / `ResolutionOption` / `DpiScalingOption`
- `DuetKMSProto.HideCursorKMSRequest`

**字段级定义：部分未知**。字符串只能确认 `cursorX`、`hasCursorPosition`、`videoBitRateOptionsMbps` 等少数名字；完整字段表需要解析 FileDescriptorProto 或抓包，本次未做。

### 3.2 传输通道（观察）

- AWDL：`AWDLToolManager`、`AWDLToolProtocol`、`AWDLUp` / `AWDLDown`、`com.kairos.awdltool.xpc`、`/Library/PrivilegedHelperTools/com.kairos.awdltool.xpc`
- WebSocket：`NSURLSessionWebSocketTask`、`Attempted to connect an active WebSocket client`
- 连接管理：`DuetRDPConnectionManager`

**推断**：控制/信令走 WebSocket，设备间直连可以走 AWDL；USB 路径在 3.20 里由 usbaapl/AOA 承担，4.0.526 未逐一确认。

### 3.3 帧封装（观察 + 未知）

3.20.3.0 里可见 `SimplePacketHeader = packetMagicNumber(4) + packetType(4) + packetLength(8)`，4.0.526 主二进制里未直接命中同名字符串，**是否沿用同一包头未知**。

视频载荷在 3.20 的字符串里可见 H.264 Annex B / HEVC Annex B 的能力协商标记（`supportsH264AnnexB`、`requiresH264AnnexB`、`supportsHEVCAnnexB`），4.0.526 未逐条确认。

### 3.4 加密（观察）

3.20.3.0 的 `DuetConnections` 里可见：

- `RDPPacketCrypto` / `MTLSPacketCrypto` / `PKIPacketCrypto`
- `DuetE2ECryptoHandshake` / `Direct` / `Proxy`
- `sendEncryptedKeyUsingE2EProtocol` / `sendEncryptedKeyUsingPBKDFDerivedKey`
- `'duet' found, using PKI key exchange protocol`

**推断**：端到端密钥交换加包级加密，具体用在哪一层（全通道还是仅信令）**未知**。

### 3.5 通道优先级（未知）

4.0.526 主二进制里没有命中 `channelPriority` 一类字符串。视频、光标、输入是否独立队列、谁优先，**静态看不到**，需要抓包或运行时观测。

---

## 四、与 SecDisplay 的对照

| 项 | Duet 4.0.526 | SecDisplay 现状 | 差距 |
|---|---|---|---|
| 采集 API | SCK 优先（macOS ≥14.3），CGDisplayStream 回退 | ScreenCaptureKit | 路线一致 |
| 队列控制 | 有 QueueDepth / MinimumFrameTime setter | 有 captureHz，队列深度未显式控制 | 可能需要补浅队列 |
| 编码 | RealTime + 禁重排 + GOP + 速度优先 + 硬编 + 码率上下限 | 基本对齐 | 差距不大 |
| 自适应码率 | 延迟反馈 + 发送码率统计 | 固定码率 | 明显缺口 |
| 分辨率档位 | 客户端声明 + host 上限 | 已有 sharp/balanced/smooth/fast | 接近 |
| 光标取图 | NSCursor.currentSystemCursor + hotSpot | 已有 0x05 图像 + 热点 | 已对齐 |
| 光标位置 | 归一化坐标 + doNotDraw | 0x03 + 归一化 | 已对齐 |
| 传输 | WebSocket + AWDL + USB | 雷电 TCP 9922 | 链路不同，延迟已够低 |
| 加密 | E2E + 包级 | 无 | 单机自用可不补 |

## 五、A-Mac-1/2/3 判据自查

- 参数表覆盖采集 API、QueueDepth、MinimumFrameTime、VT 属性、自适应码率、分辨率上限：**已覆盖，其中 QueueDepth/MinimumFrameTime 默认值与分辨率档位数值标为未知**
- 光标字段表与时序：**字段已列，时序未知**
- 消息表与通道优先级：**消息名已列，字段级定义与通道优先级部分未知**
- 每条标注证据等级：**已标注**

## 六、动态部分（D-1/D-2/D-3）状态

未执行，阻塞原因：

1. Duet 需要登录账号与订阅才能建立连接，当前未登录
2. 需要 macOS 屏幕录制与辅助功能权限
3. 需要 Windows 端同时在线跑同一运动负载

未伪造任何延迟、帧率、带宽数据。

## 七、下一步建议

1. 若要补齐 QueueDepth / MinimumFrameTime 默认值，用 REA 打开主二进制，定位 `setQueueDepth:` 与 `setMinimumFrameInterval:` 的调用点反汇编
2. 若要完整 protobuf 字段表，从二进制里提取 FileDescriptorProto 后用 `protoc --decode_raw` 还原
3. 自适应码率算法需要运行时抓包或对 `connectionAverageLatency` 做埋点，静态无法确认
