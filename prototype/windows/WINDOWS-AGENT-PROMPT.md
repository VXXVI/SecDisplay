# 给 Windows agent 的 SecDisplay 联调提示词

你在 Windows 真机上操作 SecDisplay。请完成 Windows 端的一次性部署，让 Mac agent 可以通过 SSH 编译 Windows 接收端、在已登录的桌面启动它、读取日志。直接执行你有权限完成的步骤，遇到必须由用户提权的动作时，把所需操作集中说明。

## 已知环境

- Windows 直连 IP `10.10.10.2`，Mac 直连 IP `10.10.10.1`。Mac 已配好 SSH 别名 `secdisplay-win`，上次实测 ping 正常，TCP `22` 返回 `Connection refused`。请在 Windows 上核实当前状态。
- Mac 发送端当前使用 TCP `9922`、`1600×1000`。Windows 仓库通常在 `C:\SecDisplay`，请确认实际路径。

## 1. 让 Mac 能通过公钥登录

1. 检查 Windows 直连地址、`sshd` 服务和 TCP `22` 的监听状态。按实际情况安装 Windows OpenSSH Server、启动服务并设为自动启动。
2. 将 SSH 入站规则限定为本地 `10.10.10.2:22`、来源 `10.10.10.1`。为当前 Windows 桌面账户添加下面的公钥。普通账户使用其 `.ssh\authorized_keys`，管理员账户使用 `%ProgramData%\ssh\administrators_authorized_keys`，并设置 OpenSSH 要求的文件权限。

   ```text
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJaqf9UJ9D2ZpNUiLWd5XrtsiwlJcfwgvRm5RjklJaXb secdisplay-mac-to-windows
   ```

3. 在 `sshd_config` 的全局区设置 `PasswordAuthentication no`。用 `sshd.exe -t` 检查配置，重启 `sshd`，确认 TCP `22` 已监听。记录桌面账户的 `whoami` 输出和下面命令的输出，供 Mac 核对主机指纹。

   ```powershell
   & "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe" -lf "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"
   ```

## 2. 准备 Windows 接收端的远程启动入口

1. 使用独立 Git 工作树作为联调目录，建议 `C:\SecDisplay-Lab`。保留现有开发目录和未提交改动。记录联调目录实际使用的提交号。在联调目录的 `prototype\windows` 运行 `build.bat`，确认 `SecDisplayReceiver.exe` 生成成功。
2. 注册一个叫 `SecDisplay-Receiver` 的按需运行计划任务。以当前登录 Windows 桌面的账户运行，选择「仅当用户登录时运行」。将工作目录设为联调工作树的 `prototype\windows`，创建 `logs` 目录。操作设为启动该目录下的 `SecDisplayReceiver.exe`，参数如下。

   ```text
   10.10.10.1 9922 1600 1000 --log logs\ssh-receiver.log
   ```
   **注意**：计划任务默认 `DisallowStartIfOnBatteries=True`，笔记本用电池时任务会一直排队不启动。注册后补一条：

   ```powershell
   $t = Get-ScheduledTask -TaskName 'SecDisplay-Receiver'
   $t.Settings.DisallowStartIfOnBatteries = $false
   $t.Settings.StopIfGoingOnBatteries = $false
   Set-ScheduledTask -TaskName 'SecDisplay-Receiver' -Settings $t.Settings
   ```


3. 如果桌面已登录且当前没有接收端在运行，执行 `schtasks /Run /TN SecDisplay-Receiver`，确认窗口能在桌面出现、日志可读。已有接收端在运行时保留它，回报启动验收待做。保持 `--feedback` 默认关闭，等 Mac agent 确认运行中的发送端支持 `0x07` 后再做对照。

## 完成后回报给 Mac agent

- Windows 桌面账户的 `whoami` 输出、建议使用的 SSH 登录用户名、ED25519 主机指纹。
- `sshd` 状态、端口监听地址和防火墙来源范围。Mac 会从 `10.10.10.1` 实测登录。
- 联调目录、构建提交号、计划任务名称、接收端日志完整路径，以及桌面启动验证结果。说明仍需用户完成的具体步骤。

后续由 Mac agent 指定联调提交，Windows 在独立工作树构建同一个提交。Mac 通过 SSH 触发 `SecDisplay-Receiver` 并读取日志。两端以同一个提交和相同的分辨率联调。
