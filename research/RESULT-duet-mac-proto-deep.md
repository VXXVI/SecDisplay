# RESULT：Duet Display 4.0.526 (Mac) protobuf 字段表与传输封装还原

> 任务：`research/TASK-mac-duet-analysis-2026-11-11.md` 深挖项
> 对象：`/Volumes/Duet Display/duet.app/Contents/MacOS/duet`（64,142,416 字节 universal）
> 方法：lipo 抽取单架构 + Python 手工解析 FileDescriptorProto + nm/otool/objdump 静态反汇编
> 日期：2026-11-11
> 证据分级：**观察**（字节码/符号直接可见）、**推断**（由多处观察组合）、**未知**

## 一、输入与版本

- 分析在 arm64 slice（31,751,248 字节）上提取描述符，x86_64 slice（32,363,120 字节）上做反汇编，两 slice 数据段一致。
- 8 个 proto 文件的 `FileDescriptorProto` 序列化 blob 全部定位（arm64 文件偏移）：

| proto | 偏移 | 大小 | 包名 |
|---|---|---|---|
| Annotation.proto | 0x17dda38 | 629B | DuetAnnotationProto |
| ClientSettings.proto | 0x17dde64 | 471B | （无包名） |
| Clipboard.proto | 0x17de1f4 | 463B | DuetClipboardProto |
| FileTransfer.proto | 0x17de754 | 2218B | DuetFileTransferProto |
| FrameStats.proto | 0x17df3c4 | 596B | DuetFrameStatsProto |
| Input.proto | 0x17df8e4 | 3869B | DuetInputProto |
| KMS.proto | 0x17e0b80 | 366B | DuetKMSProto |
| RDP.proto | 0x17e0e38 | 437B | DuetRDPProto |

全部 proto3。工具脚本：`scan_fdp.py`（无 protoc，纯 Python wire-format 解析），dump 备份 `fdp_dump.txt`（同目录 tmp）。

## 二、消息字段表

### 2.1 Input.proto（DuetInputProto，proto3）

**Duet_InputEvent**（oneof Duet_InputType）
| # | 名 | 类型 |
|---|---|---|
| 1 | KeyboardInput | Duet_KeyboardInput |
| 2 | MouseInput | Duet_MouseInput |
| 3 | GestureInput | Duet_GestureInput |

**Duet_InputFrame**：`1 repeated InputEvents`（批量输入的容器，观察：SendMouseInputFrame/SendKeyboardInputFrame 每次 append 一条）

**Duet_KeyboardInput**
| # | 名 | 类型 |
|---|---|---|
| 1 | KeyCode | int32 |
| 2 | KeyState | enum Duet_KeyState {KEY_PRESSED=0, KEY_RELEASED=1} |
| 3 | IsRepeat | bool |
| 4 | UnicodeChar | uint32 |
| 5 | Modifiers | repeated enum Duet_KeyModifier {SHIFT=0,CONTROL=1,ALT=2,META=3,CAPSLOCK=4,NUMLOCK=5,SCROLLLOCK=6,FUNCTIONKEY=7} |
| 6 | ModifierSides | repeated Duet_KeyModifierSide{1 Modifier, 2 Side(SIDE_UNKNOWN/LEFT/RIGHT)} |
| 7 | PhysicalKeyCode | uint32 (optional-oneof) |
| 8 | SystemKey | enum {UNSPECIFIED,MISSION_CONTROL,LAUNCHPAD,SPOTLIGHT,DICTATION,DO_NOT_DISTURB} |

**Duet_MouseInput**
| # | 名 | 类型 |
|---|---|---|
| 1 | XPercent | float |
| 2 | YPercent | float |
| 3 | Button | enum {NONE,LEFT,RIGHT,MIDDLE,X1,X2,EXTRA_1..4} |
| 4 | ButtonState | enum {PRESSED,RELEASED,DOUBLE_CLICK} |
| 5 | ScrollDirection | enum {UP,DOWN,LEFT,RIGHT} |
| 6 | ScrollAmount | int32 |
| 7 | Modifiers | repeated Duet_KeyModifier |
| 8 | DeltaX | float (optional-oneof) |
| 9 | DeltaY | float (optional-oneof) |

**Duet_GestureInput**（oneof payload）
| # | 名 | 类型 |
|---|---|---|
| 1 | X | double |
| 2 | Y | double |
| 3 | Scroll | ScrollData{1 DeltaX db, 2 DeltaY db, 3 DeltaUnit(UNIT_UNSPECIFIED/LOGICAL_PIXELS/LINES), 4 State, 5 Momentum} |
| 4 | Pinch | PinchData{1 Scale db, 2 State} |
| 5 | Rotation | RotationData{1 Degrees db, 2 State} |
| 6 | Native | PlatformNativeData{1 Encoding(FORMAT_UNSPECIFIED/MACOS_CGEVENT_DATA), 2 Data bytes} |
| 7 | Modifiers | repeated Duet_KeyModifier |

Phase 枚举（Gesture/共用）：NONE/BEGAN/CHANGED/ENDED/CANCELLED/MAY_BEGIN。
另有 Duet_PhysicalKeyMapping{1 SourcePhysicalKeyCode, 2 TargetPhysicalKeyCode}、Duet_InputConfiguration{1 KeyboardInputMode(CHARACTER/PHYSICAL), 2 ModifierKeyMappings}。

### 2.2 FrameStats.proto（DuetFrameStatsProto）

**Duet_FrameStats**
| # | 名 | 类型 |
|---|---|---|
| 1 | FrameId | uint64 |
| 2 | Checkpoints | repeated Duet_FrameCheckpoint |
| 3 | RTT | int64 |

Duet_FrameCheckpoint{1 Label, 2 Timestamp int64, 3 Clock(S sender/R receiver)}；
Duet_FrameLabel 枚举：CAPTURED=1, ENCODING_START=2, ENCODING_END=3, SENT=4, RECEIVED=5, DECODING_START=6, DECODING_END=7, PRESENTED=8。
（观察：这正是全链路延迟打点结构，SecDisplay 的 FrameStats 设计与它同构。）

### 2.3 ClientSettings.proto（无包名）

**DuetClientSettingsProto**
| # | 名 | 类型 |
|---|---|---|
| 1 | scaling_options | repeated DpiScalingOption{1 scale_value int32, 2 is_selected, 3 is_recommended} |
| 2 | resolution_options | repeated ResolutionOption{1 height, 2 width, 3 is_selected, 4 is_recommended} |
| 3 | is_mirrored | bool (optional-oneof) |
| 4 | mirrored_screen | int32 (optional-oneof) |

（观察：分辨率与缩放走这条；**没有码率字段**，码率在编码管线本地配置，不走 ClientSettings。）

### 2.4 Clipboard.proto（DuetClipboardProto）

| 消息 | 字段 |
|---|---|
| DuetClipboardData | 1 data_type enum{TEXT=0}, 2 data bytes |
| DuetSupportedClipboardDataTypesRequest / Response | 1 repeated data_type |
| DuetDisableClipboardData / DuetSupportedClipboardReinitlaizeTypesRequest | 空体 |

### 2.5 FileTransfer.proto（DuetFileTransferProto，依赖 timestamp.proto）

| 消息 | 字段（均 proto3 optional/repeated） |
|---|---|
| TransferId | 1 source_device_id string, 2 source_file_id int64 |
| DirectoryContentsRequest | 1 path |
| DirectoryContentsResponse | 1 path, 2 status, 3 files repeated FileMetadata{name,size_bytes,attributes,last_modified Timestamp}, 4 remote_device_id |
| DeleteFileRequest/Response | path,is_folder / path,status |
| DownloadFileRequest | transfer_id, max_bitrate, requested_path, destination_dir |
| DownloadFileResponse | transfer_id, status, checksum, size_bytes, attributes |
| UploadFileRequest | transfer_id, destination_path, checksum, size_bytes, attributes, original_dir |
| UploadFileResponse | transfer_id, status, max_bitrate |
| FileDataRequest | transfer_id, offset, data_size |
| FileDataResponse | transfer_id, status, offset, data bytes |
| StateChangeRequest/Response | transfer_id,state,error_code / transfer_id,status |

枚举：TransferState{QUEUED,ACTIVE,PAUSED_BY_USER,PAUSED_OFFLINE,CANCELLED_BY_USER,FAILED,FINISHED}；ResponseStatus{ERROR_UNKNOWN,SUCCESS,ERROR_BAD_PATH,ERROR_INVALID_ID,ERROR_INVALID_STATE_FT,ERROR_NO_FILE_ACCESS}。

### 2.6 KMS.proto（DuetKMSProto）

| 消息 | 字段 |
|---|---|
| StartKMSSession | 1 connectionID int32 |
| StartKMSSessionResponse | 1 monitorID rep int32, 2 left, 3 right, 4 top, 5 bottom, 6 displayName rep string（**6 条平行数组**，按索引对齐） |
| HideCursorKMSRequest | 1 hideCursor bool |
| KMSInputState | 1 captureInput, 2 cursorVisible, 3 hasCursorPosition, 4 cursorX int32, 5 cursorY int32 |

### 2.7 RDP.proto（DuetRDPProto）

| 消息 | 字段 |
|---|---|
| RDPSessionStart | 1 mode enum RDPSessionMode{UNKNOWN,MIRROR,EXTEND,KMS,FILE_TRANSFER} |
| Monitor | 1 id uint32, 2 left, 3 top, 4 right, 5 bottom int32, 6 name string |
| MonitorTopology | 1 version uint32, 2 monitors repeated Monitor |

### 2.8 Annotation.proto（DuetAnnotationProto）

| 消息 | 字段 |
|---|---|
| Point | 1 x, 2 y, 3 pressure (double) |
| StrokeStyle | 1 color uint32, 2 width double |
| Stroke | 1 display_id, 2 id uint64, 3 phase, 4 style, 5 points repeated Point |
| Erase | 1 display_id, 2 id, 3 phase, 4 width, 5 points |
| Command | 1 display_id |
| UndoRedoState | 1 display_id, 2 can_undo, 3 can_redo |

Phase{BEGIN=0,UPDATE=1,END=2,CANCEL=3}。

### 2.9 关于 NewVideoFrame 等"消息名"的更正（观察）

`NewVideoFrame`、`NewCursorImage`、`NewCursorLocation`、`NewCursorPosition`、`FirstVideoFrameReceived`、`GotClosePacket` **不是 protobuf 消息**，是 `Duet::RMM::Duet_RMMDesktopViewer` / `Duet_VideoGraphicsScene`（Qt 信号，签名如 `NewVideoFrame(std::shared_ptr<Duet::Video::Duet_Frame>)`、`NewCursorLocation(float,float,bool)`、`NewCursorImage(QPixmap const&,int,int,int,int)`）和 `Duet::Framework::Duet_RDPClient` 的 Qt 信号 `GotClosePacket()`。线上真正传输的视频/光标走 32 字节 BasePacket + 裸载荷（见下节），输入走 Input.proto。

## 三、包格式与分片

### 3.1 SimplePacketHeader 已废弃（观察）

3.20.3.0 的 `magic(4)+type(4)+len(8)` 在 4.0.526 中**无任何符号与字符串残留**（nm/strings 均无 SimplePacket/packetMagic/packetType）。取而代之的是三层信封（观察：`AllocateRDPPacketBuffer` 的三次 memcpy_s，16+16+32）：

```
偏移   大小  内容
0x00   16B  DuetPacketEnvelope        {BE32 version=2, BE32 0x18(=24), BE64 unixTimeMs}   <- 语义推断
0x10   16B  DuetPacketEnvelopeHeader  {BE32 size, BE32 size, BE32 seq, BE32 0}
0x20   32B  DuetRDPBasePacket         见 3.2
0x40   N B  payload（protobuf 序列化数据 / 视频帧头+编码数据 / 裸结构）
总长 = N + 0x40
```

EnvelopeHeader 实测（两处独立反汇编一致）：`hdr[0]=hdr[4]=BE32(payloadLen+0x20)`，`hdr[8]=BE32(seq)`（连接级原子自增计数器，`lock xadd` 于对象 +0x2e8），`hdr[12]=0`。即 size 字段统计"BasePacket+payload"整段。

### 3.2 DuetRDPBasePacket（观察，反汇编 ConstructRDPBasePacket + BuffertoRDPBasePacket）

```
0x00 char[4]  magic "drds"                 （s_RDP_BASE_PACKET_MAGIC_CODE = 0x64726473）
0x04 u32be    version = 2                  （s_RDP_BASE_PACKET_VERSION = 2）
0x08 u32be    tag1（FourCC 主类型）
0x0C u32be    tag2（FourCC 子类型）
0x10 u32be    参数（displayId / 请求 id 等）
0x14 u32be    时间戳 ms（Duet_TimeUtil::MillisecondsNow）
0x18 u64be    payload 长度
```

另 `s_RDP_REMOTE_PROTOCOL_VERSION = 2`（观察）。

### 3.3 FourCC 类型表（观察：processPacket 分发 + 发送端 mov 常量；语义标注者除注明外为推断）

主类型 tag1 → 处理：
- `dsps` 显示流族 → 二级分发（ClientConnection::ProcessDisplayStreamPacket）
- `inpt` 输入（Duet_InputFrame protobuf）
- `clip` / `cltk` 剪贴板数据 / 剪贴板 token
- `dann` 注释（有 ≤0x10000 长度校验，观察）
- `dflt` 特性列表；`kmsa` KMS 会话；`lstd` 显示器列表
- `ftpl` / `ftrt` / `dtpt` / `dsdt` 文件传输族
- `dstt` 设置族（二级 dscr/dscp/dscm；另见 dsro/dsrp/dsrq）
- `drmm` / `ddet` / `ddmt` / `dret` / `tmet` / `udpn`（镜像模式管理 / extend / mirror / 返回 / timing / UDP 协商）

`dsps` 下的二级 tag2（观察自 ProcessDisplayStreamPacket 的 cmp 链与发送端配对）：
- `dsfr` 视频帧（SendVideoData 实测配对 dsps+dsfr）
- `dscl` 光标位置（SendCursorLocationUpdate 实测）
- `dsci` 光标图像（SendCursorImageUpdate 实测）
- `dsts` timing 同步（FrameStats/RTT）
- `dsfq` 特性查询；`dstr` 流请求/控制；`dstp` 停流

### 3.4 视频帧载荷（观察，Duet_RDPHostConnection::SendVideoData 内联构造）

`dsps+dsfr` 帧包 payload = 0x50(80B) 帧头 + 编码数据：
```
[0x00] u64be frameId（Duet_Frame 首字段）
[0x08] u32be 2
[0x0C] u32be 连接对象+0x2dc 字段（displayId/streamId，推断）
[0x10] u32be 0
[0x14] u32be 帧宽（Duet_Frame+0x8，推断）
[0x18] u32be 帧高（Duet_Frame+0xc，推断）
[0x1C] u64be frame->GetStartTime()
[0x24] u32 宽（主机序原样副本）
[0x28] u32 高（主机序原样副本）
[0x2C] u32be DuetRDPDisplayStreamType（H264/H265/JPEG 枚举值）
[0x38] u64be dataLen
[0x40..0x50] 未逐字节确认（推测 flags/pts）
```
`AllocateDuetRDPDisplayStreamPacket`（通用构造器）用 0x38(56B) 头，字段序 {1, i1, 0, i2, i3, u64, i2raw, i3raw, streamType, 0, dataLen}，两构造器并存。**未见分片机制**：一帧一包，长度字段 8 字节足够；TCP 分段交给内核。`DuetRDPDisplayStreamType` 枚举成员值未逐一提取（未知）。

## 四、通道路径与优先级

- **单连接多路复用**（观察）：视频、光标、输入、剪贴板、文件、注释全部走同一条 RDP 连接，靠 tag1/tag2 区分；没有按消息类的独立 socket。收发各一个队列：`Duet_Queue<DuetRDPPacket>`（收，PacketProcessingThread）、`Duet_Queue<shared_ptr<Duet_SendTCPData>>`（发）。DuetRDPPacket 载荷迭代器在对象 +0x20/+0x28（观察）。
- 传输底座（观察）：`Duet_TCPSocket` / `Duet_SSLTCPSocket`（直连 TCP/TLS）、`DuetWebSocketClientAppleNative`（NSURLSessionWebSocketTask）与 QWebSocket（云中继）、`AWDLToolManager`（AWDLUp/AWDLDown 拉起 awdl0 接口，P2P 直连场景）、`Duet_DirectConnection`/`Duet_DirectProtocol`（USB/有线直连，TryPromoteToWired）。
- `udpn` tag + `SendUDPInfo` + `InitConnection(int, sockaddr_in, bool)`（观察）：存在 UDP 辅助通道协商，推测用于直连场景的视频流旁路（推断，未确认）。
- 时延与拥塞（观察）：`LagCheckThread`、`CheckLatency`、timing 包（dsts）+ Duet_FrameStats 检查点打点；`BeginProxyVideoBacklog`/`CompleteProxyVideoBacklogRecovery`（中继断线积压恢复）；接收端 `PresentLatestFrame` 只保留最新帧（丢帧策略=保最新弃旧）；"Decode Presentation Dropped Frames" 遥测计数。**线上没有显式优先级字段**（未知）；优先级体现为队列消费顺序与编码端实时参数（RealTime/禁重排/限 GOP）。

## 五、加密层次

- **传输层 TLS**（观察）：`Duet_SSLTCPSocket` 静态链接 OpenSSL，含 `InitClientmTLS`/`InitHostmTLS`、m_SSLClientContext/m_SSLHostContext、缓存的 client/host CA 证书与密钥 → 直连 TCP 上是**双向证书 mTLS**。WebSocket 通道 TLS 由 wss/NSURLSession 承担。
- **应用层 E2E**（观察）：`Duet_RDPAppCrypto` + `Duet_RDPCryptoUtil` + `Duet_RDPHandshakePKI`，`DuetRDPEncryptionMode` 两模式：
  - PKI 模式：PrepareClientInitialHandshakePKI / PrepareHostInitialHandshakePKI / HandleIncomingInitialHandshake（连接建立后的应用层握手），之后 `EncryptWithPKIHeader` / `DecryptPKI` / `WriteEncryptionHeader` 做包级加密；
  - PBKDF 模式：`SetPBKDFSecret(vector<uchar>)` 预共享密钥派生（PrepareClientInitialHandshakePBKDF 等成套符号）。
  - UI 字符串直接写明 `connectionEncryption: "AES256 (PKI)"`（观察）；OpenSSL 内嵌 AES-CBC/GCM/ChaCha20-Poly1305/RSA/ECDH 全套代码（观察，静态库常规体积）。
- **层次划分（推断）**：TLS/mTLS 只护直连 socket；应用层 PKI/PBKDF 加密在 RDP 包内部完成，因此走云中继（WebSocket）时中继服务器看不到明文帧。握手状态机 `Duet_RDPHandshakeEvent` + `StepClient`/`StepHost`（观察）。

## 六、未知项清单

1. Envelope 16 字节的完整语义（仅观测到 {2, 24, unixMs} 三个常量）。
2. 视频帧头 [0x08]=2、[0x0C] 连接字段、[0x40..0x50] 16 字节的具体含义；`DuetRDPDisplayStreamType`/`DuetRDPAudioEncoder`/`DuetRDPAudioBitDepth`/`DuetTouchAction`/`DuetButtonType` 枚举成员值。
3. 各 tag 的精确英文释义（dsfr/dscl/dsci/dsts/dsfq/dstr/dstp 等按行为定名，属强推断）。
4. >64KB 消息是否分片（仅注释消息观察到 0x10000 上限）。
5. UDP 通道是否承载视频、还是仅打洞/探测。
6. KMS/会话密钥协商的具体算法参数（RSA 裸指数、ECDH 曲线、HKDF 与否）。
7. 输入 tag 对（inpt + 哪个 tag2）与优先级调度细节。

## 七、对 SecDisplay 的落点建议

1. **包格式对齐成本极低**：BasePacket 是 3 个整型字段 + 固定 magic/version，可原样实现（magic "drds"、version 2、双 FourCC、长度、时间戳）。改动量：封包/解包各 ~100 行。
2. **值得补的字段**：
   - Duet_FrameStats 的 8 段 Checkpoint（CAPTURED→PRESENTED）+ Clock 域：我们的 BENCH 系列正好缺统一的线上打点结构，照抄即可对齐；
   - Duet_InputFrame 的 repeated 批量输入 + GestureInput 的 Momentum/Phase 状态机：我们 FIX-02 input 与 MOTION-WINDOW 可直接受益；
   - ClientSettings 的 is_selected/is_recommended 双标记：分辨率协商 UI 语义比我们现在的单选干净；
   - DuetClipboardDataType 目前只有 TEXT=0，说明对手也只做了文本剪贴板，我们对齐 TEXT 即可，不必上图像。
3. **设计取舍**：光标位置/图像走视频通道同流（dsps 二级 tag）而非独立 socket，证明单连接 + tag 多路复用足够低延迟；SecDisplay 无需为光标开独立通道。投屏丢帧"保最新"策略与 PresentLatestFrame 一致。
4. **加密**：对手是"mTLS 直连 + 应用层 PKI/PBKDF 双层"。SecDisplay 若只做局域网可信场景，mTLS 单层够用；若走中继，必须补应用层 E2E，否则中继可读帧。
5. **注意坑**：KMS StartKMSSessionResponse 用 6 条平行 repeated 数组而不是子消息，解析时必须按索引对齐；帧头里有主机序字段混在大端字段后（0x24/0x28 原样副本），自定义协议不要模仿，但解析 Duet 抓包时要留意。
