# 运动窗口标记（Mac 侧）

- 开始(UTC): 2026-11-11T01:58:18Z
- 预计结束(UTC): 2026-11-11T02:01:18Z（180 秒）
- 命令: `./tools/motionloader 180`（在 SecDisplay 虚拟屏播 CALayer 动画）
- 当前档位: smooth 2240x1400@60、lowlat 开、码率上限 180
- 用途: 供 Windows 侧在窗口内采 vsync / tearing 各 20 秒对照
- 备注: 窗口过后可请 Mac 侧重开（任一 commit 触发即被唤起）
