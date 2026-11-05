# 代码审查记录

对项目做了两轮独立审查，发现的阻断级问题全部修掉了。这里记录过程和结论，避免以后重复踩。

---

## 第一轮：全项目审查

审查范围：Mac 端 + Windows 端 + 文档一致性。

### 发现

| 级别 | 问题 | 状态 |
|---|---|---|
| 阻断 | Windows 呈现路径从未写入交换链后缓冲，必然黑屏 | 已修 |
| 阻断 | Mac 发 AVCC，Windows 端 MF 解码器要 Annex-B，未转换 | 已修 |
| 阻断 | 未处理 `MF_E_TRANSFORM_STREAM_CHANGE`，解码器永远无输出 | 已修 |
| 严重 | 编码时间戳 `currentCaptureTime` 跨线程无同步，且可能错帧 | 已修 |
| 严重 | `destroyAll()` 是空操作，信号退出时虚拟屏不清理 | 已修 |
| 严重 | 硬件解码未注入 `IMFDXGIDeviceManager`，零拷贝不成立 | 已修 |
| 一般 | `keyframeRequested` 只写不读，关键帧请求失效 | 已修 |
| 一般 | 文件头注释写 Annex-B，实际是 AVCC | 已修 |
| 一般 | `staticAdaptive` 配置项未实现却出现在注释里 | 已删 |
| 一般 | Windows 收包未校验最小长度 | 已修 |
| 一般 | `try! NWListener` 端口占用直接崩溃 | 已修 |
| 一般 | SIGINT handler 里做 async-signal-unsafe 操作 | 已修 |

### 已核实无问题的部分

- AVCC 参数集拼接（Mac 端）：顺序、长度前缀、大端字节序都正确
- 协议长度字段语义：两侧一致，Mac 发 `帧长+9`，Windows 按此收 body 并从偏移 9 取载荷
- BENCH-03 的延迟边界表述：明确写了"编码后到解码完成"，没有夸大
- README 除 `staticAdaptive` 外，其余声明与代码一致

---

## 第二轮：Windows 接收端重写后审查

第一轮发现的呈现和 DXGI 问题太深，逐处打补丁不如重写，所以整个 `SecDisplayReceiver.cpp` 重写了，再做一次专项审查。

### 发现

| 级别 | 问题 | 状态 |
|---|---|---|
| 编译 | `eAVEncH264VProfile_High` 缺 `codecapi.h` | 已修 |
| 编译 | `ID3D10Multithread` 头文件归属不确定 | 已改用 `ID3D11Multithread` |
| 编译 | `_countof` 需 `stdlib.h` | 已改 `ARRAYSIZE` |
| 运行 | 硬件 MFT 未解锁异步模式（缺 `MF_TRANSFORM_ASYNC_UNLOCK`），永远无输出 | 已修 |
| 运行 | FLIP_DISCARD 下缓存后缓冲指针会失效，隔帧黑屏 | 已改为每帧 `GetBuffer(0)` |
| 运行 | 软件解码回退路径拿不到 `IMF2DBuffer`，必然黑屏 | 已改 `MFCreateVideoSampleAllocatorEx` |
| 严重 | `Decode` 两处 IMFSample 泄漏 | 已修，统一出口 |
| 一般 | `SetMultithreadProtected` 返回值未检查 | 已修 |

### 核查通过的部分

- `DrainOutput` 的样本所有权：成功路径 `Detach`、MFT 自有样本转交、STREAM_CHANGE 与 NEED_MORE_INPUT 分支的守卫都正确，无 double release
- 协议解析、大端处理、时间戳字节序正确
- 线程模型：解码与呈现都在 recvThread，主线程只泵消息
- `Present(0, ALLOW_TEARING)` 组合正确，SyncInterval 必须为 0
- 资源释放顺序正确

---

## 仍未验证的部分

Windows 接收端**从未在 Windows 上编译或运行过**（开发机是 macOS，没有 MSVC）。以下依赖实机确认：

1. 能否编译通过（头文件、API 签名已在审查中核对，但没有编译器验证）
2. 硬件 MFT 是否接受当前的输入输出类型组合
3. NV12 纹理经 `VideoProcessorBlt` 到 BGRA 后缓冲的画面是否正确（色彩、全黑、绿屏）
4. 软件解码回退路径在具体驱动上的表现
5. 首帧需要多久出画（取决于接收端何时请求关键帧）

如果出问题，优先看启动日志：`解码器就绪`、`已注入 SPS`、`输出类型已重建`、`呈现器就绪` 这几行提示走到哪一步了。

---

## 当前验证状态

已在本机（macOS 27.2, M1 Pro）验证通过：

- 虚拟屏创建 / 保持 / 销毁：`vdtest` 全部通过，退出无残留
- 编码性能：2560x1600@60fps，0.078ms/帧
- 采集性能：有动画时 54.4fps
- 自环端到端延迟：中位 4.61ms（refcon 改动后重测）
- 发送端完整启动：建屏 → 抓屏 → 编码 → 监听 → 信号清理

未验证：

- Windows 端全部
- Mac ↔ Windows 真实联调
- 长时间稳定性
