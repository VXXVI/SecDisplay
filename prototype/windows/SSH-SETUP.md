# SecDisplay 的 Windows SSH 部署

Mac 端已配置好 `secdisplay-win`。保留雷电直连，Mac 地址为 `10.10.10.1`，Windows 地址为 `10.10.10.2`。以下步骤在 Windows 上执行。

## 1. 安装并启动 OpenSSH Server

打开管理员 PowerShell，粘贴以下命令。防火墙规则只允许从 Mac 的直连地址访问 Windows 的直连地址。

```powershell
$capability = 'OpenSSH.Server~~~~0.0.1.0'
if ((Get-WindowsCapability -Online -Name $capability).State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $capability
}

$rule = 'OpenSSH-Server-In-TCP'
if (Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name $rule -Enabled True `
        -LocalAddress 10.10.10.2 -RemoteAddress 10.10.10.1
} else {
    New-NetFirewallRule -Name $rule -DisplayName 'OpenSSH from SecDisplay Mac' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 `
        -LocalAddress 10.10.10.2 -RemoteAddress 10.10.10.1
}

Set-Service sshd -StartupType Automatic
Start-Service sshd
```

[微软 OpenSSH 安装文档](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)

## 2. 为 Windows 桌面账户添加 Mac 公钥

选择下方与你平时登录 Windows 桌面的账户对应的一段。普通账户在该账户自己的 PowerShell 执行，管理员账户在管理员 PowerShell 执行。先在同一个窗口设置公钥变量。

```powershell
$publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJaqf9UJ9D2ZpNUiLWd5XrtsiwlJcfwgvRm5RjklJaXb secdisplay-mac-to-windows'
```

**普通账户**

```powershell
$keyDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
Add-Content -Encoding ascii -Path (Join-Path $keyDir 'authorized_keys') -Value $publicKey
```

**管理员账户**

```powershell
$keyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
Add-Content -Encoding ascii -Path $keyFile -Value $publicKey
icacls.exe $keyFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F'
```

[微软公钥配置文档](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)

## 3. 关闭密码登录并获取主机指纹

在管理员 PowerShell 中打开配置文件。

```powershell
notepad.exe "$env:ProgramData\ssh\sshd_config"
```

在第一个 `Match` 之前找到 `PasswordAuthentication`，改成下面这一行。如果该项带 `#`，去掉 `#`。保存后关闭记事本。

```text
PasswordAuthentication no
```

在管理员 PowerShell 中检查配置并重启 SSH 服务。

```powershell
$openSshDir = Join-Path $env:WINDIR 'System32\OpenSSH'
& "$openSshDir\sshd.exe" -t
if ($LASTEXITCODE -eq 0) {
    Restart-Service sshd
    & "$openSshDir\ssh-keygen.exe" -lf "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"
}
```

用你平时登录桌面的账户打开 PowerShell，执行 `whoami`。把 `whoami` 和上面 `ssh-keygen` 的输出发给 Mac 端 agent，用来核对主机指纹并验证登录。
