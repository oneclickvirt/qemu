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

echo ""
echo "======================================================"
_red "  ⚠  警告：即将卸载 QEMU/KVM 全套环境"
echo "  包含：所有运行中/停止的虚拟机、所有磁盘镜像、"
echo "  所有 iptables 端口转发规则、libvirtd 服务、"
echo "  以及相关软件包。"
_red "  此操作不可逆！"
echo "======================================================"
echo ""
echo "请输入 yes 确认（其他输入取消）："
read -rp "> " confirm
if [[ "$confirm" != "yes" ]]; then
    _yellow "已取消卸载"
    exit 0
fi
echo ""

# ======== 1. 关闭并删除所有虚拟机 ========
_blue "[1/9] 关闭并删除所有虚拟机..."
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

# ======== 2. 清理 iptables 端口转发规则 ========
_blue "[2/9] 清理 iptables 端口转发规则..."
# 删除 libvirt hooks 中的所有自定义规则
if [[ -f /etc/libvirt/hooks/qemu ]]; then
    # 读取 hooks 中的 iptables -D 规则并执行（清理规则）
    grep 'iptables.*-D\|iptables.*-I\|iptables.*-A' /etc/libvirt/hooks/qemu 2>/dev/null | \
        sed 's/-I /-D /g; s/-A /-D /g' | bash 2>/dev/null || true
fi
# 额外清理 QEMU NAT 相关规则
iptables -t nat -F PREROUTING 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
# 保存清空后的 iptables
netfilter-persistent save 2>/dev/null || \
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
    service iptables save 2>/dev/null || true
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
_green "  iptables 规则已清理"

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
            qemu-kvm libvirt-daemon-system libvirt-clients virt-manager virtinst \
            qemu-utils cloud-init cloud-image-utils bridge-utils \
            iptables-persistent netfilter-persistent 2>/dev/null || true
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
    /var/lib/libvirt/qemu-vms.db \
    /root/vmlog; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
# 删除 /tmp 残留
rm -f /tmp/qemu-cloudinit*.yaml /tmp/qemu-cloudinit*.iso 2>/dev/null || true
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
