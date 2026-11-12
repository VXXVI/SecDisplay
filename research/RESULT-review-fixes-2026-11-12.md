# RESULT：审查问题修复（2026-11-12）

> 对应审查：`research/REVIEW-2026-11-12.md`
> 执行提交号：`a7e7ca7`
> 日期：2026-11-12
> CI：`build-windows` / `build-mac` / `telemetry-consistency` 全绿

## 一、已修复

| 级别 | 问题 | 修复 |
|---|---|---|
| P1 | `RateController` 把编码延迟当主信号，45fps 档 82→15 下滑 | v2 改为 `encodeGuard > 1.5` 才参与，并加降档试探/回退与 60 秒冷却 |
| P1 | 0x07 反馈已解析但控制律不消费 | v2 加入 `winQueueLoad = winQueueMs/15` 与 `presentDrop` 丢帧项 |
| P1 | `--pace` 标称一帧，实际队列上限 3 | 启动日志与文档改为「1~3 帧」，代码上限保持 3，避免更多丢帧 |
| P1 | `SetSourceSize` 后 `inViewCache_` 未失效 | `Presenter::CreateProcessor` 重建枚举器时 `inViewCache_.clear()` |
| P1 | 光标 50ms 时间过滤 + 250ms 门控可能活锁 | 改为「时间接近且落点等于上次 SetCursorPos 目标点」才过滤；真实移动一定刷新 `g_lastLocalInputMs` |
| P1 | 没有 `SO_SNDTIMEO`，send 可能永久阻塞 | socket 增加 500ms 发送超时，退出不再卡 `inputThread.join()` |
| P2 | `DrainOutput` 三个提前返回泄漏 `buffer.pEvents` | 加 `releaseEvents()`，所有出口统一释放 |
| P2 | `Decoder::Init` 失败后 `g_sock` 悬空 | 关闭前 `if (g_sock == sock) g_sock = INVALID_SOCKET` |
| P2 | pace 模式下 latest 被新帧取代记成 `dropped` | pace 开启时记 `paced`，避免 Mac 误判拥塞 |
| P2 | 高精度滚轮同窗口覆盖丢格 | `g_pendingWheel` 改为累加并夹紧到 int16 |
| P2 | `s_lastPresentMs` 跨连接不重置 | 改为全局 `g_lastPresentMs`，`ResetPresentRing` 时复位 |
| P2 | 静止桌面每 2 秒请求一次 IDR | 第一次立即请求，之后每 5 轮（约 10 秒）一次 |
| P2 | Mac 新连接不清 `ctrlBuf` | 新连接建立时 `ctrlBuf.removeAll()` |
| P2 | `idleRounds` 在 guard 提前返回时不清零 | 所有提前返回路径重置；静止时若在途≥2或有丢帧则不回升 |
| P2 | `setBitrate` 只检查 DataRateLimits | `AverageBitRate` 也检查并记录失败 |
| P2 | `ExpectedFrameRate` 固定 60 | `Encoder` 接收 `captureHz`，按实际档位设置 |
| P2 | 单帧丢帧即判 1.5 重度拥塞 | `presentDrop + droppedDelta >= 2` 才计入 `dropLoad` |

## 二、暂缓项（记录原因）

| 问题 | 原因 |
|---|---|
| `sent` / `sentBytes` / `inFlight` / `dropped` / `cap.captured` / `encLatSum` 跨线程读写 | 需要统一计数锁或串行队列，改动面大；当前统计只用于观测与慢速控制，先记录 |
| `InputInjector` 断连不释放按下的按钮 | 需要在连接断开路径注入全释放，涉及 Sender 与 Injector 的耦合 |
| `SetInputTypeFromParamSets` 用命令行宽高而非 SPS | 需要解析 SPS，切档场景再处理 |
| `g_refreshHz` 只在启动时取一次 | 多显示器不同刷新率时需监听 `WM_DISPLAYCHANGE` |
| 0x07 无版本协商 | `--feedback` 默认关闭已规避；等两端都稳定后再加能力协商 |
| 静止判定仍用 `d == lastDecoded` | 已加 IDR 退避；更深层的字节/光标判定留到有真机数据时再做 |

## 三、验证

- Windows 双工具链：MSVC / MinGW 全部编译成功。
- CI `a7e7ca7`：`build-windows`、`build-mac`、`telemetry-consistency` 全部 success。
- 接收端已重启，PID 14540，2240x1400 硬解，`解码失败 0`。
- 60 分钟 soak 已启动（PID 18360，日志 `logs/soak-2026-11-12.log`），
  起始内存 158.4MB、句柄 482、线程 19。

## 四、仍需真机

- 光标四项交互验收（W3/W4）需要用户或 Mac 光标配合。
- `--feedback` 闭环需要 Mac 重建并重启含 0x07 解析的二进制。
- 自适应码率 v2 的真实降档/回退行为需要 motionloader 负载。
