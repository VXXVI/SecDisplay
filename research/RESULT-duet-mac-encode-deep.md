# Duet Display 4.0.526 Mac Host：采集与编码参数静态深挖

日期：2026-11-11
执行：逆向子代理（otool / objdump / nm / strings，纯静态，未运行 Duet）
关联：`research/REVERSE-DUET-4.0.526.md`（基线）、`research/PLAN-duet-analysis-2026-11-11.md`（A-Mac-1 工作包）
分析缓存：`/private/var/folders/8s/qd14vxd90v7c5xfjl6ls1nxw0000gp/T/opencode/duet/`（arm64/x86_64 slice、全量反汇编 full.asm、gotmap.txt，可复查）

---

## 1. 版本与输入

| 项 | 值 |
|---|---|
| 二进制 | `/Volumes/Duet Display/duet.app/Contents/MacOS/duet`，64,142,416 B，universal (x86_64 + arm64) |
| SHA256（整个 fat） | `0cb6b7b6fd4c8174…` |
| arm64 slice | 31,751,248 B，主要分析对象；x86_64 仅做抽查交叉验证 |
| 关键类 | `Duet::Video::Duet_CGDuplicateDesktop`（CGDisplayStream 路径）、`Duet::Video::Duet_SCKDuplicateDesktop`（ScreenCaptureKit 路径）、基类 `Duet::Video::Duet_DuplicateDesktop`、`Duet::Video::Encoder::Duet_VTEncoder`（+ `Duet_VTH264Encoder`）、`Duet::Framework::Duet_DesktopDuplicationManager` / `Duet_ApplicationEncoderPipeline` / `Duet_HostConnectionDelegate` / `Duet_RDPConnection` |

证据分级沿用基线文档：**观察**（反汇编直接可见）/ **推断**（组合得出）/ **未知**。
以下偏移如 `+0x40224` 均指 `this + 0x40000 + 0x224`（对象头部预留 256KB，两路径一致）。

---

## 2. 参数表

### 2.1 CGDisplayStream properties（`Duet_CGDuplicateDesktop`）

| 参数 | 取值 | 等级 | 证据位置 |
|---|---|---|---|
| `kCGDisplayStreamQueueDepth` | **5**（SInt32，4 个构造函数全部写 5；x86_64 同：`movl $0x5, 0x40224(%r15)`） | 观察 | ctor `Duet_CGDuplicateDesktop()` @0x10046c610（arm64）；`Initialize` @0x10046ccb4 读同字段入 CFNumber(SInt32) |
| `kCGDisplayStreamMinimumFrameTime` | **1.0 / targetFrameRate**（CGFloat，秒）；`SetTargetFrameRate` 未调用过（字段 0）时**整个键不设置** | 观察 | `Initialize` @0x10046cc68-ccb0：`1.0/w8` → CFNumber(CGFloat=13) |
| `kCGDisplayStreamShowCursor` | `kCFBooleanTrue/False`，取 `Initialize(w,h,bool)` 第 3 参 | 观察 | `Initialize` @0x10046cc14-cc38（GOT 0x3a0/0x3a8 = False/True） |
| pixelFormat | `'BGRA'`（0x42475241） | 观察 | `Initialize` @0x10046cd34 |
| 调用形式 | `CGDisplayStreamCreateWithDispatchQueue(display, w, h, 'BGRA', props, queue, handlerBlock)`，handler 为栈 block 直通 `HandleFrameUpdate`；队列为串行（attr=0），每实例一个 | 观察/推断 | @0x10046ccf0-cd44；queue 创建 @0x10046caac |

结论：父会话提到的 `setQueueDepth:` / `setMinimumFrameInterval:` 是 **SCStreamConfiguration 的 ObjC 选择器**（SCK 路径），CG 路径用 C 属性字典，两路取值一致（见 2.2）。

### 2.2 SCStreamConfiguration（`Duet_SCKDuplicateDesktop`）

| 参数 | 取值 | 等级 | 证据位置 |
|---|---|---|---|
| `queueDepth` | **5**（构造时从 16 字节常量 {5,0,0,2} @0x1017d75c0 装入 +0x40240，运行期无人改写） | 观察 | ctor @0x100477060；`Initialize` @0x1004775fc `setQueueDepth:` |
| `minimumFrameInterval` | `CMTimeMake(1, targetFrameRate)`；fps==0 时设 `kCMTimeZero`（交还系统默认） | 观察 | `Initialize` @0x1004775b0-5f8；`SetTargetFrameRate` block @0x100478688 |
| `showsCursor` | Initialize 第 3 参 bool | 观察 | @0x100477470 |
| `scalesToFit` | NO | 观察 | @0x100477610 |
| `captureResolution` | 1（macOS ≥14 才设，`__isPlatformVersionAtLeast(14,0,0)`） | 观察 | @0x100477518-538 |
| width/height | 逻辑像素 × scale factor（`fmul.2s`），0 则报错退出 | 观察 | @0x100477474-514 |
| colorSpaceName | `kCGColorSpaceSRGB` | 观察 | @0x100477444-454 |

### 2.3 VideoToolbox（`Duet_VTEncoder::Configure` @0x10047ab48 等）

| 参数 | 取值 | 等级 | 证据位置 |
|---|---|---|---|
| encoder spec | `RequireHardwareAcceleratedVideoEncoder = true` | 观察 | @0x10047accc-ace4 |
| pixel buffer attrs | `'BGRA'` + width/height + OpenGL/Metal 兼容 | 观察 | @0x10047ad64-ae14 |
| `RealTime` | **true**（kCFBooleanTrue） | 观察 | @0x10047b190-1a0 |
| `AllowFrameReordering` | **false**（kCFBooleanFalse） | 观察 | @0x10047b264-280 |
| `PrioritizeEncodingSpeedOverQuality` | **true，仅 HEVC（'hvc1'）才设置**；H.264 不设 | 观察 | @0x10047b1d8-200（codec=='hvc1' 分支） |
| `ProfileLevel`（H264 子类） | `kVTProfileLevel_H264_Baseline_AutoLevel` | 观察 | `Duet_VTH264Encoder::ConfigureCodecSpecificSettings` @0x10047cc80-9c |
| 色彩三键 | ColorPrimaries=`ITU_R_709_2`，TransferFunction=`sRGB`，YCbCrMatrix=`ITU_R_709_2`（像素 buffer 与 session 双份） | 观察 | @0x10047ae28-ae80、b038-b0ac |
| `MaxKeyFrameInterval` | SInt32 秒；**默认 10**（字段 0 → 10），可被 `SetKeyFrameIntervalSeconds` 覆盖 | 观察 | `ConfigureKeyFrameInterval` @0x10047b974-9b8 |
| `MaxKeyFrameIntervalDuration` | 同上值的 double 形式 | 观察 | @0x10047ba24 附近 |
| `AverageBitRate` | SInt32 bps = `bitRate × max(0.25, budget/100)`；逐帧重算，值未变则跳过；算出 0 → 设 0 | 观察 | `ApplyDataRateLimitsIfNeeded` @0x10047c264-2d8 |
| `DataRateLimits` | 4 元数组：`[1.1×ABR/8 字节 per 1s, 2.5×ABR/8 字节 per 2s]`（即持续 1.1×ABR、2 秒窗 1.25×ABR 的双窗口限速）；ABR==0 时设 NULL（解除限制） | 观察（除法魔数 0x28f5c28f5c28f5c3=÷25、常量 1.1/2.5/1.25 直接可读） | @0x10047c2e4-c3c0 |
| 按需关键帧 | `kVTEncodeFrameOptionKey_ForceKeyFrame`（导入符号）+ `InsertKeyFrame` | 观察 | 符号表 |

### 2.4 分辨率上限

| 项 | 取值 | 等级 | 证据位置 |
|---|---|---|---|
| H.264 编码宽度上限 | **4096**（`s_MAX_H264_FRAME_WIDTH`@0x1017db060 = 4096）；超过时按比例压缩：w=4096, h=4096×h/w | 观察 | `Configure` @0x10047abc8-ac28 |
| pipeline 编码宽度默认上限 | `s_MAXIMUM_ENCODING_RESOLUTION_WIDTH_DEFAULT` = **3840** | 观察 | 静态数据 @0x1016f1178 |
| HEVC 宽度上限 | `s_MAXIMUM_ENCODING_RESOLUTION_WIDTH_HEVC` = **8192** | 观察 | @0x1016f117c |
| 默认码率 | `s_DEFAULT_BIT_RATE` = **25,000,000 bps**（25 Mbps） | 观察 | @0x1016f1168 |
| 默认图像质量 | `s_DEFAULT_IMAGE_QUALITY` = **75**（管线层 clamp 到 [0,100]） | 观察 | @0x1016f92c0；`SetImageQuality` @0x1001ad17c |
| 发送缓冲 | `s_SEND_BUFFER_SIZE` = 8,388,608 (8MB) | 观察 | @0x1016f1170 |
| 帧率默认 | 解析链见 §3；字段默认 60（VTEncoder ctor @0x10047aab4） | 观察 | — |

---

## 3. 采集路径切换逻辑

工厂：`Duet_DuplicateDesktop::GetInstance(w,h,vdm)` @0x1004702b4：

1. 按 (width,height) 在红黑树缓存实例，命中直接复用。
2. 未命中 → 调 `Duet_SCKDuplicateDesktop::IsScreenCaptureKitAvailable()` @0x100476384：
   - 加载一个名字（走 0x10064074c，形如 `objc_getClass("SCStream")`）并判空；
   - AND 平台函数 vtable+0xd8 的 bool；
   - AND `[NSProcessInfo isOperatingSystemAtLeastVersion:]`，版本参数为 **14.3**（平台检查通过）或 13.0（未通过）——由 `cinc`/`csel` 直接构造。
3. 可用 → `new Duet_SCKDuplicateDesktop(w,h)`；否则 → `new Duet_CGDuplicateDesktop(w,h)`。

**这修正了基线文档的结论**：`REVERSE-DUET-4.0.526.md` 写"采集主力是 CGDisplayStream，SCK 只是可选后备"。实际选择逻辑相反——macOS ≥14.3 且类可用时**优先 SCK**，CGDisplayStream 是旧系统回退。（两份证据不矛盾：基线看的是"谁被导入"，本文看的是"谁被实例化"。）

- 运行期 SCK 失败回退：存在 `HandleStreamStoppedWithError` 与 `RequestFrameRefresh`，但**未观察到**失败后重建为 CG 路径的代码 → 未知（见 §5）。
- 帧率解析链（两路径共用）：`ResolvePreferredFrameRate` @0x1001dc9d8 → 默认 **36 fps**（连接类型字段 &~1 == 2 时 33）→ 客户端设置覆盖（vtable+0x508）→ 无效则 **60** → native-mirror 开启时取 `Duet_MonitorUtil::GetCurrentRefreshRate`（显示器真实刷新率）→ flag(0x2e6) 置位且 ≥31 时压到 **30**。随后 `ApplyFrameRateToCapture` → `DDM::SetFrameRate` → `SetTargetFrameRate`：CG 路径**整条流重建**（重新 Initialize），SCK 路径只重设 `minimumFrameInterval`。

---

## 4. 自适应码率机制

参与者：`Duet_RDPConnection`（采样）→ `Duet_HostConnectionDelegate`（分档与限值）→ `Duet_DesktopDuplicationManager::SetConnectionBitRateLimit` → `Duet_ApplicationEncoderPipeline::SetBitRate`（取 min）→ `ApplyDataRateLimitsIfNeeded` 落到 VT。

启用条件：feature 协商。`Duet_RDPConnection::SendFeatureList` @0x10017f914 写 `conn+0x2e6 = 1`（推断：连接建立时协商的特性开关）。

**采样**（`Duet_RDPConnection::CheckLatency` @0x10018a3e8 / `RecordLatency` @0x10018a420）：
- RTT = 当前时间 − 包内发送时间戳（ms），写入环缓冲（最近 11 个样本），维护 last / avg / max / min。
- `connectionAverageLatency`/`connectionCurrentLatency`/`transmittedBitRateMbps` 这三个名字是 Qt 侧 `ConnectionViewModel` 的 UI 属性；host 侧对应 RDPConnection 统计与 pipeline 的 `GetCurrentEncoderBitRate`/`GetOneMinuteEncoderBitRate`（float [0x158]/[0x15c]，Mbps）。

**降档触发**（RecordLatency 内，@0x10018a614-a738）：
- `avg ≥ last + 150 ms` 且通过稳定性闸门（avg−min ≤ 100、冷却 `(now-lastEvent)>>4 < 625` 则跳过 ≈10 秒、队列 ≤ 0x30000、计数 ≤ 150）→ 调 delegate vtable+992（= `AdjustBitRateDown` @0x1018e0778 槽）；
- 降档之间再垫 20 秒保持（w10=20000）；升档路径保持 2 秒（w10=2000）。

**分档调节**（`AdjustBitRateDown` @0x1001e53a4 / `AdjustBitRateUp` @0x1001e55f8）：
- 档位 conn+0x328（0..2）：降档 +1（内部防抖 10001 ms），升档 −1（防抖 625 ms）。
- `CalculateAdaptiveBitRate(level)` @0x1001e5148：

```
base     = conn+0x330（用户/连接码率，bps），否则 DDM::GetDefaultBitRate()（默认 25 Mbps，下限 1）
adaptive = base × percent[level] / 100        percent = {40%, 30%, 20%}   @0x1017086c8
floor    = min(base, 2 Mbps)                  绝对下限
cap      = min(base, {8M, 6M, 4M}[level])     分档硬上限                  @0x101708cbc
result   = min( max(floor, adaptive), cap )
```

- 未调节前的默认限值（`GetAdaptiveBitRateLimit` @0x1001e51e4）：`min(base, max(2 Mbps, 30%×base))`。
- 应用：`ApplyAdaptiveBitRateLimit` @0x1001dcbfc → `DDM::SetConnectionBitRateLimit(name, limit)`；`Pipeline::SetBitRate` 中 `effective = min(请求值, 各连接 limit)`（@0x1001acd70-78、`UpdateEffectiveBitRateLocked` @0x1001acdc0）。限值最终经 `ApplyDataRateLimitsIfNeeded` 变成上文的 AverageBitRate/DataRateLimits。

---

## 5. 明确未知项清单

1. SCK 流运行期出错后是否回退 CG 路径——`HandleStreamStoppedWithError` 的处理逻辑未展开。
2. `Configure(w, h, bitRate, arg4)` 中 arg4（进入 ABR 公式的 budget/100）的确切语义与逐帧来源（怀疑是"本帧编码时间预算百分比"，Encode 第三参），仅推断。
3. `IsScreenCaptureKitAvailable` 里平台函数 vtable+0xd8 的具体功能（能力探测？VM 判定？）。
4. x86_64 slice 未全量复核（抽查 QueueDepth=5 一致）；两架构同源，差异风险低。
5. 实测码率 [0x158]/[0x15c] 的平滑算法（EncodeCallback 内，未展开）。
6. CG 路径 dispatch queue 创建包装函数 0x100644b14 的精确语义（attr=0 推断为串行）。
7. SCK 常量 {5,0,0,2} 的后两个 0 与字段 0x24c=2 的含义。
8. 档位表之外的"用户手动限速"来源 conn+0x330 的写入路径（设置 UI 或对端协商）。

---

## 6. 与 SecDisplay 的落点建议

| # | 建议 | 改动量 | 风险 |
|---|---|---|---|
| 1 | CGDisplayStream properties 补 `QueueDepth=5`、`MinimumFrameTime=1/fps`（fps 未定则不设键）、`ShowCursor` 显式设置，pixelFormat 定 `'BGRA'` | 小（一个字典构造，~20 行） | 低：参数 OS 有钳制，最坏是无效 |
| 2 | 采集路径采用"SCK 优先 + 版本闸 14.3 + 类存在性检查，CG 回退"的顺序，并修正 `REVERSE-DUET-4.0.526.md` §总体架构的表述 | 小（工厂一处）+ 文档一段 | 低 |
| 3 | VT 参数组照抄：RealTime=true、AllowFrameReordering=false、PrioritizeEncodingSpeedOverQuality=true（仅 HEVC）、H264 Baseline AutoLevel、709/sRGB 色彩三键 | 小 | 低 |
| 4 | 码率控制：`ABR = target × max(0.25, budget/100)` + 双窗口 `DataRateLimits [1.1×ABR/8 / 1s, 2.5×ABR/8 / 2s]`，target==0 时显式清空两键；逐帧重算并去重 | 中（BENCH-05 的 rate control 直接对标） | 中：ABR 过小时 VT 可能拒设 DataRateLimits，需保留 Duet 的"0 → 清空"分支 |
| 5 | 自适应限速状态机：3 档 {40%,8M} {30%,6M} {20%,4M}、2 Mbps 地板、升档防抖 625 ms / 降档 10 s、触发条件 avg≥last+150 ms 且 avg−min≤100 | 中（独立小模块） | 中：阈值依赖 RTT 采样质量，建议先照抄再按 `tools/EncLatency.swift` 实测校准 |
| 6 | GOP 默认 10 s + 按需 ForceKeyFrame；`MaxKeyFrameIntervalDuration` 同步设置 | 小 | 低 |
| 7 | 分辨率上限：H264 4096（超宽按比例压）、默认管线 3840、HEVC 8192；默认码率 25 Mbps、默认质量 75 | 小（常量） | 低 |
| 8 | native-mirror 模式帧率取显示器真实刷新率（GetCurrentRefreshRate）而非固定 60 | 小 | 低：需处理刷新率读取失败回退 60 |
