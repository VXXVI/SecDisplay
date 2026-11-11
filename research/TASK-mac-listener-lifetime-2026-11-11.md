# 任务单：NWListener 未被强引用，运行中监听端口会消失

> 状态：待执行
> 派发方：Windows 侧
> 目标端：Mac 侧
> 日期：2026-11-11
> 优先级：高（会导致接收端永久连不上，直到重启发送端）
> 回报方式：`research/RESULT-mac-listener-lifetime-2026-11-11.md`

## 一、现象与证据

- Windows 端 `ping 10.10.10.1` 正常，但 TCP 连接 **9922 返回 `WSAECONNREFUSED (10061)`**，
  说明主机可达、端口没有监听。
- 同时 Mac 遥测仍在每 5 分钟更新（`generated_utc` 持续前进），说明发送端进程还活着，
  SCK 采集与编码循环也在跑，只有监听器没了。
- 时间点约 2026-11-11 20:50（本地），此前接收端做过多次快速重启。

## 二、根因

`prototype/mac/Sources/Sender.swift`（实际文件 `ScreenSender.swift`）的
`func listen(port:)` 里：

```swift
let listener: NWListener
do {
    listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
} catch { ... }
listener.newConnectionHandler = { ... }
listener.stateUpdateHandler = { ... }
listener.start(queue: queue)
```

`listener` 是**局部变量**，函数返回后没有任何强引用。`NWListener` 在启动后
可能被运行时释放，端口随之关闭，而 `Sender` 对象、SCK、编码器都继续运行。
全仓库搜索不到 `var listener` 或 `self.listener`，只有这一处局部声明。

## 三、修法（最小改动）

1. 在 `Sender` 里加属性：`private var listener: NWListener?`。
2. `listen(port:)` 中改为 `self.listener = try NWListener(...)`，后续用 `self.listener` 配置与启动。
3. `stateUpdateHandler` 增加失败自愈：
   - `.failed(let e)`：记日志，`self.listener?.cancel()`，延迟 1 秒重新 `listen(port:)`。
   - `.cancelled`：若进程仍在运行，延迟 1 秒重新 `listen(port:)`。
4. 加一个轻量看门狗（复用现有定时器队列即可）：每 5 秒检查
   `self.listener?.state == .ready`，不 ready 就重建。避免只靠状态回调漏掉释放。

注意：重建监听器不要动现有连接与 `connEpoch` 逻辑，也不要重置编码器。

## 四、判据

- 修复后连续启停 Windows 接收端 20 次，`lsof -iTCP:9922 -sTCP:LISTEN`（或等价命令）
  每次都能看到监听。
- 让发送端空跑 2 小时，期间不重启，Windows 端随时 `Test-NetConnection 10.10.10.1 -Port 9922`
  都成功。
- 日志里出现监听自愈时要有明确一行，便于事后取证。

## 五、本轮不做

- 不改编码、采集、码率、档位。
- 不动辅助功能授权与跨屏光标。
- 不引入新的网络框架，仍是 Network.framework。
