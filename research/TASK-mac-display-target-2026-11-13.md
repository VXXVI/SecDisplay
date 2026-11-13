# 任务单：修正虚拟屏采集目标（2026-11-13）

> 状态：待执行
> 派发方：Windows 侧
> 目标端：Mac 侧
> 日期：2026-11-13
> 关联：`prototype/mac/Sources/main.swift` 的 `Capture.buildStream`、`VirtualDisplayManager.create`
> 回报：`research/RESULT-mac-display-target-2026-11-13.md`

## 一、现象

Windows 接收端收到的是 1600x1000 的实时画面，内容却是内建屏上的 Chrome 窗口，不是一块独立的扩展桌面。用户在 macOS 显示器设置里选了「扩展」，Windows 端仍然看到内建屏内容，点击也落不到扩展桌面上的窗口。

## 二、Windows 侧证据

- 接收端单实例、连接稳定，1600x1000，解码失败 0，呈现丢帧 0
- 静止时 2fps，画面变化时 11 到 22fps，源间隔 p50 21ms，说明采集、编码、传输、解码链路是通的
- 内容与内建屏一致，不是空扩展桌面

## 三、两个嫌疑点

1. **虚拟屏在镜像内建屏**：`VirtualDisplayManager.create` 只建屏和 `applySettings`，没有解除镜像。新建的 CGVirtualDisplay 可能沿用系统排列处于 mirror 状态，SCK 抓镜像屏会拿到镜像源（内建屏）的内容。
2. **采集兜底选错屏**：`buildStream` 先按 EDID 三元组找 `[SELF]`，找不到时退回 `wantID`。Sidecar 插拔会让 displayID 重分配，`wantID` 可能已经指向内建屏或 Sidecar，于是抓到别的屏。代码注释自己写了这个风险。

## 四、判据

- W1：发送端启动日志里 `抓屏已启动 displayID=X` 的 X 必须等于 `在线显示器身份` 里带 `[SELF]` 的那个 id
- W2：对虚拟屏查询 `CGDisplayMirrorsDisplay(vdID) == 0`，不是镜像；若为镜像必须显式解除
- W3：Windows 窗口显示一块独立的扩展桌面，把任一窗口拖到扩展屏上，Windows 端能看到
- W4：在 Windows 端点击扩展桌面上的窗口，Mac 上对应窗口响应

## 五、建议改法

1. 建屏后显式解除镜像：

   ```swift
   var cfgRef: CGDisplayConfigRef?
   CGBeginDisplayConfiguration(&cfgRef)
   CGConfigureDisplayMirrorOfDisplay(cfgRef, vd.displayID, kCGNullDirectDisplay)
   CGCompleteDisplayConfiguration(cfgRef, .permanently)
   ```

2. `buildStream` 的兜底改成严格校验：`wantID` 对应屏的 vendor/model 也必须匹配 0xEEEE/0x5344，否则抛错并打印所有候选屏身份，不要静默抓别的屏。
3. 启动日志补一行虚拟屏的 mirror 状态和 bounds，便于现场判断。

## 六、Sidecar 连接后的镜像行为（2026-11-13 现场补充）

现象：先关 Sidecar，SecDisplay 显示正常；再开 Sidecar 并在显示器设置里选「扩展」，实际 Sidecar 镜像了 SecDisplay。

这不是采集代码的问题，是 macOS 的显示器排列与记忆：

- macOS 按显示器身份记住上一次的排列，Sidecar 重新接入时会恢复上次的排列，默认经常是镜像主屏或最后活跃的那块屏
- 在「使用方式」里选「扩展显示器」只改模式，不会移动排列图里的矩形；两块屏的矩形仍然重叠时，系统仍按镜像处理
- SecDisplay 虚拟屏如果被设为菜单栏所在的主屏，新接入的 Sidecar 更容易默认镜像到它

现场处理顺序：

1. 系统设置 → 显示器 → 选中 iPad/Sidecar，使用方式选「扩展显示器」
2. 排列页把 Sidecar 的矩形拖到 SecDisplay 矩形之外，不要重叠
3. 把菜单栏拖回内建屏，让内建屏当主屏
4. 断开再重连 Sidecar，确认排列被记住

代码侧可选加固：

- 注册 `CGDisplayRegisterReconfigurationCallback`，在显示器变化后检查 `CGDisplayMirrorsDisplay(vdID)`，如果虚拟屏变成镜像源或被镜像，重新应用一次排列
- 启动和每次重配置时打印每块屏的 `CGDisplayMirrorsDisplay`、bounds、主屏标记，便于现场判断

## 七、本轮不做

- 不改协议
- 不改 Windows 接收端
- 不动静止帧跳过策略（2fps 是预期）
