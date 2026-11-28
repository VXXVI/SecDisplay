# 真机回归记录：角色跟随、鼠标互通、过渡层与面板

日期：2026-11-28

## 环境

- Mac：MacBook Pro（Apple Silicon），macOS，Tailscale `100.94.140.116`。
- Windows：Lenovo Yoga Slim 7 Pro 14IHU5，Windows 11，Intel Iris Xe，Tailscale `100.119.194.106`，控制台会话 ID 1。
- 构建：Mac `build_app.sh`（Apple Development 签名，保留 TCC）；Windows VS2022 Community `build.bat`，另用 MinGW-w64 14 交叉编译验证。
- 链路：Thunderbolt 的 `10.10.10.2` 当前单向异常（Windows→Mac 可 ping，Mac→Windows ARP 不解析），本次回归改用 Tailscale 地址，协议与端口不变。Thunderbolt 问题另行排查。

## 构建与自检

- Windows MSVC 编译通过（`SelfCheck.exe`、`SecDisplayReceiver.exe`）。
- `SelfCheck.exe`：H.264 硬件解码、D3D11 VideoProcessor、免垂直同步均可用。
- `SecDisplayReceiver.exe --selftest-cursor`：`SELFTEST_PASS fails=0`，包含新增的「远端 0x03 仍变化时 HOLD 续期」断言。SSH 会话无交互桌面，分层叠加窗几何用例按设计跳过（err=1459）。

## 正向（Mac 主屏 → Windows 副屏）

- Mac `SECDISPLAY_MODE=sender`、2880×1800、50 fps；Windows receiver `--fullscreen`。
- 连接成功，握手 `0x7E/0x02`，会话头 `2880x1800 @ 50 fps scale=2.0x`。
- 稳定 43～56 fps，解码失败 0、上屏失败 0、呈现丢帧 0；画面为 Mac 桌面。
- 鼠标互通：
  - Windows 本机指针移到 `(410,310)`，Mac 指针精确落到 `(1922,392)`，与虚拟屏原点 `(1512,82)` 的映射一致。
  - Mac 指针 warp 到 `(1700,300)`，Windows 本机指针变为 `(188,218)`，反向映射一致。
  - 键盘事件计数随焦点操作增长，说明 0x09 回传通路正常。

## 角色自动跟随

- Windows receiver 连接 Mac receiver 时收到 `0x7E role=1`：
  - 日志：`收到 Mac 角色握手 role=1` → `角色跟随: Mac 已切换为副屏，Windows 自动切为主控`。
  - 进程命令行变为 `--mode sender`，VDD 插入 `\\.\DISPLAY15 2880x1800`，编码器 Intel QSV，连接 Mac receiver。
- Windows sender 连接 Mac sender 时收到校验通过的 `0x06` 会话头：
  - 日志：`角色冲突: Mac 端当前是主控发送端（0x06），本机将自动切回副屏` → `角色跟随: Mac 已切换为主屏，Windows 自动切为副屏`。
  - 进程命令行变回 `--mode receiver`，重新连接并收流。
- Mac receiver 窗口显示 Windows 11 桌面壁纸、任务栏与远端光标，反向链路正常。静态桌面下发送端按 0.2 fps 保活，属预期。

## 过渡层

- 断开 Mac sender 后截图：最后一帧保留并压暗，中央显示「连接已断开」「2 秒后自动重连，画面会在首帧到达后恢复」，底部品牌文字，不再整屏纯黑。
- `SecDisplayTransition` 分层窗口 `2880x1800`、DPI 192、`WS_EX_TRANSPARENT`，不拦截鼠标；首帧 Present 后隐藏。
- 本次发现并修复：断线后重连尝试期间，过渡层还停留在「连接已断开」；现在每次连接失败会更新为「正在重连 Mac」，与状态提示一致。

## 晃动找光标

- 在 Windows 副屏上快速左右晃动：日志 `检测到快速晃动（反转 x3 y2，摆幅 x720p y240p）`，叠加层 `101x149 (zoom 2.66x 源 146x215)`。
- 截图可见 3.8x 放大光标；停手后叠加层隐藏，恢复硬件光标。
- 自检覆盖 GROW/HOLD/SHRINK、远端续期、收缩重启、几何上限。

## 控制面板

- Windows 面板在 192 DPI 下为 1896×1706，完整落在 2880×1800 屏幕内。
- 角色/显示方式大选择卡、标题+副标题、选中勾、右侧「鼠标互通」「跟随 Mac 自动切换」、三列信息卡、中转站、控制按钮、日志卡均正常显示。
- 本次发现并修复：接收端模式没有显示方式按钮时仍绘制「显示方式」标签，留下空行；现在只在主控模式绘制该标签。

## 遗留

- Thunderbolt `10.10.10.x` 单向问题需要单独排查（Windows 端 ARP 表指向 Mac 的桥 MAC，Mac 端 ARP 请求得不到回复；怀疑 macOS Thunderbolt Bridge 的 FDB/MAC 选举或 Windows Thunderbolt Networking 驱动状态）。Tailscale 下功能与协议完全正常。
- Windows 全屏时任务栏仍可能置顶显示，属既有窗口层级行为，本次未改。
