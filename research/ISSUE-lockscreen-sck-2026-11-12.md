# ISSUE：锁屏后 ScreenCaptureKit 返回空列表，采集无法恢复

> 发现日期：2026-11-12
> 环境：macOS 27.2 / M1 Pro / SecDisplay 1600x1000 / 接收端在线
> 状态：已定位触发条件，待修复

## 一、现象

屏幕锁定后，发送端日志从正常帧率掉到 0fps，随后 SCK 报告流停止。重建时 `SCShareableContent` 返回空显示器列表：

```
[91450.652] 抓屏已启动 displayID=16 1600x1000，采集上限 60fps
[91452.600] 采集 50 峰值 49fps ... 采集延迟 2.5 编码延迟 11.2 ms
[91462.603] 采集 50 峰值 0fps ...
[91464.599] 采集 50 峰值 0fps ...
[91485.x]   SCK 报告流已停止，触发重建
[91486.x]   抓屏流重建失败（第 1 次）: 找不到 SecDisplay 虚拟屏（当前可用: 空）
```

`当前可用: 空` 是 `SCShareableContent.excludingDesktopWindows` 返回的 `displays` 为空，内建屏也不在列表里。

## 二、排除项

- CG 层虚拟屏仍在：同一时刻 `CGGetOnlineDisplayList` 能看到 id=1 与 id=16，`system_profiler` 也显示 SecDisplay。
- TCC 屏幕录制授权仍在，未重置。
- 进程存活，监听 9922 正常，接收端连接未断。

## 三、结论

锁屏状态下 ScreenCaptureKit 不返回可捕获显示器，`SCShareableContent` 为空。发送端此时的重建循环注定失败，每 1 秒重试一次，日志会快速累积到上百次。

虚拟屏本身没有消失，消失的是 SCK 的可见列表。

## 四、影响

- 远程办公时屏幕锁定，副屏变成 0fps，直到解锁。
- 解锁后理论上 SCK 会恢复，重建循环能成功，但需要确认。
- 长时间锁屏会产生大量失败日志，占用磁盘。

## 五、修复方向

1. 检测 `SCShareableContent.displays` 为空时不重试，退避到 30 秒或等到屏幕解锁再试。
2. 用 `CGSSessionScreenIsLocked` / `com.apple.screenIsLocked` 通知判断锁屏，锁屏期间暂停重建。
3. 解锁通知到达后立即重建一次。
4. 重建失败日志做限流，避免每秒刷屏。

## 六、验证方法

锁屏 30 秒再解锁，观察发送端是否在解锁后自动恢复采集。当前版本会一直重试，理论上能恢复，但日志噪声很大。
