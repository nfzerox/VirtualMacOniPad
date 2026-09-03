#!/bin/bash

set -u

script_directory="$(cd "$(dirname "$0")" && pwd)"
receiver="$script_directory/VirtualMacGamepadReceiver"
port=25863

clear
echo "VirtualMac 手柄接收器"
echo ""
echo "1) Virtio Socket（推荐，无需客体 IP）"
echo "2) UDP 兼容模式"
printf "选择传输方式 [1]: "
IFS= read -r selection

case "$selection" in
    2) transport="udp" ;;
    *) transport="vsock" ;;
esac

if [[ ! -x "$receiver" ]]; then
    echo "错误：找不到可执行的接收器：$receiver"
    printf "按回车键关闭窗口..."
    IFS= read -r _
    exit 1
fi

echo ""
echo "接下来需要输入客体 macOS 的管理员密码。"
echo "按 Control-C 可停止接收器并释放虚拟手柄。"
echo ""

if ! sudo -v; then
    echo "未获得 root 权限，接收器没有启动。"
    printf "按回车键关闭窗口..."
    IFS= read -r _
    exit 1
fi

sudo "$receiver" --transport "$transport" --port "$port" \
    --timeout-ms 750 --stats --print-state
status=$?

echo ""
echo "接收器已停止，退出状态：$status"
printf "按回车键关闭窗口..."
IFS= read -r _
exit "$status"
