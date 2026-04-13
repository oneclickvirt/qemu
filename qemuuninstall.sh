#!/bin/bash
# from
# https://github.com/oneclickvirt/qemu
# 2026.03.02
# 完整卸载 QEMU/KVM 环境及所有虚拟机

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root"
    exit 1
fi

# 支持 -y / --force / --yes 跳过确认
force_mode=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes|--force) force_mode=true ;;
    esac
done

echo ""
echo "======================================================"
_red "  ⚠  警告：即将卸载 QEMU/KVM 全套环境"
echo "  包含：所有运行中/停止的虚拟机、所有磁盘镜像、"
echo "  所有 iptables 端口转发规则、libvirtd 服务、"
echo "  以及相关软件包。"
_red "  此操作不可逆！"
echo "======================================================"
echo ""
if [[ "$force_mode" != true ]]; then
    echo "请输入 yes 确认（其他输入取消）："
    read -rp "> " confirm
    if [[ "$confirm" != "yes" ]]; then
        _yellow "已取消卸载"
        exit 0
    fi
fi
echo ""

# ======== 1. 关闭并删除所有虚拟机 ========
_blue "[1/9] 关闭并删除所有虚拟机..."
# 杀掉后台 cloud-init 守护进程
pkill -f "qemu-init-" 2>/dev/null || true
pkill -f "Waiting for VM" 2>/dev/null || true
if command -v virsh >/dev/null 2>&1; then
    # 强制关闭所有运行中的VM
    virsh list --name 2>/dev/null | while read -r vm; do
        [[ -z "$vm" ]] && continue
        _yellow "  关闭虚拟机: $vm"
        virsh destroy "$vm" 2>/dev/null || true
    done
    sleep 2
    # 删除所有VM定义（包括停止的）
    virsh list --all --name 2>/dev/null | while read -r vm; do
        [[ -z "$vm" ]] && continue
        _yellow "  删除虚拟机定义: $vm"
        virsh undefine "$vm" --remove-all-storage 2>/dev/null || \
        virsh undefine "$vm" 2>/dev/null || true
    done
    _green "  所有虚拟机已删除"
else
    _yellow "  virsh 未安装，跳过虚拟机清理"
fi

# ======== 2. 清理防火墙规则 ========
_blue "[2/9] 清理防火墙规则..."

# 清理 nftables qemu 表
if command -v nft >/dev/null 2>&1; then
    nft delete table ip qemu 2>/dev/null || true
    rm -f /etc/nftables.d/qemu.nft 2>/dev/null || true
    # 移除 nftables.conf 中的 include 指令
    if [[ -f /etc/nftables.conf ]]; then
        sed -i '/include "\/etc\/nftables.d\/\*\.nft"/d' /etc/nftables.conf 2>/dev/null || true
    fi
    _green "  nftables qemu 表已清理"
fi

# 清理 iptables 中残留的 qemu 相关规则（不影响非 qemu 规则）
if command -v iptables >/dev/null 2>&1; then
    # 清理 PREROUTING 中指向 192.168.122.x 的 DNAT 规则
    while iptables -t nat -S PREROUTING 2>/dev/null | grep -q "DNAT.*192\.168\.122\."; do
        rule=$(iptables -t nat -S PREROUTING 2>/dev/null | grep "DNAT.*192\.168\.122\." | head -1 | sed 's/^-A /-D /')
        iptables -t nat $rule 2>/dev/null || break
    done
    # 清理 POSTROUTING MASQUERADE
    iptables -t nat -D POSTROUTING -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE 2>/dev/null || true
    # 清理 FORWARD 中 192.168.122.0/24 相关规则
    iptables -D FORWARD -d 192.168.122.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -s 192.168.122.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    # Save cleaned rules (both v4 and v6)
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    service iptables save 2>/dev/null || true
    service ip6tables save 2>/dev/null || true
    netfilter-persistent save 2>/dev/null || true
fi
_green "  防火墙规则已清理"

# ======== 3. 删除 libvirt 网络 ========
_blue "[3/9] 删除 libvirt 网络..."
if command -v virsh >/dev/null 2>&1; then
    virsh net-list --all --name 2>/dev/null | while read -r net; do
        [[ -z "$net" ]] && continue
        _yellow "  删除网络: $net"
        virsh net-destroy "$net" 2>/dev/null || true
        virsh net-undefine "$net" 2>/dev/null || true
    done
    _green "  libvirt 网络已清理"
else
    _yellow "  virsh 未安装，跳过网络清理"
fi

# ======== 4. 停止并禁用 libvirtd 服务 ========
_blue "[4/9] 停止 libvirtd 服务..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop libvirtd 2>/dev/null || systemctl stop libvirt-daemon 2>/dev/null || true
    systemctl disable libvirtd 2>/dev/null || systemctl disable libvirt-daemon 2>/dev/null || true
    _green "  libvirtd 服务已停止"
fi

# ======== 5. 卸载软件包 ========
_blue "[5/9] 卸载 QEMU/KVM 相关软件包..."
SYSTEM=""
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "Alpine")
CMD=(
    "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)"
    "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
    "$(lsb_release -sd 2>/dev/null)"
    "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)"
    "$(grep . /etc/redhat-release 2>/dev/null)"
    "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')"
)
SYS="${CMD[0]}"
[[ -n $SYS ]] || SYS="${CMD[1]}"
[[ -n $SYS ]] || SYS="${CMD[2]}"
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

case $SYSTEM in
    Debian|Ubuntu)
        apt-get remove -y --purge \
            qemu-kvm qemu-system libvirt-daemon-system libvirt-clients virtinst \
            qemu-utils cloud-image-utils bridge-utils 2>/dev/null || true
        # 仅在已安装时才卸载 iptables-persistent
        dpkg -l iptables-persistent 2>/dev/null | grep -q "^ii" && \
            apt-get remove -y --purge iptables-persistent netfilter-persistent 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        ;;
    CentOS|Fedora)
        yum remove -y \
            qemu-kvm libvirt libvirt-client virt-install qemu-img \
            cloud-init bridge-utils iptables-services 2>/dev/null || true
        ;;
    *)
        _yellow "  系统 $SYSTEM 不支持自动卸载包，请手动卸载"
        ;;
esac
_green "  软件包已卸载"

# ======== 6. 删除 libvirt 配置和数据目录 ========
_blue "[6/9] 删除 libvirt 配置和数据..."
for dir in \
    /var/lib/libvirt \
    /var/run/libvirt \
    /run/libvirt \
    /etc/libvirt; do
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        _yellow "  删除 $dir"
    fi
done
_green "  libvirt 数据目录已清理"

# ======== 7. 删除磁盘镜像 ========
_blue "[7/9] 删除虚拟机磁盘镜像..."
images_path="/var/lib/libvirt/images"
if [[ -f /usr/local/bin/qemu_images_path ]]; then
    images_path=$(cat /usr/local/bin/qemu_images_path)
fi
if [[ -d "$images_path" ]]; then
    # 只删除 qcow2 格式的磁盘，不删除下载缓存的 cloud 镜像基础文件
    find "$images_path" -name "vm-*.qcow2" -delete 2>/dev/null || true
    find "$images_path" -name "vm-*-cloudinit.iso" -delete 2>/dev/null || true
    _yellow "  删除 $images_path 中的虚拟机磁盘"
fi
_green "  磁盘镜像已清理"

# ======== 8. 删除本脚本安装的状态文件 ========
_blue "[8/9] 删除辅助状态文件..."
for f in \
    /usr/local/bin/qemu_arch \
    /usr/local/bin/qemu_cdn \
    /usr/local/bin/qemu_images_path \
    /usr/local/bin/qemu_bridge \
    /usr/local/bin/qemu_ipv6_enabled \
    /usr/local/bin/qemu_main_interface \
    /usr/local/bin/qemu_db_file \
    /usr/local/bin/qemu_fw_backend \
    /var/lib/libvirt/qemu-vms.db \
    /root/vmlog; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
# 删除 /tmp 残留
rm -f /tmp/qemu-cloudinit*.yaml /tmp/qemu-cloudinit*.iso 2>/dev/null || true
rm -f /tmp/qemu-init-*.log 2>/dev/null || true
rm -f /tmp/qemu-ci-* 2>/dev/null || true
_green "  状态文件已清理"

# ======== 9. 清理 sysctl 配置 ========
_blue "[9/9] 清理 sysctl 配置..."
if [[ -f /etc/sysctl.d/99-qemu.conf ]]; then
    rm -f /etc/sysctl.d/99-qemu.conf
    sysctl --system >/dev/null 2>&1 || true
    _yellow "  删除 /etc/sysctl.d/99-qemu.conf"
fi
_green "  sysctl 已清理"

echo ""
echo "======================================================"
_green "  ✓ QEMU/KVM 环境已完整卸载！"
echo "======================================================"
echo ""
echo "如需重新安装，执行："
echo "  bash <(curl -sSL https://raw.githubusercontent.com/oneclickvirt/qemu/main/qemuinstall.sh)"
