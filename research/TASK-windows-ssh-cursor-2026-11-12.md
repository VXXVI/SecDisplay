# 任务单：SSH 直连 + 分辨率同步 + 鼠标验收（2026-11-12）

> 状态：待 Windows 侧执行
> 派发方：Mac 侧
> 目标端：Windows 侧
> 日期：2026-11-12
> 关联：`SYNC-windows-resolution-1600x1000-2026-11-12.md`、`fb09a33`
> 回报：`prototype/windows/RESULT-ssh-cursor-2026-11-12.md`

## 一、为什么改用 SSH

现在每次验证都要走 GitHub 提交、Mac 拉取、Windows 拉取，一轮几分钟。
Windows 的 OpenSSH Server 已经在 10.10.10.2:22 跑起来（OpenSSH_for_Windows_9.5），
配好免密后 Mac 可以直接 SSH 过去执行命令、拉日志、传二进制，不用等仓库往返。

## 二、W1（最高优先）配置 Mac 免密 SSH

### 2.1 添加公钥

在 Windows 上把下面这行写进 authorized_keys。**注意权限**：如果登录用户属于
Administrators 组，OpenSSH for Windows 只认
`C:\ProgramData\ssh\administrators_authorized_keys`，不认用户目录下的那份。

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ5VVDTwc24CGhHTF2wFhDAVM+csm2LNRWpEtF4O4eR4 quark-mac
```

PowerShell（管理员）示例：

```powershell
$key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ5VVDTwc24CGhHTF2wFhDAVM+csm2LNRWpEtF4O4eR4 quark-mac'
$f = "$env:ProgramData\ssh\administrators_authorized_keys"
Add-Content -Path $f -Value $key -Encoding ascii
icacls $f /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
Restart-Service sshd
```

### 2.2 回传登录信息

请回报：

- Windows 登录用户名（大小写敏感）
- 是否属于 Administrators 组
- Mac 侧验证命令的实际结果

Mac 侧会用这条命令验证：

```bash
ssh -o BatchMode=yes 10.10.10.2 "hostname"
```

成功判据：输出 Windows 主机名，不出现 `Permission denied`。

## 三、W2 分辨率必须改成 1600x1000

Mac 当前虚拟屏是 **1600x1000（1x，逻辑同尺寸）**，不是 2240x1400。

```powershell
$env:SECDISPLAY_W="1600"; $env:SECDISPLAY_H="1000"
cd C:\SecDisplay\prototype\windows
.\start.bat
```

不一致会黑边、点击偏移（见 SYNC 文档）。改完后 `g_coordW/H` 应显示 1600/1000。

## 四、W3 鼠标跟随四项判据

在 1600x1000 下逐条确认，写进回报：

1. Mac 光标在副屏内移动，Windows 光标是否跟随
2. Mac 光标停在副屏内，Windows 光标是否停住、不抖不飘
3. Mac 光标移出副屏回主屏后，是否不再被拽回
4. 用 Windows 鼠标操作时，是否不会被 Mac 光标抢走

## 五、W4 通过 SSH 回传现场，不再只靠 GitHub

配置好 W1 后，验证时请尽量用 SSH 直接取日志，例如在 Windows 上允许 Mac 读取：

```powershell
# 让日志可被 SSH 读取（默认路径即可，不必额外配置）
dir C:\SecDisplay\prototype\windows\logs
```

Mac 侧会这样取：

```bash
ssh 10.10.10.2 "type C:\SecDisplay\prototype\windows\logs\fullscreen.log | more"
```

这样出问题能当场看日志，不用等提交。

## 六、W5 依赖与能力差距（参照 Duet，按需）

Duet 4.0.526 的 Windows 客户端具备、SecDisplay 目前没有的：

| 能力 | Duet 做法 | SecDisplay 现状 | 优先级 |
|---|---|---|---|
| 传输加密 | 直连 mTLS + 应用层 PKI/PBKDF E2E | 明文 TCP | 低（点对点直连） |
| 帧统计反馈 | FrameStats 八段 checkpoint + RTT | 无 | 中（Phase 2 需要 0x07） |
| 自适应质量 | 三档 40%/30%/20%，地板 2Mbps | Mac 侧 Phase 1 已有，Windows 无反馈 | 中 |
| 编解码 | FFmpeg 4.x + D3D11VA | Media Foundation | 已够用 |
| 虚拟显示驱动 | IddCx（方向 B，Windows 当 host） | 无，当前方向 A 不需要 | 不做 |

本轮只需回报「是否有现成的 OpenSSL / 证书需求」，不要开始改协议。

## 七、边界

- 不改协议，不加新包类型
- 不恢复 4ms 轮询光标线程
- SSH 只用于开发协作，不引入常驻服务依赖

## 八、回报格式

新建 `prototype/windows/RESULT-ssh-cursor-2026-11-12.md`：

1. W1 用户名、组、SSH 验证结果
2. W2 启动参数截图或日志行
3. W3 四项逐条结果
4. W4 SSH 取日志是否可用
5. W5 依赖现状一句话
