# RESULT：Sidecar 镜像与满帧率修复（2026-11-13）

- 执行端：Windows 侧（经 SSH 直接操作 Mac）
- 关联任务：`research/TASK-mac-sidecar-2026-11-13.md`
- Mac 仓库：`/Users/quark/Codex/Project/SecDisplay`，本地未提交改动仍在

## 一、已确认的事实

1. 三块屏是扩展关系，不是 CG 镜像：
   - 内建 id=1 `(0,0 1512x982)` main
   - Sidecar id=29 `(-1149,0 1149x802)`
   - SecDisplay id=32 `(1512,0 1600x1000)`
   - 三块 `mirrorOf=0`、`inMirrorSet=0`，`system_profiler` 也显示 `Mirror: Off`
2. 发送端日志 `抓屏已启动 displayID=32`，抓的确实是虚拟屏
3. 但 Windows 端看到的仍是内建屏的 Chrome 内容，原因是采集流建立时虚拟屏还在镜像集里，SCK 把镜像源内容绑进了流；MirrorGuard 之后解除镜像，流没有重建，画面继续是旧的镜像源

## 二、已做的修改

### 1. 满帧率（掉帧）

`Sources/main.swift` 的 `shouldSkipStatic` 改为直接返回 `false`：

- 去掉 0.5 秒兜底和 96x60 采样跳过
- SCK 送多少帧就编多少帧

实测 Windows 端稳定 61.5 到 63.5 fps，`呈现丢帧 +0`，`解码失败 0`，源间隔 p50 16.7 到 17.2ms。

### 2. 镜像守护

沿用 Mac 侧未提交的 `MirrorGuard`：建屏后和每次显示重配置都检查 `CGDisplayMirrorsDisplay`，发现虚拟屏是 slave 或有屏镜像到它，就调 `CGConfigureDisplayMirrorOfDisplay(..., kCGNullDirectDisplay)` 拆掉。

### 3. 签名与 TCC

- 证书签名在 SSH 会话里失败（`errSecInternalComponent`，登录钥匙串锁着）
- 退回 ad-hoc 签名，DR 为 `identifier "com.secdisplay.screensender"`
- 从 SSH 启动的发送端没有屏幕录制权限（TCC 归到 sshd），抓屏报 `-3801 The user declined TCCs`
- 必须从 Mac 的 Terminal 启动，Terminal 有屏幕录制授权

### 4. 隐藏镜像（2026-11-13 现场追加）

权限都正常：屏幕录制已授权（抓屏 60fps，无 `-3801`），辅助功能无告警。

但采集内容仍然是内建屏/Sidecar：

- 发送端日志 `抓屏已启动 displayID=33`，`在线显示器身份` 里 `id=33 ... [SELF]`，抓的确实是虚拟屏
- `CGDisplayMirrorsDisplay(33)=0`，`CGDisplayIsInMirrorSet(33)=0`，`system_profiler` 也是 `Mirror: Off`
- 但窗口列表里虚拟屏只有 Finder 桌面，Sidecar 上有 Chrome/Music，而 Windows 端看到的是 Sidecar 的 Chrome
- 说明虚拟屏的 framebuffer 在显示 Sidecar 的内容，这个镜像关系 CG 的 mirror API 看不到

尝试过：

- `CGConfigureDisplayMirrorOfDisplay` 对三块屏统一解除：`CGCompleteDisplayConfiguration` 返回 1001（illegal argument）
- 只对 Sidecar + 虚拟屏解除：同样返回 1001
- 把虚拟屏原点 1512 → 1513 → 1512 强制重配置：complete 返回 0，但采集内容不变

结论：这个镜像由 macOS/Sidecar 在接入时建立，CG 的 mirror API 既不报告也拒绝修改。应用侧用 `CGConfigureDisplayMirrorOfDisplay` 拆不掉。

可行的修复方向：

1. 显示器变化（Sidecar 接入）后销毁并重建虚拟屏，再重建采集流，让新虚拟屏按扩展方式重新加入排列
2. 不用 display filter，改成按虚拟屏自己的窗口列表做 window filter，避开镜像源
3. 现场手动：显示器设置里选中 iPad，使用方式改成「扩展显示器」，排列图里把 iPad 和 SecDisplay 的矩形拖开；如果仍然镜像，先断开 Sidecar，重启发送端，再连 Sidecar 并立刻设成扩展

## 三、还差一步（需要现场操作）

### 1. 启动发送端

在 Mac 的 Terminal 里执行：

```bash
cd /Users/quark/Codex/Project/SecDisplay/prototype/mac
export SECDISPLAY_W=1600 SECDISPLAY_H=1000
export SECDISPLAY_LOGICAL_W=1600 SECDISPLAY_LOGICAL_H=1000
export SECDISPLAY_HZ=60
./run.sh start
```

注意：从 SSH 或后台启动会丢屏幕录制权限，必须在这个 Terminal 窗口里跑。

### 2. 授予辅助功能

重签后 Accessibility 授权失效，发送端日志会打 `未获得辅助功能权限`。在 系统设置 → 隐私与安全 → 辅助功能 里勾选 `screensender`（或运行它的 Terminal），否则副屏点击和滚轮不生效。

### 3. 采集流重建

如果启动后画面仍是内建屏内容，说明流建立时虚拟屏还在镜像集里。需要给 `MirrorGuard` 的解除镜像回调加一条：解除后把 `Capture.needsRestart = true`，让采集流按新排列重建。当前代码只解除镜像，不重建流。

## 四、验收

- Windows 端稳定 60fps 左右，`呈现丢帧 +0`
- 发送端日志 `抓屏已启动 displayID=` 等于 `[SELF]` 的 id
- Windows 窗口显示虚拟屏自己的桌面，不是内建屏 Chrome
- 断开重连 Sidecar 后，排列保持扩展，不自动镜像
- 副屏点击和滚轮生效
