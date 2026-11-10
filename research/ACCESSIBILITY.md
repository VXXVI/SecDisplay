# 辅助功能授权与稳定签名

## 为什么需要

副屏上的点击、滚轮通过 Mac 端 `CGEvent` 重放，受 macOS 辅助功能（Accessibility / TCC）保护。没授权时事件被系统静默丢弃，画面和光标都正常，但点击不生效。

## 给哪个应用授权

**`screensender` 这个可执行文件本身**，不是终端。

原因：

- 它是裸 Mach-O 二进制，没有 `.app` bundle、没有 bundle ID（`Info.plist=not bound`）
- `./run.sh start` 用 `nohup ... &` 启动，父进程是 launchd（pid 1），已脱离终端，不继承终端的授权
- TCC 按「发起 CGEvent 的进程」的代码身份判定

路径：

```
<仓库>/prototype/mac/screensender
```

## 一次性授权步骤

1. 系统设置 → 隐私与安全性 → 辅助功能
2. 点 `+`，`Cmd+Shift+G` 粘贴上面 `screensender` 的完整路径，打开
3. 确认列表里 `screensender` 开关为开
4. 完全重启服务：`./run.sh restart`
5. 验证：`./run.sh doctor` 显示「已授权」，或启动日志里不再有「未获得辅助功能权限」

命令行重置：`tccutil reset Accessibility com.secdisplay.screensender`

## 稳定签名：重编后不用再授权

### 问题

`swiftc` 默认产出 ad-hoc 签名，其 designated requirement 是 `cdhash H"..."`。TCC 把授权绑在这个 DR 上，而 `run.sh` 每次检测到源码更新就重编，cdhash 一变，授权立即失效。表现为「每次改代码都要重新授权」。

### 解决

编译后用固定 identifier 型 DR 重签：

```sh
codesign --force --sign - \
    --identifier com.secdisplay.screensender \
    -r='designated => identifier "com.secdisplay.screensender"' \
    screensender
```

TCC 存的是 `identifier "com.secdisplay.screensender"`，与二进制内容无关。实测两次不同源码编译的 cdhash 完全不同，但 DR 文本一致，授权保持有效。不需要 Apple 开发者证书。

`run.sh` 已在以下时机自动重签：

- 每次编译完成后
- 启动时若发现二进制不是稳定身份（如首次拉仓库）
- `./run.sh sign` 手动重签

### 相关命令

| 命令 | 作用 |
|---|---|
| `./run.sh doctor` | 查签名身份与授权状态，给授权指引 |
| `./run.sh sign` | 只重签身份，不启动 |
| `codesign -d -r- screensender` | 看当前 DR，应为 `designated => identifier "com.secdisplay.screensender"` |

### 安全边界

identifier 型 DR 意味着「同 identifier 的任意二进制都能满足授权」。对本地自研工具足够，但它不如 Developer ID 证书签名严格。若要更强隔离，可改用本机已有的 Apple Development 证书签名，代价是证书绑个人账号、换机器不可用。

## 重启时的残留虚拟屏

`kill -TERM` 后进程需要时间走完 `CDVirtualDisplayDestroy`，WindowServer 同步销毁又是异步的。`run.sh stop` 现在会：

1. 等进程退出（最多 6 秒）
2. 轮询确认 SELF 虚拟屏（`vendor=0xEEEE/model=0x5344`）从在线列表消失（最多 4 秒）
3. 仍有残留时明确提示，不静默放过

若进程被强杀导致残留屏在线，`start` 会报「虚拟屏创建被拒绝」。CoreDisplay 只提供 `CDVirtualDisplayDestroy(client指针)`，client 指针在创建它的进程里才有效，进程已退出则无法从外部清除，只能**注销并重新登录**（或重启）让 WindowServer 重建显示状态。见 `reset-display-state.sh`。
