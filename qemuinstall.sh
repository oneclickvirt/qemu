#!/bin/bash
# from
# https://github.com/oneclickvirt/qemu
# 2026.03.02

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi

# ======== 系统检测 ========
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "Alpine")
PACKAGE_UPDATE=(
    "! apt-get update && apt-get --fix-broken install -y && apt-get update"
    "apt-get update"
    "yum -y update"
    "yum -y update"
    "yum -y update"
    "pacman -Sy"
    "apk update"
)
PACKAGE_INSTALL=(
    "apt-get -y install"
    "apt-get -y install"
    "yum -y install"
    "yum -y install"
    "yum -y install"
    "pacman -Sy --noconfirm"
    "apk add --no-cache"
)

CMD=(
    "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)"
    "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
    "$(lsb_release -sd 2>/dev/null)"
    "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)"
    "$(grep . /etc/redhat-release 2>/dev/null)"
    "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')"
    "$(grep . /etc/alpine-release 2>/dev/null)"
)
SYS="${CMD[0]}"
[[ -n $SYS ]] || SYS="${CMD[1]}"
[[ -n $SYS ]] || SYS="${CMD[2]}"
[[ -n $SYS ]] || SYS="${CMD[3]}"
[[ -n $SYS ]] || SYS="${CMD[4]}"
[[ -n $SYS ]] || SYS="${CMD[5]}"
[[ -n $SYS ]] || SYS="${CMD[6]}"
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done
if [[ -z $SYSTEM ]]; then
    _red "ERROR: The script does not support the current system!"
    exit 1
fi

# ======== 架构检测 ========
ARCH_UNAME=$(uname -m)
case "$ARCH_UNAME" in
    x86_64)  ARCH_TYPE="amd64" ;;
    aarch64) ARCH_TYPE="arm64" ;;
    armv7l)  ARCH_TYPE="arm"   ;;
    *)
        _red "Unsupported arch: $ARCH_UNAME"
        exit 1
        ;;
esac
_blue "Detected system: $SYSTEM  arch: $ARCH_TYPE"

# ======== CDN 检测 ========
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
cdn_success_url=""

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "${cdn_url}${o_url}" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN: $cdn_success_url"
    else
        _yellow "No CDN available, using direct connection"
    fi
}

# ======== KVM 虚拟化支持检测 ========
check_kvm_support() {
    _yellow "Checking KVM virtualization support..."
    if grep -E 'vmx|svm' /proc/cpuinfo >/dev/null 2>&1; then
        _green "  ✓ CPU supports hardware virtualization (vmx/svm)"
    else
        _yellow "  ⚠ CPU virtualization flags not found in /proc/cpuinfo"
        _yellow "    (May still work in nested virtualization environments)"
    fi
    if [[ -e /dev/kvm ]]; then
        _green "  ✓ /dev/kvm is available"
    else
        _yellow "  ⚠ /dev/kvm not found, trying to load kvm module..."
        modprobe kvm 2>/dev/null || true
        modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
        if [[ -e /dev/kvm ]]; then
            _green "  ✓ /dev/kvm loaded successfully"
        else
            _yellow "  ⚠ /dev/kvm still not available, VMs may run slower without KVM acceleration"
        fi
    fi
}

# ======== 安装基础依赖 ========
install_base_deps() {
    _yellow "Installing base dependencies..."
    case $SYSTEM in
        Debian|Ubuntu)
            eval "${PACKAGE_UPDATE[int]}" 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates iptables iproute2 \
                socat unzip tar jq dnsmasq-base genisoimage 2>/dev/null || true
            ;;
        CentOS|Fedora)
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates iptables iproute \
                socat unzip tar jq dnsmasq genisoimage 2>/dev/null || true
            ;;
        Alpine)
            eval "${PACKAGE_UPDATE[int]}" 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates iptables iproute2 \
                socat unzip tar jq cdrkit 2>/dev/null || true
            ;;
    esac
    _green "Base dependencies installed"
}

# ======== 安装 QEMU/KVM + libvirt 套件 ========
install_qemu_stack() {
    _yellow "Installing QEMU/KVM + libvirt stack..."
    case $SYSTEM in
        Debian|Ubuntu)
            eval "${PACKAGE_UPDATE[int]}" 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} \
                qemu-kvm \
                libvirt-daemon-system \
                libvirt-clients \
                virt-manager \
                virtinst \
                qemu-utils \
                cloud-init \
                cloud-image-utils \
                bridge-utils \
                net-tools \
                sqlite3 \
                iptables-persistent \
                netfilter-persistent \
                2>/dev/null || true
            ;;
        CentOS|Fedora)
            ${PACKAGE_INSTALL[int]} \
                qemu-kvm \
                libvirt \
                libvirt-client \
                virt-install \
                qemu-img \
                cloud-init \
                bridge-utils \
                net-tools \
                sqlite \
                iptables-services \
                2>/dev/null || true
            ;;
        Alpine)
            eval "${PACKAGE_UPDATE[int]}" 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} \
                qemu-system-x86_64 \
                qemu-img \
                libvirt \
                libvirt-client \
                virt-install \
                bridge \
                2>/dev/null || true
            ;;
    esac
    _green "QEMU/KVM stack installed"
}

# ======== 启动 libvirtd 服务 ========
start_libvirtd() {
    _yellow "Starting libvirtd service..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable libvirtd 2>/dev/null || systemctl enable libvirt-daemon 2>/dev/null || true
        systemctl start libvirtd 2>/dev/null || systemctl start libvirt-daemon 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet libvirtd 2>/dev/null || systemctl is-active --quiet libvirt-daemon 2>/dev/null; then
            _green "  ✓ libvirtd is running"
        else
            _yellow "  ⚠ libvirtd may not be running properly"
        fi
    fi
}

# ======== 配置 libvirt 默认存储池 ========
configure_storage_pool() {
    _yellow "Configuring default storage pool..."
    mkdir -p /var/lib/libvirt/images
    if ! virsh pool-info default >/dev/null 2>&1; then
        virsh pool-define-as default dir --target /var/lib/libvirt/images 2>/dev/null || true
        virsh pool-start default 2>/dev/null || true
        virsh pool-autostart default 2>/dev/null || true
        _green "  ✓ Default storage pool created"
    else
        if ! virsh pool-list --all 2>/dev/null | grep -q "default.*active"; then
            virsh pool-start default 2>/dev/null || true
            virsh pool-autostart default 2>/dev/null || true
        fi
        _green "  ✓ Default storage pool is ready"
    fi
}

# ======== 配置 libvirt 默认 NAT 网络 ========
configure_default_network() {
    _yellow "Configuring default NAT network..."
    # 检查 default 网络是否存在
    if ! virsh net-info default >/dev/null 2>&1; then
        # 创建默认网络 XML
        cat > /tmp/qemu-default-net.xml <<'NETEOF'
<network>
  <name>default</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.100' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
NETEOF
        virsh net-define /tmp/qemu-default-net.xml 2>/dev/null || true
        rm -f /tmp/qemu-default-net.xml
        _green "  ✓ Default NAT network defined"
    fi
    if ! virsh net-list --all 2>/dev/null | grep -q "default.*active"; then
        virsh net-start default 2>/dev/null || true
        virsh net-autostart default 2>/dev/null || true
        _green "  ✓ Default NAT network started"
    else
        virsh net-autostart default 2>/dev/null || true
        _green "  ✓ Default NAT network is running"
    fi
    # 保存网络网桥名
    local bridge_name
    bridge_name=$(virsh net-dumpxml default 2>/dev/null | grep '<bridge' | grep -oP 'name="\K[^"]+' || echo "virbr0")
    echo "$bridge_name" > /usr/local/bin/qemu_bridge
    _green "  ✓ Bridge interface: $bridge_name"
}

# ======== 配置 libvirt hooks 目录 ========
configure_hooks() {
    _yellow "Configuring libvirt hooks..."
    mkdir -p /etc/libvirt/hooks
    if [ ! -f /etc/libvirt/hooks/qemu ]; then
        cat > /etc/libvirt/hooks/qemu <<'HOOKEOF'
#!/bin/bash
# libvirt qemu hook - managed by oneclickvirt/qemu
# DO NOT EDIT MANUALLY
HOOKEOF
        chmod +x /etc/libvirt/hooks/qemu
        _green "  ✓ libvirt qemu hook initialized"
    else
        _green "  ✓ libvirt qemu hook already exists"
    fi
}

# ======== 配置 sysctl 转发参数 ========
configure_sysctl() {
    _yellow "Configuring sysctl for IP forwarding..."
    cat > /etc/sysctl.d/99-qemu.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-qemu.conf 2>/dev/null || true
    _green "IP forwarding enabled"
}

# ======== 检测公网 IPv4 ========
detect_interface() {
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    if [[ -z "$iface" ]]; then
        iface=$(ip link show | awk '/^[0-9]+: / && !/lo:/{gsub(":", "", $2); print $2; exit}')
    fi
    echo "$iface" > /usr/local/bin/qemu_main_interface
    _green "Main network interface: $iface"
}

# ======== 检测 IPv6 支持 ========
check_ipv6() {
    _yellow "Checking IPv6 support..."
    local ipv6_addr
    ipv6_addr=$(ip -6 addr show scope global 2>/dev/null | grep "inet6" | awk '{print $2}' | head -1)
    if [[ -n "$ipv6_addr" ]]; then
        echo "true" > /usr/local/bin/qemu_ipv6_enabled
        _green "  ✓ IPv6 available: $ipv6_addr"
    else
        echo "false" > /usr/local/bin/qemu_ipv6_enabled
        _yellow "  IPv6 not detected"
    fi
}

# ======== 初始化 SQLite 数据库 ========
init_database() {
    _yellow "Initializing VM database..."
    local db_file="/var/lib/libvirt/qemu-vms.db"
    if ! command -v sqlite3 >/dev/null 2>&1; then
        _yellow "  sqlite3 not available, skipping database init"
        return 0
    fi
    sqlite3 "$db_file" <<'SQLEOF'
CREATE TABLE IF NOT EXISTS vms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vm_name TEXT UNIQUE,
    ipv4 TEXT,
    mac TEXT,
    ssh_port INTEGER,
    start_port INTEGER,
    end_port INTEGER,
    cpu INTEGER,
    memory INTEGER,
    disk INTEGER,
    system TEXT,
    password TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
SQLEOF
    echo "$db_file" > /usr/local/bin/qemu_db_file
    _green "  ✓ VM database initialized: $db_file"
}

# ======== 验证安装 ========
verify_install() {
    _yellow "Verifying installation..."
    local all_ok=true
    for cmd in virsh virt-install qemu-img; do
        if command -v "$cmd" >/dev/null 2>&1; then
            _green "  ✓ $cmd: available"
        else
            _yellow "  ✗ $cmd not found"
            all_ok=false
        fi
    done
    if [[ -e /dev/kvm ]]; then
        _green "  ✓ KVM: /dev/kvm available"
    else
        _yellow "  ✗ KVM: /dev/kvm not available (performance degraded)"
    fi
    if $all_ok; then
        _green "All components installed successfully"
    else
        _yellow "Some components missing, please check manually"
    fi
}

# ======== 主流程 ========
main() {
    _blue "======================================================"
    _blue "  QEMU/KVM 虚拟机运行时一键安装脚本"
    _blue "  from https://github.com/oneclickvirt/qemu"
    _blue "  2026.03.02"
    _blue "======================================================"
    echo

    # 重新计算 int（系统类型索引）
    for ((int = 0; int < ${#REGEX[@]}; int++)); do
        if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
            break
        fi
    done

    reading "虚拟机镜像存储路径？（回车默认：/var/lib/libvirt/images）：" qemu_images_path
    if [ -z "$qemu_images_path" ]; then
        qemu_images_path="/var/lib/libvirt/images"
    fi
    mkdir -p "$qemu_images_path"
    echo "$qemu_images_path" > /usr/local/bin/qemu_images_path

    check_cdn_file
    echo "$cdn_success_url" > /usr/local/bin/qemu_cdn

    check_kvm_support
    install_base_deps
    install_qemu_stack
    start_libvirtd
    configure_storage_pool
    configure_default_network
    configure_hooks
    configure_sysctl
    detect_interface
    check_ipv6
    init_database

    # 保存架构信息
    echo "$ARCH_TYPE" > /usr/local/bin/qemu_arch

    verify_install

    echo
    _green "======================================================"
    _green "  ✓ QEMU/KVM 安装完成！"
    _green "======================================================"
    echo
    _blue "常用命令:"
    _yellow "  查看所有虚拟机:  virsh list --all"
    _yellow "  开设单个虚拟机:  bash scripts/oneqemu.sh <name> <cpu> <memory_mb> <disk_gb> <password> <sshport> <startport> <endport>"
    _yellow "  批量开设虚拟机:  bash scripts/create_qemu.sh"
    _yellow "  进入虚拟机控制台: virsh console <name>"
    _yellow "  项目地址:        https://github.com/oneclickvirt/qemu"
    echo
}

main "$@"
