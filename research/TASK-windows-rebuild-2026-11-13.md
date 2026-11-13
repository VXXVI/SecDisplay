# 任务单：Windows 接收端必须重建（2026-11-13 13:20）

> 派发方：Mac 侧
> 目标端：Windows 侧（windowsagent）
> 优先级：最高。当前 Windows 画面完全不可用。
> 关联提交：`264b6c3`（上屏失败可见化 / SPS 真实尺寸 / 重复帧检测 / 呈现看门狗）、`633d746`（光标按 DPI 绘制 / 单实例 / 断线清屏）

## 一、现象与已排除项

用户看到 Windows 上显示的是 Mac 的 Chrome 聊天窗口，与 iPad 上的内容一样，看起来像「SecDisplay 镜像了 Sidecar」。

Mac 侧已实测排除：

- 三块屏 `CGDisplayMirrorsDisplay` 全部为 0，`system_profiler` 也是 `Mirror: Off`
- 虚拟屏截图（13:13）是空桌面加壁纸，没有任何 Chrome 窗口
- 采集目标日志 `抓屏已启动 displayID=33 1600x1000`，身份锚定 `[SELF]`
- 发送端每 2 秒发 111~114 帧，约 57fps，0.2 Mbps（静止 P 帧）
- 接收端 13:12 连上并发了 0x02 关键帧请求，Mac 已回 IDR

结论：Mac 发的就是空桌面，Windows 显示的是**旧帧**。

## 二、根因（已定位到代码）

旧版接收端用启动参数的分辨率建解码器输入类型，不看码流 SPS：

- `SecDisplayReceiver.cpp` 旧代码：`MFSetAttributeSize(in, MF_MT_FRAME_SIZE, width_, height_)`
- 启动脚本写死 `2240x1400`（`start.bat`/`monitor.bat`/`diag.bat`），exe 默认 `2880x1800`
- Mac 当前发 `1600x1000`

尺寸不符时 `SetInputType` 反复失败，解码器不出帧，呈现线程保持最后一帧。因为断线时没有清屏，窗口就一直停在很早以前那张 Chrome 画面上，日志也一行不写。

`264b6c3` 已改成：从 SPS 解真实宽高再协商输入类型，失败可见化，呈现线程 2 秒没成功上屏就清屏并提示无信号。

## 三、要执行的动作

```powershell
cd C:\SecDisplay
git pull
cd prototype\windows
build.bat
```

启动时**不要**再传死分辨率，让它按 SPS 自适应；或者继续传也可以，新代码会用 SPS 覆盖：

```powershell
.\SecDisplayReceiver.exe --host 10.10.10.1 --port 9922 --fullscreen
```

启动前先确认没有旧实例残留：

```powershell
Get-Process SecDisplayReceiver -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='SecDisplayReceiver.exe'" |
  Select-Object ProcessId,CreationDate,CommandLine | Format-List
```

新代码带单实例互斥量，第二个实例会直接退出并打日志，不会互踢。

## 四、验收判据

日志里必须出现：

1. `按 SPS 更新编码尺寸: 1600x1000（启动参数 2240x1400）` —— 证明尺寸协商已按真实码流纠正
2. `上屏失败` 恒为 0
3. 画面内容与 Mac 虚拟屏一致：当前应显示**空桌面加壁纸**，不是 Chrome
4. 状态行 `同帧重复 +N` 不应持续增长（持续增长说明源端在重发同一帧）
5. 光标尺寸正常（日志 `光标位图 24x24 ... 缩放 2.00x → 实际 48x48`，按显示器 DPI）

## 五、回报

把以下内容写进 `prototype/windows/RESULT-rebuild-2026-11-13.md` 并推送：

- `git rev-parse --short HEAD`
- 上面 5 条判据的实际日志片段
- 如果画面仍然不动，附 `上屏失败` 的具体行和 `解码器按 %ux%u 输出` 那一行

## 六、不要做的事

- 不要修改 Mac 侧代码
- 不要再用 `start.bat` 里写死的分辨率去「对齐」Mac；新代码以 SPS 为准
- 不要同时跑多个接收端实例
