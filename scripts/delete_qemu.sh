#!/bin/bash
# from
# https://github.com/oneclickvirt/qemu
# 2026.03.02

# 删除单个虚拟机脚本
# Usage: ./delete_qemu.sh <vm_name> [-y]
# -y / --yes / --force: 跳过确认提示

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }

is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

LOCK_DIR="/tmp/qemu-vm-state.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
lock_acquired=false
state_lock_depth=0

acquire_state_lock() {
    local timeout="${1:-60}" elapsed=0
    if [[ "$lock_acquired" == true ]]; then
        state_lock_depth=$((state_lock_depth + 1))
        return 0
    fi
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        if [[ -f "$LOCK_PID_FILE" ]]; then
            local old_pid
            old_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
            if [[ "$old_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$old_pid" 2>/dev/null; then
                rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null || true
                continue
            fi
        fi
        if (( elapsed >= timeout )); then
            _red "Failed to acquire VM state lock after ${timeout}s"
            exit 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    lock_acquired=true
    state_lock_depth=1
    printf '%s\n' "$$" > "$LOCK_PID_FILE" 2>/dev/null || true
}

release_state_lock() {
    if [[ "$lock_acquired" == true ]]; then
        if (( state_lock_depth > 1 )); then
            state_lock_depth=$((state_lock_depth - 1))
            return 0
        fi
        rm -f "$LOCK_PID_FILE" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        lock_acquired=false
        state_lock_depth=0
    fi
}

trap release_state_lock EXIT

vm_db_file() {
    if [[ -f /usr/local/bin/qemu_db_file ]]; then
        cat /usr/local/bin/qemu_db_file
    else
        printf '%s\n' "/var/lib/libvirt/qemu-vms.db"
    fi
}

sql_escape() {
    printf '%s' "${1:-}" | sed "s/'/''/g"
}

delete_vm_db_record() {
    local vm_name="$1" db_file
    command -v sqlite3 >/dev/null 2>&1 || return 0
    db_file=$(vm_db_file)
    [[ -f "$db_file" ]] || return 0
    sqlite3 "$db_file" "DELETE FROM vms WHERE vm_name='$(sql_escape "$vm_name")';" >/dev/null 2>&1 || \
        _yellow "  SQLite VM database cleanup skipped for ${vm_name}"
}

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

# 支持 -y / --force / --yes 跳过确认
# 也支持环境变量：VM_NAME=<name>  QEMU_FORCE_DELETE=yes 或 noninteractive=true
force_mode=false
if is_truthy "${QEMU_FORCE_DELETE:-}" || is_truthy "${noninteractive:-}"; then
    force_mode=true
fi
vm_name="${VM_NAME:-}"
for arg in "$@"; do
    case "$arg" in
        -y|--yes|--force) force_mode=true ;;
        *) [[ -z "$vm_name" ]] && vm_name="$arg" ;;
    esac
done

if [[ -z "$vm_name" ]]; then
    # 显示所有虚拟机
    echo "当前虚拟机列表 / Current VMs:"
    virsh list --all 2>/dev/null
    echo ""
    if is_truthy "${noninteractive:-}" || [[ ! -t 0 ]]; then
        _red "No VM name specified. Set VM_NAME env or pass name as argument."
        exit 1
    fi
    read -rp "$(echo -e "\033[32m请输入要删除的虚拟机名称 / Enter VM name to delete: \033[0m")" vm_name
fi

if [[ -z "$vm_name" ]]; then
    _red "No VM name specified."
    exit 1
fi
if [[ ! "$vm_name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    _red "VM name must start with a letter and contain only letters, digits, underscore, hyphen"
    exit 1
fi

# 检查 VM 是否存在
if ! virsh dominfo "$vm_name" >/dev/null 2>&1; then
    _red "VM '$vm_name' does not exist."
    exit 1
fi

_yellow "即将删除虚拟机 / About to delete VM: $vm_name"
if [[ "$force_mode" != true ]]; then
    if [[ ! -t 0 ]]; then
        _red "Confirmation required. Set noninteractive=true or QEMU_FORCE_DELETE=yes to run without prompts."
        exit 1
    fi
    read -rp "$(echo -e "\033[31m确认删除？输入 yes 继续 / Confirm? (yes): \033[0m")" confirm
    if [[ "$confirm" != "yes" ]]; then
        _yellow "已取消 / Cancelled"
        exit 0
    fi
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
# 如果 vmlog 没有 IP，从 DHCP 预留中获取
if [[ -z "$vm_ip" ]]; then
    vm_ip=$(virsh net-dumpxml default 2>/dev/null | grep "name='${vm_name}'" | grep -oP "ip='[^']+'" | cut -d"'" -f2 || true)
fi

# ======== 3. 清理端口转发 ========
_yellow "[2/5] 清理端口转发规则..."

# 检测防火墙后端
FW_BACKEND=""
if [[ -f /usr/local/bin/qemu_fw_backend ]]; then
    FW_BACKEND=$(cat /usr/local/bin/qemu_fw_backend)
fi
if [[ "$FW_BACKEND" != "nft" && "$FW_BACKEND" != "iptables" ]]; then
    if command -v nft >/dev/null 2>&1; then
        FW_BACKEND="nft"
    elif command -v iptables >/dev/null 2>&1; then
        FW_BACKEND="iptables"
    fi
fi

if [[ "$FW_BACKEND" == "nft" ]]; then
    # 删除 nft qemu 表中该 VM 的所有规则（通过 comment 匹配）
    nft -a list chain ip qemu prerouting 2>/dev/null | grep "\"vm:${vm_name}\"" | grep -oP '# handle \K[0-9]+' | while read -r h; do
        nft delete rule ip qemu prerouting handle "$h" 2>/dev/null || true
    done
    _green "  ✓ nftables 规则已清理"
    # 持久化
    mkdir -p /etc/nftables.d
    {
        echo "# QEMU VM port forwarding - managed by oneclickvirt/qemu"
        echo "table ip qemu"
        echo "delete table ip qemu"
        nft list table ip qemu
    } > /etc/nftables.d/qemu.nft 2>/dev/null || true
elif [[ "$FW_BACKEND" == "iptables" ]]; then
    # iptables: 删除所有指向该 VM IP 的 DNAT/FORWARD 规则
    if [[ -n "$vm_ip" ]]; then
        while iptables -t nat -S PREROUTING 2>/dev/null | grep -Fq -- "--to-destination ${vm_ip}"; do
            rule=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "--to-destination ${vm_ip}" | head -1 | sed 's/^-A /-D /')
            read -r -a rule_args <<< "$rule"
            iptables -t nat "${rule_args[@]}" 2>/dev/null || break
        done
        while iptables -S FORWARD 2>/dev/null | grep -q -- "-d ${vm_ip}"; do
            rule=$(iptables -S FORWARD 2>/dev/null | grep -- "-d ${vm_ip}" | head -1 | sed 's/^-A /-D /')
            read -r -a rule_args <<< "$rule"
            iptables "${rule_args[@]}" 2>/dev/null || break
        done
    fi
    _green "  ✓ iptables 规则已清理"
    # Save both IPv4 and IPv6 rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    service iptables save 2>/dev/null || true
    service ip6tables save 2>/dev/null || true
    netfilter-persistent save 2>/dev/null || true
fi

# 清理 hooks 文件中该 VM 的条目（如有遗留）
if [[ -f /etc/libvirt/hooks/qemu ]] && grep -qE "^#${vm_name}#$" /etc/libvirt/hooks/qemu 2>/dev/null; then
    tmpfile=$(mktemp)
    skip=false
    while IFS= read -r line; do
        if [[ "$line" == "#${vm_name}#" ]]; then
            skip=true
            continue
        fi
        if [[ "$line" == "###${vm_name}###" ]]; then
            skip=false
            continue
        fi
        if ! $skip; then
            echo "$line" >> "$tmpfile"
        fi
    done < /etc/libvirt/hooks/qemu
    mv "$tmpfile" /etc/libvirt/hooks/qemu
    chmod +x /etc/libvirt/hooks/qemu
fi

# ======== 4. 删除 DHCP 预留 ========
_yellow "[3/5] 删除 DHCP 预留..."
acquire_state_lock 60
# 优先从网络 XML 中读取实际的 DHCP 预留信息（比 vmlog 更可靠）
dhcp_mac=$(virsh net-dumpxml default 2>/dev/null | grep "name='${vm_name}'" | grep -oP "mac='[^']+'" | cut -d"'" -f2 || true)
dhcp_ip=$(virsh net-dumpxml default 2>/dev/null | grep "name='${vm_name}'" | grep -oP "ip='[^']+'" | cut -d"'" -f2 || true)
if [[ -n "$dhcp_mac" && -n "$dhcp_ip" ]]; then
    virsh net-update default delete ip-dhcp-host \
        "<host mac='${dhcp_mac}' name='${vm_name}' ip='${dhcp_ip}' />" \
        --live --config 2>/dev/null || \
    virsh net-update default delete ip-dhcp-host \
        "<host mac='${dhcp_mac}' name='${vm_name}' ip='${dhcp_ip}' />" \
        --config 2>/dev/null || true
    _green "  ✓ DHCP 预留已删除 (${dhcp_mac} -> ${dhcp_ip})"
elif [[ -n "$vm_mac" && -n "$vm_ip" ]]; then
    # 回退：使用 vmlog 中的 IP
    virsh net-update default delete ip-dhcp-host \
        "<host mac='${vm_mac}' name='${vm_name}' ip='${vm_ip}' />" \
        --live --config 2>/dev/null || \
    virsh net-update default delete ip-dhcp-host \
        "<host mac='${vm_mac}' ip='${vm_ip}' />" \
        --config 2>/dev/null || true
    _green "  ✓ DHCP 预留已删除"
else
    _yellow "  No DHCP reservation found for $vm_name, skipping"
fi
release_state_lock

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
    acquire_state_lock 60
    tmplog=$(mktemp)
    grep -v "^${vm_name} " /root/vmlog > "$tmplog" 2>/dev/null || true
    mv "$tmplog" /root/vmlog
    delete_vm_db_record "$vm_name"
    release_state_lock
    _green "  ✓ 日志记录已删除"
else
    acquire_state_lock 60
    delete_vm_db_record "$vm_name"
    release_state_lock
fi

echo ""
_green "======================================================"
_green "  ✓ 虚拟机 ${vm_name} 已成功删除！"
_green "======================================================"
