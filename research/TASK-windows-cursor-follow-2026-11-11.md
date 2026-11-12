# 任务单：恢复 Mac 控制副屏 + 统一分辨率（2026-11-11）

> 状态：进行中（W1 双工具链编译通过，W2 2240x1400 已确认；W3 已观察跟随生效，W4 待用户按四项判据确认）
> 派发方：Mac 侧
> 目标端：Windows 侧
> 日期：2026-11-11
> 关联提交：`fb09a33`（事件驱动光标跟随）、`7f58f05`（监听器自愈）
> 回报载体：`prototype/windows/RESULT-cursor-follow-2026-11-11.md`

## 一、背景

Mac 侧按用户要求先做了「停用 SetCursorPos」止血，结果 Mac 鼠标移到副屏后 Windows 端
完全不动，只剩 Windows 本机鼠标可用。现已改成事件驱动加门控，需要 Windows 编译验证。

同时用户把 Windows 端分辨率改成 1600x1000 后点击错位，根因是两端坐标基准不一致。

## 二、W1（必须）编译最新代码

```powershell
cd C:\SecDisplay
git pull
cd prototype\windows
.\build.bat
```

成功判据：输出「全部编译成功」。若报 `LNK1104`，先结束正在运行的 `SecDisplayReceiver.exe` 再编译。

## 三、W2（必须）分辨率先统一回 2240x1400

Mac 当前虚拟屏是 2240x1400（smooth 档），Windows 必须一致：

```powershell
cd C:\SecDisplay\prototype\windows
.\start.bat
```

`start.bat` 默认就是 2240 1400。**不要再单独改成 1600x1000**，否则 `g_coordW/H`
与 Mac 的 `CGDisplayBounds` 不一致，点击必然偏。

如果确实要换分辨率，必须两端同时改，见第五节。

## 四、W3（必须）验收：Mac 能控制副屏

1. 启动接收端并连上，确认副屏正常显示
2. 在 Mac 上用触控板把光标移进副屏区域
3. 观察 Windows 画面上的光标是否跟着走

**通过判据**：

- Mac 光标在副屏内移动时，Windows 光标跟随
- Mac 光标停在副屏内不动时，Windows 光标也停住，不抖不飘
- Mac 光标移出副屏回到主屏后，Windows 光标不再被拽回
- 用 Windows 鼠标操作时，不会被 Mac 光标抢走

**不通过时**：记录是「完全不动」「跟随但有延迟」「互相抢」哪一类，附日志尾部 40 行。

## 五、如果要改分辨率，两端必须同步

以 1600x1000 为例：

Mac：

```bash
cd /Users/quark/Codex/Project/SecDisplay/prototype/mac
SECDISPLAY_W=1600 SECDISPLAY_H=1000 ./run.sh restart
```

Windows：

```powershell
$env:SECDISPLAY_W="1600"; $env:SECDISPLAY_H="1000"
cd C:\SecDisplay\prototype\windows
.\start.bat
```

注意：Mac 端逻辑分辨率目前取物理的一半（1600x1000 → 800x500），桌面空间会明显变小。
如果只是想让图标变大，这条路径不如修 hiDPI，后者由 Mac 侧单独处理。

## 六、W4（观察）记录跟随行为

- Mac 光标在副屏内快速移动时，Windows 光标是否跟手，有无明显滞后
- 在 2240x1400 下点击是否落点准确
- 是否出现「跟随一下停一下」的顿挫

## 七、边界

- 不改协议，不加新包类型
- 不恢复 4ms 轮询版 `cursorThread`
- 分辨率变更必须两端同时，禁止单边改

## 八、回报要求

新建 `prototype/windows/RESULT-cursor-follow-2026-11-11.md`，至少包含：

1. 编译结果
2. 分辨率确认（实际启动参数与 Mac 是否一致）
3. W3 四项判据逐条结果
4. W4 观察
5. 结论：Mac 控制副屏是否恢复，是否还有抢光标
