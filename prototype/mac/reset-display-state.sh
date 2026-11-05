#!/bin/zsh
# reset-display-state.sh
# 清理异常退出遗留的虚拟显示器。
# 原理：虚拟显示器由创建它的进程持有，进程非正常退出时可能残留。
# 重启登录会话（不改密码、不关机）会重建整个显示状态。

cat <<'EOF'
当前在线显示器：
EOF
/private/tmp/ls 2>/dev/null || true

cat <<'EOF'

清理方式（按侵入性从低到高）：

1) 注销再登录（最快，最安全）
   苹果菜单 → 退出登录，然后重新登录

2) 重启

3) 命令行强制重启登录会话（会关闭所有未保存的窗口，谨慎）
   sudo launchctl kickstart -k gui/$(id -u)

注意：不要用 killall WindowServer，会直接黑屏并丢失未保存工作。
EOF
