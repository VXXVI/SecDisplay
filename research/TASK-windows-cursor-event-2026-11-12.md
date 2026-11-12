# 任务单：Windows 验收 Mac 光标事件驱动（60/90Hz）

> 状态：待执行
> 派发方：Mac
> 目标端：Windows
> 日期：2026-11-12
> 协议：不变，仍是 0x03 光标位置 + 0x05 光标图像，接收端不需要改代码

## 一、Mac 侧改了什么

`CursorTracker` 从 8ms 轮询改成事件驱动：

- 用 `NSEvent.addGlobalMonitorForEvents` 监听 `mouseMoved` 和三种拖拽事件
- 事件到达即记位置，按目标频率限流后立刻发 0x03
- 目标频率由 `SECDISPLAY_CURSOR_HZ` 控制，当前默认 60，可切 90
- 50ms 定时器只做鼠标停顿补发；监视器不可用时退回 8ms 轮询

实测锁屏状态下事件源被压到 40Hz 左右，30Hz 目标实测 25Hz，说明限流逻辑正确。解锁后需要 Windows 侧确认 60Hz 能否跑满。

## 二、Windows 侧当前配置

计划任务已经被 Mac 侧改过，参数里带了 `--pace`：

```
C:\SecDisplay-Lab\prototype\windows\SecDisplayReceiver.exe 10.10.10.1 9922 1600 1000 --log logs\ssh-receiver.log --pace
```

`--pace` 生效后日志是 `节拍 33.3 ms`、`节拍丢帧 +11 ~ 13`、`上屏间隔 p95 约 50 ms`。这是预期行为，不要当成异常。

## 三、验收判据

W1（必做）：接收端连续运行 5 分钟，日志 `光标+` 稳定在每 2 秒 110 到 120 包，也就是约 55 到 60 包每秒。

W2（必做）：同一窗口内 `呈现丢帧 +0`、`解码失败 0`、`节拍丢帧` 只在个位数增长。

W3（需要用户在场）：在副屏上移动鼠标，光标跟手，没有一跳一跳的观感，也没有回拽到主屏。

W4（可选）：Mac 侧把 `SECDISPLAY_CURSOR_HZ` 切到 90 后，重复 W1，`光标+` 应接近每 2 秒 180 包。这一项等 60Hz 稳定后再做。

## 四、怎么配合

Mac 侧发送端已经重启，接收端会自动重连。Windows 只需要：

1. `git pull` 拿到本任务单
2. 确认接收端在跑，`Get-Process SecDisplayReceiver` 有 PID
3. 观察 `C:\SecDisplay-Lab\prototype\windows\logs\ssh-receiver.log` 的 `光标+` 字段
4. 按判据写 `prototype/windows/RESULT-cursor-event-2026-11-12.md`

## 五、本轮不做

- 不改接收端代码
- 不改协议字段
- 不做 90Hz 长期验收，等 60Hz 判据通过再开
- 不动 `--pace` 参数，它是本轮基线的一部分
