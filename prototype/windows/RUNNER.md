# 让 GitHub 能操作这台 Windows（self-hosted runner）

装好之后，可以在 GitHub Actions 里点一下 `Windows Ops`，让这台机器：

- 自动 `git fetch` 并 `reset --hard origin/main`，拉取最新代码
- 可选地重新编译接收端
- 执行任意 PowerShell 命令，执行日志回传到 GitHub

整个过程不需要在这台机器上手动开端口，也不需要公网 IP。

---

## 为什么要装

`windows-latest` 是 GitHub 云端的一次性虚拟机，跑完就销毁，连不到雷电链路
`10.10.10.x`，也碰不到 `C:\SecDisplay`。只有 self-hosted runner 才能真正落到这台机器上。

---

## 第 1 步：准备

确认这台机器已经有：

- Git（`git --version` 能出版本）
- Visual Studio 2022，勾选「使用 C++ 的桌面开发」
- 代码在 `C:\SecDisplay`

---

## 第 2 步：在 GitHub 上生成安装命令

1. 打开仓库 `Settings → Actions → Runners`
2. 点 `New self-hosted runner`
3. 选 `Windows` + `x64`

页面会给出两条命令，带一个**一次性 token**（有效期约 1 小时）。照抄即可，不要把 token 贴到任何地方。

---

## 第 3 步：下载并配置

在 **PowerShell（管理员）** 里执行页面给的下载解压命令，然后：

```powershell
cd C:\actions-runner

# 把 URL 和 TOKEN 换成页面上给出的那一对
.\config.cmd --url https://github.com/VXXVI/SecDisplay --token <TOKEN> `
  --labels windows --work C:\actions-runner\_work --runasservice
```

几个参数的含义：

- `--labels windows`：workflow 里用 `runs-on: [self-hosted, windows]` 匹配
- `--work`：runner 的临时工作目录，和部署目录 `C:\SecDisplay` 分开，避免互相覆盖
- `--runasservice`：注册成 Windows 服务，开机自启

如果 `--runasservice` 失败，可以先用 `.\run.cmd` 前台跑起来验证，成功后再装服务：

```powershell
.\svc.cmd install
.\svc.cmd start
```

---

## 第 4 步：验证

回到 GitHub 仓库，打开 `Actions → Windows Ops → Run workflow`：

- `sync` 勾上
- 其他留空

跑完应该能看到「同步最新代码」这一步输出了当前提交号，最后「汇总」里显示机器名和接收端路径。

---

## 日常用法

| 想做的事 | 怎么填 |
|---|---|
| 只拉最新代码 | `sync=true`，其余留空 |
| 拉代码并重新编译 | `sync=true`、`rebuild=true` |
| 重启接收端 | `command` 填 `Start-Process .\prototype\windows\SecDisplayReceiver.exe -ArgumentList '10.10.10.1','9922','2240','1400'` |
| 看当前进程 | `command` 填 `Get-Process SecDisplayReceiver -ErrorAction SilentlyContinue` |

---

## 安全边界

- runner 以服务身份运行，`command` 会在本机执行任意 PowerShell，**只有对仓库有写权限的人能触发**
- 不要把这个 runner 挂到公开仓库上
- token 是一次性的，泄露了去 Settings 里 revoke 再重新生成
- `reset --hard` 会丢弃这台机器上未提交的改动；需要保留的改动请先提交或另存

---

## 机器睡眠怎么办

self-hosted runner 需要机器在线才能接任务。Windows 睡眠时任务会排队，唤醒后执行。
如果希望它随时可用，把电源计划里的睡眠关掉，或者接受"唤醒后补跑"。
