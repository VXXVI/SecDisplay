# Duet 分析阶段汇总（2026-11-11）

> 状态：静态阶段基本完成，动态阶段阻塞
> 输入：`research/RESULT-duet-mac-static.md`（Mac 4.0.526）、`research/RESULT-duet-win-static.md`（Windows 4.0.479）
> 版本差异：Mac 侧分析的是 4.0.526，Windows 本机安装的是 4.0.479，结论需按版本理解。
> 证据等级沿用两份 RESULT 的观察 / 推断 / 未知。

## 一、已经回答的

### Mac host（方向 A）

- 采集主力是 `CGDisplayStream`，ScreenCaptureKit 弱链接作后备。
- 有 `setQueueDepth:` / `setMinimumFrameInterval:`，默认值未知。
- VideoToolbox 六件套齐全：RealTime、禁 B 帧重排、GOP、速度优先、硬编、码率上下限。
- 光标：`NSCursor.currentSystemCursor` + `hotSpot`，`CGDisplayHideCursor` 隐藏本地光标，
  图像与位置分两路消息，位置带 `doNotDraw` 标志。
- 协议：WebSocket / AWDL / USB，protobuf 消息名已列，字段级定义部分未知。
- 自适应码率：有延迟与发送码率状态，具体调节算法未知。

### Windows client（方向 A）

- 客户端是普通 Qt 顶层窗口，`QGraphicsView` 画解码帧，全屏 `showFullScreen`，
  退出 `showNormal`，触发键 `ExitFullscreenKey` 可配置。
- 未发现置顶/工具窗标志，说明它不会盖住所有虚拟桌面。
- 解码是 FFmpeg 4.x + Qt pixmap；Windows 当 host 时才用 MF 硬件编码。
- 输入是 Raw Input + 钩子采集，`SendInput` / `InjectTouchInput` 回传。
- 默认 `WiredFrameRate=60`，特性开关含 frame-resend、adaptive-quality=50、lag-quality-check。
- IddCx 驱动（UMDF，IddCx0102，配 `duetbus.sys`）属于方向 B，Windows 当 host 用。

## 二、与 SecDisplay 的差距（按影响排序）

| 优先级 | 差距 | Duet | SecDisplay 现状 | 影响 |
|---|---|---|---|---|
| 1 | 自适应码率反馈环 | 延迟 + 发送码率闭环 | 固定码率 | 拥塞时延迟稳定性 |
| 2 | 采集队列深度与最小帧间隔 | 显式 setter | 只有 captureHz，队列深度未控 | 积压型延迟 |
| 3 | 光标位置模型 | 客户端本地绘制 + 位置包 | 刚停用 SetCursorPos，位置由本机鼠标决定 | 止血可用，远程驱动需在视频上绘光标 |
| 4 | 窗口模型 | 普通 Qt 全屏 | 已改 WS_EX_APPWINDOW，方向一致 | 基本对齐 |
| 5 | 编码与分辨率 | VT 六件套 + 客户端声明档位 | 基本对齐 | 差距不大 |

## 三、现在能做的

### Windows 侧（不依赖 Mac）

- `--pace` 稳定内容 A/B：需要一段稳定 30~40fps 或 55~60fps 的运动源；
  可以请 Mac 侧再开一次 `motionloader` 窗口。
- A-Win-2 运行时呈现采样：需要 Duet 登录并建立会话。当前 `duet.exe` 只有两个隐藏的
  Qt 后台窗口（tray 与 screen change observer），没有 viewer，无法采 present。
- Windows 4.0.479 的配置默认值已读，后续可验证 feature flag 行为。
- 代码层可以开始设计自适应码率环，这是两端都确认的明显差距。

### Mac 侧

- P0：`NWListener` 强引用与监听自愈，仍未修。9922 现在只是重启恢复。
- D-1/D-2/D-3 动态实测：需要 Duet 登录、屏幕录制与辅助功能权限。
- 帧节奏任务：等 Windows `--pace` 阈值修好、稳定内容复测后再复核。

### 用户

- W3 目视确认：副屏光标外观与点击落点。
- 如果要继续 Duet 动态：登录 Duet、授权抓包与屏幕录制。

## 四、建议的下一步顺序

1. Mac 先修 P0 监听器，避免联调再次中断。
2. 用户确认 W3，关闭光标任务。
3. 若要继续 Duet：登录后由 Windows 侧跑 PresentMon / WPR，补 A-Win-2。
4. 代码层优先评估自适应码率环，其次采集队列深度。
5. 动态 A/B 放在最后，避免在链路不稳时做无效对照。

## 五、边界

- 不传播 Duet 二进制，不绕过登录/授权，不复制代码。
- 本汇总只合并两端已交付的静态结论，不补造动态数据。
