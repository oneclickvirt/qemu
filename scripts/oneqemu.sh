#!/bin/bash
# from
# https://github.com/oneclickvirt/qemu
# 2026.03.02

# Usage:
# ./oneqemu.sh <name> <cpu> <memory_mb> <disk_gb> <password> <sshport> <startport> <endport> [system]
# Example:
# ./oneqemu.sh vm1 1 1024 20 MyPassword 25001 35001 35025 debian

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

# ======== 参数 ========
name="${1:-vm1}"
cpu="${2:-1}"
memory="${3:-1024}"
disk="${4:-20}"
passwd="${5:-123456}"
sshport="${6:-25001}"
startport="${7:-35001}"
endport="${8:-35025}"
system="${9:-debian}"

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

# ======== 架构及 CDN ========
ARCH_UNAME=$(uname -m)
case "$ARCH_UNAME" in
    x86_64)  ARCH_TYPE="amd64" ;;
    aarch64) ARCH_TYPE="arm64" ;;
    *)       ARCH_TYPE="amd64" ;;
esac
# 读取安装时保存的架构
if [[ -f /usr/local/bin/qemu_arch ]]; then
    ARCH_TYPE=$(cat /usr/local/bin/qemu_arch)
fi

# CDN
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
cdn_success_url=""
if [[ -f /usr/local/bin/qemu_cdn ]]; then
    cdn_success_url=$(cat /usr/local/bin/qemu_cdn)
fi

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
        _yellow "CDN available, using: $cdn_success_url"
    else
        _yellow "No CDN, using direct connection"
    fi
}

# 若没读取到 CDN，重新检测
if [[ -z "$cdn_success_url" ]]; then
    check_cdn_file
fi

# ======== 镜像存储路径 ========
images_path="/var/lib/libvirt/images"
if [[ -f /usr/local/bin/qemu_images_path ]]; then
    images_path=$(cat /usr/local/bin/qemu_images_path)
fi
mkdir -p "$images_path"

# ======== 网桥名称 ========
bridge_name="virbr0"
if [[ -f /usr/local/bin/qemu_bridge ]]; then
    bridge_name=$(cat /usr/local/bin/qemu_bridge)
fi

# ======== 主网卡 ========
main_interface=""
if [[ -f /usr/local/bin/qemu_main_interface ]]; then
    main_interface=$(cat /usr/local/bin/qemu_main_interface)
fi
if [[ -z "$main_interface" ]]; then
    main_interface=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
fi

# ======== 检查 virsh ========
if ! command -v virsh >/dev/null 2>&1; then
    _red "virsh not found. Please run qemuinstall.sh first."
    exit 1
fi

# ======== 检查 virt-install ========
if ! command -v virt-install >/dev/null 2>&1; then
    _red "virt-install not found. Please run qemuinstall.sh first."
    exit 1
fi

# ======== 标准化 system 名称 ========
system=$(echo "$system" | tr '[:upper:]' '[:lower:]')
case "$system" in
    debian|debian12|debian-12)
        system="debian"
        os_info="debian12"
        ;;
    ubuntu|ubuntu24|ubuntu-24|ubuntu2404)
        system="ubuntu"
        os_info="ubuntu24.04"
        ;;
    almalinux|alma|almalinux9|alma9)
        system="almalinux"
        os_info="almalinux9"
        ;;
    rockylinux|rocky|rocky9|rockylinux9)
        system="rockylinux"
        os_info="rhel9.0"
        ;;
    openeuler|euler)
        system="openeuler"
        os_info="rhel8.0"
        ;;
    *)
        _yellow "Unknown system '${system}', using debian"
        system="debian"
        os_info="debian12"
        ;;
esac

# ======== cloud 镜像官方回退 URL 映射 ========
# 仅在组织预置镜像下载失败时使用
get_official_image_url() {
    local sys="$1"
    local arch="$2"
    CLOUD_IMG_URL=""
    case "$sys" in
        debian)
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2"
            else
                CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
            fi
            ;;
        ubuntu)
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img"
            else
                CLOUD_IMG_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
            fi
            ;;
        almalinux)
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://repo.almalinux.org/almalinux/9/cloud/aarch64/images/AlmaLinux-9-GenericCloud-latest.aarch64.qcow2"
            else
                CLOUD_IMG_URL="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
            fi
            ;;
        rockylinux)
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://dl.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud-Base.latest.aarch64.qcow2"
            else
                CLOUD_IMG_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
            fi
            ;;
        openeuler)
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://repo.openeuler.org/openEuler-22.03-LTS-SP3/virtual_machine_img/aarch64/openEuler-22.03-LTS-SP3-aarch64.qcow2.xz"
            else
                CLOUD_IMG_URL="https://repo.openeuler.org/openEuler-22.03-LTS-SP3/virtual_machine_img/x86_64/openEuler-22.03-LTS-SP3-x86_64.qcow2.xz"
            fi
            ;;
    esac
}

# ======== 组织预置镜像版本映射 ========
# 返回 oneclickvirt 组织 kvm_images 系列 repo 中对应的版本标签
get_org_image_ver() {
    local sys="$1"
    case "$sys" in
        debian)     echo "debian12" ;;
        ubuntu)     echo "ubuntu22" ;;
        almalinux)  echo "almalinux9" ;;
        rockylinux) echo "rockylinux9" ;;
        *)          echo "" ;;
    esac
}

# 尝试从 oneclickvirt/pve_kvm_images 下载（最高优先级）
# 该仓库由 CI 自动构建，镜像名形如 debian12-cloud-20240101.qcow2
try_pve_kvm_images() {
    local ver="$1"       # e.g. debian12
    local img_path="$2"  # 本地保存路径

    _yellow "Trying oneclickvirt/pve_kvm_images for ${ver}..."
    local api_url="https://api.github.com/repos/oneclickvirt/pve_kvm_images/releases/tags/images"
    local images_list=""
    # GitHub API 直连（CDN 通常不代理 api.github.com）
    images_list=$(curl -slk -m 15 "$api_url" 2>/dev/null | \
        grep -o '"name":"[^"]*\.qcow2"' | sed 's/"name":"//;s/"//')
    if [[ -z "$images_list" ]] && [[ -n "$cdn_success_url" ]]; then
        images_list=$(curl -slk -m 15 "${cdn_success_url}${api_url}" 2>/dev/null | \
            grep -o '"name":"[^"]*\.qcow2"' | sed 's/"name":"//;s/"//')
    fi
    [[ -z "$images_list" ]] && return 1

    # 优先选择带 cloud 关键字的镜像，再按名称倒序取最新
    local selected=""
    selected=$(echo "$images_list" | grep "^${ver}" | sort -r | grep -i "cloud" | head -n1)
    [[ -z "$selected" ]] && selected=$(echo "$images_list" | grep "^${ver}" | sort -r | head -n1)
    [[ -z "$selected" ]] && return 1

    _yellow "  Org image: ${selected}"
    local url="${cdn_success_url}https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/${selected}"
    if wget -q --show-progress --connect-timeout=15 --timeout=600 \
            -O "${img_path}.tmp" "$url" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
        mv "${img_path}.tmp" "$img_path"
        _green "  ✓ Downloaded from pve_kvm_images: ${selected}"
        return 0
    fi
    rm -f "${img_path}.tmp" 2>/dev/null
    return 1
}

# 尝试从 oneclickvirt/kvm_images 下载（第二优先级）
# 该仓库手动维护，release tag = ver，文件名 = ${ver}.qcow2
try_kvm_images() {
    local ver="$1"       # e.g. debian12
    local img_path="$2"

    _yellow "Trying oneclickvirt/kvm_images for ${ver}..."
    local url="${cdn_success_url}https://github.com/oneclickvirt/kvm_images/releases/download/${ver}/${ver}.qcow2"
    if wget -q --show-progress --connect-timeout=15 --timeout=600 \
            -O "${img_path}.tmp" "$url" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
        mv "${img_path}.tmp" "$img_path"
        _green "  ✓ Downloaded from kvm_images: ${ver}.qcow2"
        return 0
    fi
    rm -f "${img_path}.tmp" 2>/dev/null
    return 1
}

# ======== 下载 cloud 基础镜像 ========
# 优先顺序：
#   1. oneclickvirt/pve_kvm_images（CI 自动构建）
#   2. oneclickvirt/kvm_images（手动维护）
#   3. 官方上游地址（兜底）
# 本地统一保存到 ${images_path}/${system}.qcow2
download_cloud_image() {
    local img_path="${images_path}/${system}.qcow2"

    if [[ -f "$img_path" ]] && [[ -s "$img_path" ]]; then
        _green "Base image already cached: $img_path"
        return 0
    fi

    _yellow "Base image not cached, downloading for system '${system}'..."

    # ---- 1. 尝试组织预置镜像 ----
    local org_ver
    org_ver=$(get_org_image_ver "$system")
    if [[ -n "$org_ver" ]]; then
        if try_pve_kvm_images "$org_ver" "$img_path"; then
            return 0
        fi
        if try_kvm_images "$org_ver" "$img_path"; then
            return 0
        fi
        _yellow "Org images unavailable, falling back to official upstream..."
    fi

    # ---- 2. 回退到官方上游地址 ----
    get_official_image_url "$system" "$ARCH_TYPE"
    if [[ -z "$CLOUD_IMG_URL" ]]; then
        _red "No upstream URL available for system: $system"
        exit 1
    fi

    _yellow "Downloading from official upstream: $CLOUD_IMG_URL"

    # xz 压缩镜像（如 openEuler）：先下载再解压
    if [[ "$CLOUD_IMG_URL" == *.xz ]]; then
        local xz_path="${img_path}.xz"
        local dl_ok=false
        if [[ -n "$cdn_success_url" ]]; then
            wget -q --show-progress --connect-timeout=15 --timeout=600 \
                -O "$xz_path" "${cdn_success_url}${CLOUD_IMG_URL}" 2>/dev/null && \
                [[ -s "$xz_path" ]] && dl_ok=true
        fi
        if [[ "$dl_ok" != true ]]; then
            wget -q --show-progress --connect-timeout=15 --timeout=600 \
                -O "$xz_path" "$CLOUD_IMG_URL" 2>/dev/null && [[ -s "$xz_path" ]] && dl_ok=true || true
        fi
        if [[ "$dl_ok" != true ]]; then
            curl -L --connect-timeout 15 --max-time 600 \
                -o "$xz_path" "$CLOUD_IMG_URL" 2>/dev/null && [[ -s "$xz_path" ]] && dl_ok=true || true
        fi
        if [[ "$dl_ok" = true ]]; then
            _yellow "Decompressing image..."
            if xz -d "$xz_path" 2>/dev/null; then
                local decompressed="${xz_path%.xz}"
                [[ "$decompressed" != "$img_path" ]] && mv "$decompressed" "$img_path" 2>/dev/null || true
            elif unxz "$xz_path" 2>/dev/null; then
                local decompressed="${xz_path%.xz}"
                [[ "$decompressed" != "$img_path" ]] && mv "$decompressed" "$img_path" 2>/dev/null || true
            fi
            if [[ -f "$img_path" ]] && [[ -s "$img_path" ]]; then
                _green "  ✓ Image decompressed: $img_path"
                return 0
            fi
        fi
        rm -f "$xz_path" 2>/dev/null
        _red "Failed to download/decompress image from: $CLOUD_IMG_URL"
        exit 1
    fi

    # 普通镜像下载
    if [[ -n "$cdn_success_url" ]]; then
        if wget -q --show-progress --connect-timeout=15 --timeout=600 \
                -O "${img_path}.tmp" "${cdn_success_url}${CLOUD_IMG_URL}" 2>/dev/null && \
                [[ -s "${img_path}.tmp" ]]; then
            mv "${img_path}.tmp" "$img_path"
            _green "  ✓ Downloaded via CDN"
            return 0
        fi
        rm -f "${img_path}.tmp" 2>/dev/null
    fi
    if wget -q --show-progress --connect-timeout=15 --timeout=600 \
            -O "${img_path}.tmp" "$CLOUD_IMG_URL" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
        mv "${img_path}.tmp" "$img_path"
        _green "  ✓ Downloaded directly"
        return 0
    fi
    if curl -L --connect-timeout 15 --max-time 600 --progress-bar \
            -o "${img_path}.tmp" "$CLOUD_IMG_URL" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
        mv "${img_path}.tmp" "$img_path"
        _green "  ✓ Downloaded via curl"
        return 0
    fi
    rm -f "${img_path}.tmp" 2>/dev/null
    _red "Failed to download image: $CLOUD_IMG_URL"
    exit 1
}

# ======== 生成 MAC 地址 ========
generate_mac() {
    printf '52:54:%02x:%02x:%02x:%02x\n' \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

# ======== 分配静态 IP ========
allocate_ip() {
    # 使用 192.168.122.2 ~ 192.168.122.99 范围静态分配
    # 查询已用的 DHCP 固定分配 IP 列表
    local base_ip="192.168.122"
    local used_ips
    used_ips=$(virsh net-dumpxml default 2>/dev/null | grep '<host ' | grep -oP "ip='[^']+'" | cut -d"'" -f2 | sort -t. -k4 -n)

    for ((i=2; i<=99; i++)); do
        local candidate="${base_ip}.${i}"
        if ! echo "$used_ips" | grep -qF "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    # 超出范围则从 100 开始
    for ((i=100; i<=254; i++)); do
        local candidate="${base_ip}.${i}"
        if ! echo "$used_ips" | grep -qF "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    _red "No available IP in 192.168.122.0/24"
    exit 1
}

# ======== 创建 cloud-init 配置 ========
create_cloudinit() {
    local vm_name="$1"
    local password="$2"
    local tmp_yaml="/tmp/qemu-cloudinit-${vm_name}.yaml"
    local tmp_iso="${images_path}/vm-${vm_name}-cloudinit.iso"

    cat > "$tmp_yaml" <<CIEOF
#cloud-config
hostname: ${vm_name}
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  list:
    - root:${password}
write_files:
  - path: /etc/ssh/sshd_config.d/99-qemu.conf
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
      PubkeyAuthentication yes
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent 2>/dev/null || true
  - systemctl start qemu-guest-agent 2>/dev/null || true
  - systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  - systemctl enable --now serial-getty@ttyS0.service 2>/dev/null || true
  - shutdown -P now
CIEOF

    # 生成 cloud-init ISO (NoCloud 数据源)
    local meta_yaml="/tmp/qemu-cloudinit-${vm_name}-meta.yaml"
    cat > "$meta_yaml" <<METAEOF
instance-id: ${vm_name}
local-hostname: ${vm_name}
METAEOF

    # 使用 cloud-localds 或 genisoimage 创建 ISO
    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$tmp_iso" "$tmp_yaml" "$meta_yaml"
    elif command -v genisoimage >/dev/null 2>&1; then
        local ci_dir="/tmp/qemu-ci-${vm_name}"
        mkdir -p "$ci_dir"
        cp "$tmp_yaml" "$ci_dir/user-data"
        cp "$meta_yaml" "$ci_dir/meta-data"
        genisoimage -output "$tmp_iso" -volid cidata -joliet -rock "$ci_dir" 2>/dev/null
        rm -rf "$ci_dir"
    elif command -v mkisofs >/dev/null 2>&1; then
        local ci_dir="/tmp/qemu-ci-${vm_name}"
        mkdir -p "$ci_dir"
        cp "$tmp_yaml" "$ci_dir/user-data"
        cp "$meta_yaml" "$ci_dir/meta-data"
        mkisofs -output "$tmp_iso" -volid cidata -joliet -rock "$ci_dir" 2>/dev/null
        rm -rf "$ci_dir"
    else
        _red "No ISO creation tool found (cloud-localds / genisoimage / mkisofs)"
        _red "Please install: apt-get install cloud-image-utils"
        exit 1
    fi

    rm -f "$tmp_yaml" "$meta_yaml"
    echo "$tmp_iso"
}

# ======== 创建 VM 磁盘 ========
create_disk() {
    local vm_name="$1"
    local disk_gb="$2"
    local base_img="${images_path}/${system}.qcow2"
    local vm_disk="${images_path}/vm-${vm_name}.qcow2"

    _yellow "Creating VM disk: ${vm_disk} (${disk_gb}GB backing ${system}.qcow2)"
    # 从 cloud image 创建差量磁盘（backing store）
    qemu-img create -f qcow2 -b "$base_img" -F qcow2 "$vm_disk" "${disk_gb}G"
    echo "$vm_disk"
}

# ======== 配置端口转发 ========
configure_port_forwarding() {
    local vm_name="$1"
    local vm_ip="$2"
    local ssh_port="$3"
    local start_p="$4"
    local end_p="$5"
    local iface="$bridge_name"

    _yellow "Configuring port forwarding for ${vm_name}: SSH=${ssh_port}, ports ${start_p}-${end_p}"

    # 在 /etc/libvirt/hooks/qemu 中追加规则
    # 先添加标识符（用于删除）
    if ! grep -q "#${vm_name}#" /etc/libvirt/hooks/qemu 2>/dev/null; then
        cat >> /etc/libvirt/hooks/qemu <<HOOKEOF

#${vm_name}#
if [ "\${1}" = "${vm_name}" ]; then
    if [ "\${2}" = "stopped" ] || [ "\${2}" = "reconnect" ]; then
        /sbin/iptables -t nat -D PREROUTING -p tcp --dport ${ssh_port} -j DNAT --to ${vm_ip}:22 2>/dev/null || true
        /sbin/iptables -D FORWARD -o ${iface} -p tcp -d ${vm_ip} --dport 22 -j ACCEPT 2>/dev/null || true
        /sbin/iptables -t nat -D PREROUTING -p udp --dport ${ssh_port} -j DNAT --to ${vm_ip}:22 2>/dev/null || true
HOOKEOF
        # 输出各端口的删除规则
        for ((port=start_p; port<=end_p; port++)); do
            cat >> /etc/libvirt/hooks/qemu <<PORTEOF
        /sbin/iptables -t nat -D PREROUTING -p tcp --dport ${port} -j DNAT --to ${vm_ip}:${port} 2>/dev/null || true
        /sbin/iptables -D FORWARD -o ${iface} -p tcp -d ${vm_ip} --dport ${port} -j ACCEPT 2>/dev/null || true
        /sbin/iptables -t nat -D PREROUTING -p udp --dport ${port} -j DNAT --to ${vm_ip}:${port} 2>/dev/null || true
        /sbin/iptables -D FORWARD -o ${iface} -p udp -d ${vm_ip} --dport ${port} -j ACCEPT 2>/dev/null || true
PORTEOF
        done
        cat >> /etc/libvirt/hooks/qemu <<HOOKEOF2
    fi
    if [ "\${2}" = "start" ] || [ "\${2}" = "reconnect" ]; then
        /sbin/iptables -t nat -I PREROUTING -p tcp --dport ${ssh_port} -j DNAT --to ${vm_ip}:22
        /sbin/iptables -I FORWARD -o ${iface} -p tcp -d ${vm_ip} --dport 22 -j ACCEPT
        /sbin/iptables -t nat -I PREROUTING -p udp --dport ${ssh_port} -j DNAT --to ${vm_ip}:22
HOOKEOF2
        for ((port=start_p; port<=end_p; port++)); do
            cat >> /etc/libvirt/hooks/qemu <<PORTEOF2
        /sbin/iptables -t nat -I PREROUTING -p tcp --dport ${port} -j DNAT --to ${vm_ip}:${port}
        /sbin/iptables -I FORWARD -o ${iface} -p tcp -d ${vm_ip} --dport ${port} -j ACCEPT
        /sbin/iptables -t nat -I PREROUTING -p udp --dport ${port} -j DNAT --to ${vm_ip}:${port}
        /sbin/iptables -I FORWARD -o ${iface} -p udp -d ${vm_ip} --dport ${port} -j ACCEPT
PORTEOF2
        done
        cat >> /etc/libvirt/hooks/qemu <<HOOKEOF3
    fi
fi
###${vm_name}###
HOOKEOF3
    fi

    # 立即应用 iptables 规则（无需重启 VM）
    iptables -t nat -I PREROUTING -p tcp --dport "${ssh_port}" -j DNAT --to "${vm_ip}:22" 2>/dev/null || true
    iptables -I FORWARD -o "${iface}" -p tcp -d "${vm_ip}" --dport 22 -j ACCEPT 2>/dev/null || true
    iptables -t nat -I PREROUTING -p udp --dport "${ssh_port}" -j DNAT --to "${vm_ip}:22" 2>/dev/null || true
    iptables -t nat -I POSTROUTING -s "192.168.122.0/24" ! -d "192.168.122.0/24" -j MASQUERADE 2>/dev/null || true
    iptables -I FORWARD -s "192.168.122.0/24" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD -d "192.168.122.0/24" -j ACCEPT 2>/dev/null || true
    for ((port=start_p; port<=end_p; port++)); do
        iptables -t nat -I PREROUTING -p tcp --dport "${port}" -j DNAT --to "${vm_ip}:${port}" 2>/dev/null || true
        iptables -I FORWARD -o "${iface}" -p tcp -d "${vm_ip}" --dport "${port}" -j ACCEPT 2>/dev/null || true
        iptables -t nat -I PREROUTING -p udp --dport "${port}" -j DNAT --to "${vm_ip}:${port}" 2>/dev/null || true
        iptables -I FORWARD -o "${iface}" -p udp -d "${vm_ip}" --dport "${port}" -j ACCEPT 2>/dev/null || true
    done

    # 持久化保存
    netfilter-persistent save 2>/dev/null || \
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        service iptables save 2>/dev/null || true

    _green "Port forwarding configured"
}

# ======== 检测公网 IP ========
IPV4=""
check_ipv4() {
    local API_NET=("ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
    for p in "${API_NET[@]}"; do
        local response
        response=$(curl -s4m8 "$p" 2>/dev/null | tr -d '[:space:]')
        if [[ $? -eq 0 && -n "$response" ]] && ! echo "$response" | grep -q "error"; then
            IPV4="$response"
            return 0
        fi
        sleep 0.5
    done
    # fallback：从路由获取本机 IP
    IPV4=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
}

# ======== 等待 VM 关机（cloud-init 第一次启动后执行 shutdown）========
wait_for_shutdown() {
    local vm_name="$1"
    _yellow "Waiting for VM first-boot setup to complete (cloud-init)..."
    local max_wait=300  # 最多等待 5 分钟
    local elapsed=0
    while true; do
        local state
        state=$(virsh domstate "$vm_name" 2>/dev/null || echo "error")
        if [[ "$state" == "shut off" ]]; then
            _green "  ✓ VM first-boot done, VM is shut down"
            return 0
        fi
        if (( elapsed >= max_wait )); then
            _yellow "  ⚠ Timeout waiting for shutdown after ${max_wait}s, continuing anyway..."
            return 1
        fi
        sleep 5
        (( elapsed += 5 ))
        echo -n "."
    done
    echo ""
}

# ======== 主逻辑 ========
main() {
    _blue "Creating VM: name=${name} cpu=${cpu} memory=${memory}MB disk=${disk}GB system=${system}"
    _blue "SSH port: ${sshport}  port range: ${startport}-${endport}"

    _blue "Base image: ${images_path}/${system}.qcow2"

    # 下载 cloud 基础镜像（优先使用组织预置镜像，再回退官方上游）
    download_cloud_image

    # 生成 MAC 地址
    local vm_mac
    vm_mac=$(generate_mac)
    _blue "VM MAC: $vm_mac"

    # 分配静态 IP
    local vm_ip
    vm_ip=$(allocate_ip)
    _blue "VM IP: $vm_ip"

    # 创建 VM 磁盘
    local vm_disk
    vm_disk=$(create_disk "$name" "$disk")

    # 创建 cloud-init ISO
    _yellow "Creating cloud-init configuration..."
    local ci_iso
    ci_iso=$(create_cloudinit "$name" "$passwd")
    _green "  ✓ cloud-init ISO: $ci_iso"

    # 部署虚拟机
    _yellow "Deploying VM with virt-install..."
    local extra_args=""
    if [[ "$ARCH_TYPE" == "aarch64" || "$ARCH_TYPE" == "arm64" ]]; then
        extra_args="--boot uefi=off"
    fi

    virt-install \
        --name "$name" \
        --memory "$memory" \
        --vcpus "$cpu" \
        --disk "path=${vm_disk},format=qcow2,bus=virtio,cache=none" \
        --disk "path=${ci_iso},device=cdrom,bus=scsi" \
        --network "bridge=${bridge_name},mac=${vm_mac},model=virtio" \
        --os-variant "$os_info" \
        --graphics none \
        --serial pty \
        --console pty,target_type=serial \
        --noautoconsole \
        $extra_args \
        2>/dev/null

    if [[ $? -ne 0 ]]; then
        _red "virt-install failed! Trying without --os-variant..."
        virt-install \
            --name "$name" \
            --memory "$memory" \
            --vcpus "$cpu" \
            --disk "path=${vm_disk},format=qcow2,bus=virtio,cache=none" \
            --disk "path=${ci_iso},device=cdrom,bus=scsi" \
            --network "bridge=${bridge_name},mac=${vm_mac},model=virtio" \
            --graphics none \
            --serial pty \
            --console pty,target_type=serial \
            --noautoconsole \
            $extra_args
        if [[ $? -ne 0 ]]; then
            _red "VM deployment failed"
            # 清理
            virsh undefine "$name" 2>/dev/null || true
            rm -f "$vm_disk" "$ci_iso" 2>/dev/null || true
            exit 1
        fi
    fi

    _green "  ✓ VM created: $name"

    # 等待 VM 第一次启动完成（cloud-init 执行 shutdown）
    wait_for_shutdown "$name"

    # 在 libvirt default 网络中设置 DHCP 固定 IP
    _yellow "Setting DHCP reservation: $vm_mac -> $vm_ip"
    virsh net-update default add ip-dhcp-host \
        "<host mac='${vm_mac}' name='${name}' ip='${vm_ip}' />" \
        --live --config 2>/dev/null || \
    virsh net-update default add ip-dhcp-host \
        "<host mac='${vm_mac}' name='${name}' ip='${vm_ip}' />" \
        --config 2>/dev/null || true
    _green "  ✓ DHCP reservation: $vm_mac -> $vm_ip"

    # 配置端口转发
    configure_port_forwarding "$name" "$vm_ip" "$sshport" "$startport" "$endport"

    # 重新启动 libvirtd，使 hooks 生效
    _yellow "Restarting libvirtd to apply hooks..."
    systemctl restart libvirtd 2>/dev/null || systemctl restart libvirt-daemon 2>/dev/null || true
    sleep 2

    # 启动 VM
    _yellow "Starting VM: $name"
    virsh start "$name"
    if [[ $? -ne 0 ]]; then
        _red "Failed to start VM $name"
        exit 1
    fi
    _green "  ✓ VM ${name} started"

    # 设置 VM 开机自启
    virsh autostart "$name" 2>/dev/null || true

    # 检测公网 IP
    check_ipv4

    # 获取公网 IP
    echo ""
    _green "======================================================"
    _green "  ✓ VM ${name} 创建成功！"
    _green "======================================================"
    _green "  系统:     ${system}"
    _green "  CPU:      ${cpu} 核"
    _green "  内存:     ${memory} MB"
    _green "  磁盘:     ${disk} GB"
    _green "  VM IP:    ${vm_ip} (内网)"
    if [[ -n "$IPV4" ]]; then
        _green "  公网 IP:  ${IPV4}"
        _green "  SSH:      ssh root@${IPV4} -p ${sshport}"
    else
        _green "  SSH 端口: ${sshport}  (通过宿主机公网 IP 连接)"
    fi
    _green "  密码:     ${passwd}"
    _green "  端口映射: ${startport}-${endport} → ${startport}-${endport} (NAT)"
    _green "======================================================"

    # 记录到日志文件
    echo "${name} ${sshport} ${passwd} ${cpu} ${memory} ${disk} ${startport} ${endport} ${system} ${vm_ip}" >> /root/vmlog
    _green "VM info saved to /root/vmlog"
}

main "$@"
