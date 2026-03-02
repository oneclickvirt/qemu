#!/bin/bash
# from
# https://github.com/oneclickvirt/qemu
# 2026.03.02

# 删除单个虚拟机脚本
# Usage: ./delete_qemu.sh <vm_name>

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

vm_name="${1:-}"
if [[ -z "$vm_name" ]]; then
    # 显示所有虚拟机
    echo "当前虚拟机列表 / Current VMs:"
    virsh list --all 2>/dev/null
    echo ""
    read -rp "$(echo -e "\033[32m请输入要删除的虚拟机名称 / Enter VM name to delete: \033[0m")" vm_name
fi

if [[ -z "$vm_name" ]]; then
    _red "No VM name specified."
    exit 1
fi

# 检查 VM 是否存在
if ! virsh dominfo "$vm_name" >/dev/null 2>&1; then
    _red "VM '$vm_name' does not exist."
    exit 1
fi

_yellow "即将删除虚拟机 / About to delete VM: $vm_name"
read -rp "$(echo -e "\033[31m确认删除？输入 yes 继续 / Confirm? (yes): \033[0m")" confirm
if [[ "$confirm" != "yes" ]]; then
    _yellow "已取消 / Cancelled"
    exit 0
fi

# ======== 1. 关闭 VM ========
_yellow "[1/5] 关闭虚拟机..."
virsh destroy "$vm_name" 2>/dev/null || true
sleep 2

# ======== 2. 读取 VM 信息（IP、MAC）用于清理 ========
vm_ip=""
vm_mac=""
if [[ -f /root/vmlog ]]; then
    log_line=$(grep "^${vm_name} " /root/vmlog 2>/dev/null | tail -1)
    vm_ip=$(echo "$log_line" | awk '{print $10}')
fi
if command -v virsh >/dev/null 2>&1; then
    vm_mac=$(virsh domiflist "$vm_name" 2>/dev/null | grep virtio | awk '{print $5}' | head -1)
fi

# ======== 3. 清理端口转发（hooks 和 iptables）========
_yellow "[2/5] 清理端口转发规则..."
if [[ -f /etc/libvirt/hooks/qemu ]]; then
    # 提取 VM 的 iptables -I / -A 规则并执行相应的 -D（删除）
    local in_block=false
    while IFS= read -r line; do
        if echo "$line" | grep -q "#${vm_name}#"; then
            in_block=true
            continue
        fi
        if echo "$line" | grep -q "###${vm_name}###"; then
            in_block=false
            continue
        fi
        if $in_block; then
            # 将 -I 或 -A 替换为 -D 然后执行
            del_rule=$(echo "$line" | sed 's/iptables -I /iptables -D /g; s/iptables -A /iptables -D /g')
            eval "$del_rule" 2>/dev/null || true
        fi
    done < /etc/libvirt/hooks/qemu

    # 从 hooks 文件中删除该 VM 的规则块
    tmpfile=$(mktemp)
    skip=false
    while IFS= read -r line; do
        if echo "$line" | grep -q "^#${vm_name}#$"; then
            skip=true
            continue
        fi
        if echo "$line" | grep -q "^###${vm_name}###$"; then
            skip=false
            continue
        fi
        if ! $skip; then
            echo "$line" >> "$tmpfile"
        fi
    done < /etc/libvirt/hooks/qemu
    mv "$tmpfile" /etc/libvirt/hooks/qemu
    chmod +x /etc/libvirt/hooks/qemu
    _green "  ✓ iptables 规则已清理"
fi

# 持久化保存
netfilter-persistent save 2>/dev/null || \
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
    service iptables save 2>/dev/null || true

# ======== 4. 删除 DHCP 预留 ========
_yellow "[3/5] 删除 DHCP 预留..."
if [[ -n "$vm_mac" && -n "$vm_ip" ]]; then
    virsh net-update default delete ip-dhcp-host \
        "<host mac='${vm_mac}' name='${vm_name}' ip='${vm_ip}' />" \
        --live --config 2>/dev/null || \
    virsh net-update default delete ip-dhcp-host \
        "<host mac='${vm_mac}' ip='${vm_ip}' />" \
        --config 2>/dev/null || true
    _green "  ✓ DHCP 预留已删除"
elif [[ -n "$vm_mac" ]]; then
    _yellow "  No IP found for $vm_name, skipping DHCP cleanup"
fi

# ======== 5. 删除 VM 定义和磁盘 ========
_yellow "[4/5] 删除虚拟机定义和磁盘..."
virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || \
    virsh undefine "$vm_name" 2>/dev/null || true

# 手动删除磁盘（以防 --remove-all-storage 未生效）
images_path="/var/lib/libvirt/images"
if [[ -f /usr/local/bin/qemu_images_path ]]; then
    images_path=$(cat /usr/local/bin/qemu_images_path)
fi
rm -f "${images_path}/vm-${vm_name}.qcow2" 2>/dev/null || true
rm -f "${images_path}/vm-${vm_name}-cloudinit.iso" 2>/dev/null || true
_green "  ✓ 虚拟机磁盘已删除"

# ======== 5. 从日志中删除记录 ========
_yellow "[5/5] 从日志中删除记录..."
if [[ -f /root/vmlog ]]; then
    local tmplog
    tmplog=$(mktemp)
    grep -v "^${vm_name} " /root/vmlog > "$tmplog" 2>/dev/null || true
    mv "$tmplog" /root/vmlog
    _green "  ✓ 日志记录已删除"
fi

echo ""
_green "======================================================"
_green "  ✓ 虚拟机 ${vm_name} 已成功删除！"
_green "======================================================"
