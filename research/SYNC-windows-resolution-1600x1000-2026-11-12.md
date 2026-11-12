# SYNC：Mac 侧已改 1600x1000，Windows 必须同步（2026-11-12）

> 派发方：Mac 侧
> 目标端：Windows 侧
> 性质：分辨率对齐 + 稳定性说明
> 关联：`TASK-windows-cursor-follow-2026-11-11.md`、`fb09a33`

## 一、必须同步分辨率

用户要求副屏元素更大，Mac 已切到 **1600x1000（1x，逻辑也是 1600x1000）**。

Windows 侧 `RESULT-cursor-follow-2026-11-11.md` 里仍写「启动参数 2240 1400」，
**这是旧值，必须改**：

```powershell
$env:SECDISPLAY_W="1600"; $env:SECDISPLAY_H="1000"
cd C:\SecDisplay\prototype\windows
.\start.bat
```

原因：`g_coordW/g_coordH` 默认取启动参数，必须等于 Mac 的 `CGDisplayBounds`。
不一致会导致：

- 解码器按 2240x1400 初始化，实际流是 1600x1000，可能持续解码失败或黑屏
- `0x03`/`0x04` 坐标换算基准错位，点击落点偏移

## 二、Mac 侧当前实测状态（可作为对照）

```
虚拟屏 id=59 vendor=0xeeee 1600x1000 @ 1x
采集上限 60fps，运动负载下峰值 31~41fps
采集延迟 6~10ms，编码延迟 20~22ms
实际码率 16 Mbps（默认按像素率估算 33 Mbps，Phase1 在负载下降档）
端到端（编码输出→解码完成）中位 23.7ms，p95 122ms
```

## 三、排查中发现的稳定性问题（Mac 侧已缓解，Windows 侧需知）

**显示器一旦睡眠，ScreenCaptureKit 会返回 0 个显示器**，表现为发送端日志反复
「找不到 SecDisplay 虚拟屏（当前可用: ）」，抓屏重建连续失败，采集 0 帧。

根因不是权限（TCC 已授权），也不是孤儿虚拟屏（那种是 CG 能枚举但 SCK 看不到）。

有效缓解：保持显示器常亮

```bash
nohup caffeinate -dims -u >/dev/null 2>&1 &
```

必须带 `-u`（声明用户活动），只带 `-d` 时实测无效。

如果 Windows 端看到画面卡住/黑屏，先确认 Mac 上这条命令还在跑。

## 四、Windows 侧要做的

1. 按第一节改成 1600x1000 重新启动
2. 重新验收 W3 四项动判据与 W4：
   - Mac 光标在副屏内移动，Windows 光标是否跟随
   - Mac 光标静止时不抖不飘
   - Mac 光标移出后不再被拽回
   - Windows 鼠标操作不被抢
3. 回报写进 `prototype/windows/RESULT-cursor-follow-2026-11-11.md`，注明分辨率 1600x1000

## 五、边界

- 不改协议
- 不恢复 4ms 轮询版 cursorThread
- 分辨率变更必须两端同时，禁止单边改
