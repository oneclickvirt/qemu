#!/bin/bash
# from
# https://github.com/oneclickvirt/qemu
# 2026.03.02

# Usage:
# ./oneqemu.sh <name> <cpu> <memory_mb> <disk_gb> <password> <sshport> <startport> <endport> [system]
# ./oneqemu.sh <name> <cpu> <memory_mb> <disk_gb> <password> <sshport> <startport> <endport> <extra_flag(y/n)> [system]
# Example:
# ./oneqemu.sh vm1 1 1024 20 MyPassword 25001 35001 35025 debian
# ./oneqemu.sh vm1 1 1024 20 MyPassword 25001 35001 35025 n debian13

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
# $9 可能为附加标志（如 y/n），$10 可能才是系统名
# 若 $9 非空且不像 y/n/yes/no 这类纯标志，则作为系统名；否则取 $10
_raw9="${9:-}"
_raw10="${10:-}"
if [[ -n "$_raw10" && ("$_raw9" == "y" || "$_raw9" == "n" || "$_raw9" == "yes" || "$_raw9" == "no") ]]; then
    system="$_raw10"
elif [[ -n "$_raw9" ]]; then
    system="$_raw9"
else
    system="debian"
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

# ======== 解析 system 名称与版本 ========
# 支持格式：debian / debian12 / debian-12 / ubuntu22 / ubuntu2204 / almalinux9 / rocky8 等
system=$(echo "$system" | tr '[:upper:]' '[:lower:]')

# 规范化别名（alma→almalinux，rocky→rockylinux，euler→openeuler）
case "$system" in
    alma*) system=$(echo "$system" | sed 's/^alma/almalinux/') ;;
    rocky*) system=$(echo "$system" | sed 's/^rocky/rockylinux/') ;;
    euler*) system="openeuler" ;;
esac

# 去掉分隔符（ubuntu-22→ubuntu22，ubuntu_22→ubuntu22）
# 注意：tr -d '-_' 中 - 开头会被误判为选项，需将 - 置于末尾
system=$(echo "$system" | tr -d '_-')

# 4 位 Ubuntu 版本号缩短（ubuntu2204→ubuntu22，ubuntu2404→ubuntu24）
system=$(echo "$system" | sed 's/^\(ubuntu\)\([0-9][0-9]\)[0-9][0-9]$/\1\2/')

# 拆分名称部分与版本部分
en_system=$(echo "$system" | sed 's/[0-9]*$//')
num_system=$(echo "$system" | sed 's/^[a-z]*//')

# 验证系统名称
case "$en_system" in
    debian|ubuntu|almalinux|rockylinux|openeuler) ;;
    *)
        _yellow "Unknown system '${system}', using debian12"
        en_system="debian"
        num_system="12"
        ;;
esac

# 没有指定版本时使用默认版本
if [[ -z "$num_system" ]]; then
    case "$en_system" in
        debian)     num_system="12" ;;
        ubuntu)     num_system="22" ;;
        almalinux)  num_system="9"  ;;
        rockylinux) num_system="9"  ;;
        openeuler)  num_system="22" ;;
    esac
fi

# 拼接标准名称（用于镜像文件缓存命名及下载版本 ID）
system="${en_system}${num_system}"

# 设置 virt-install 使用的 os-variant
case "$en_system" in
    debian)
        case "$num_system" in
            10) os_info="debian10" ;;
            11) os_info="debian11" ;;
            12) os_info="debian12" ;;
            13) os_info="debian13" ;;
            *)  os_info="debian12" ;;
        esac ;;
    ubuntu)
        case "$num_system" in
            18) os_info="ubuntu18.04" ;;
            20) os_info="ubuntu20.04" ;;
            22) os_info="ubuntu22.04" ;;
            24) os_info="ubuntu24.04" ;;
            *)  os_info="ubuntu22.04" ;;
        esac ;;
    almalinux)
        case "$num_system" in
            8)  os_info="almalinux8" ;;
            9)  os_info="almalinux9" ;;
            *)  os_info="almalinux9" ;;
        esac ;;
    rockylinux)
        case "$num_system" in
            8)  os_info="rhel8.0" ;;
            9)  os_info="rhel9.0" ;;
            *)  os_info="rhel9.0" ;;
        esac ;;
    openeuler)
        os_info="rhel8.0" ;;
esac

# ======== cloud 镜像官方回退 URL 映射 ========
# 仅在组织预置镜像下载失败时使用
# 参数：en_sys（系统名称，如 debian），num_sys（版本号，如 12），arch（amd64/arm64）
get_official_image_url() {
    local en_sys="$1"
    local num_sys="$2"
    local arch="$3"
    CLOUD_IMG_URL=""
    case "$en_sys" in
        debian)
            local codename
            case "$num_sys" in
                10) codename="buster"   ;;
                11) codename="bullseye" ;;
                12) codename="bookworm" ;;
                13) codename="trixie"   ;;
                *)  codename="bookworm"; num_sys="12" ;;
            esac
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/${codename}/latest/debian-${num_sys}-generic-arm64.qcow2"
            else
                CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/${codename}/latest/debian-${num_sys}-generic-amd64.qcow2"
            fi
            ;;
        ubuntu)
            local codename full_ver
            case "$num_sys" in
                18) codename="bionic"; full_ver="18.04" ;;
                20) codename="focal";  full_ver="20.04" ;;
                22) codename="jammy";  full_ver="22.04" ;;
                24) codename="noble";  full_ver="24.04" ;;
                *)  codename="jammy";  full_ver="22.04" ;;
            esac
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://cloud-images.ubuntu.com/minimal/releases/${codename}/release/ubuntu-${full_ver}-minimal-cloudimg-arm64.img"
            else
                CLOUD_IMG_URL="https://cloud-images.ubuntu.com/minimal/releases/${codename}/release/ubuntu-${full_ver}-minimal-cloudimg-amd64.img"
            fi
            ;;
        almalinux)
            local ver="${num_sys:-9}"
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://repo.almalinux.org/almalinux/${ver}/cloud/aarch64/images/AlmaLinux-${ver}-GenericCloud-latest.aarch64.qcow2"
            else
                CLOUD_IMG_URL="https://repo.almalinux.org/almalinux/${ver}/cloud/x86_64/images/AlmaLinux-${ver}-GenericCloud-latest.x86_64.qcow2"
            fi
            ;;
        rockylinux)
            local ver="${num_sys:-9}"
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://dl.rockylinux.org/pub/rocky/${ver}/images/aarch64/Rocky-${ver}-GenericCloud-Base.latest.aarch64.qcow2"
            else
                CLOUD_IMG_URL="https://dl.rockylinux.org/pub/rocky/${ver}/images/x86_64/Rocky-${ver}-GenericCloud-Base.latest.x86_64.qcow2"
            fi
            ;;
        openeuler)
            local eu_ver
            case "$num_sys" in
                20) eu_ver="20.03-LTS-SP3" ;;
                22) eu_ver="22.03-LTS-SP3" ;;
                *)  eu_ver="22.03-LTS-SP3" ;;
            esac
            if [[ "$arch" == "arm64" ]]; then
                CLOUD_IMG_URL="https://repo.openeuler.org/openEuler-${eu_ver}/virtual_machine_img/aarch64/openEuler-${eu_ver}-aarch64.qcow2.xz"
            else
                CLOUD_IMG_URL="https://repo.openeuler.org/openEuler-${eu_ver}/virtual_machine_img/x86_64/openEuler-${eu_ver}-x86_64.qcow2.xz"
            fi
            ;;
    esac
}

# 尝试从 oneclickvirt/pve_kvm_images 下载（最高优先级）
# 支持两种 release tag 格式：
#   tag=images : .../releases/download/images/debian12.qcow2
#   tag=<sys>  : .../releases/download/debian/debian12.qcow2
try_pve_kvm_images() {
    local ver="$1"       # e.g. debian12
    local img_path="$2"  # 本地保存路径
    local sys="$3"       # e.g. debian

    _yellow "Trying oneclickvirt/pve_kvm_images for ${ver}..."

    # 直接按已知 URL 模式尝试，不依赖 GitHub API
    # 优先使用 tag=<sys> 的系统专项 release，次优先使用 tag=images 的通用 release
    local candidate_urls=(
        "https://github.com/oneclickvirt/pve_kvm_images/releases/download/${sys}/${ver}.qcow2"
        "https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/${ver}.qcow2"
    )

    for base_url in "${candidate_urls[@]}"; do
        _yellow "  Trying: ${base_url}"
        # 优先走 CDN
        local try_url="${cdn_success_url}${base_url}"
        if curl -fL --progress-bar --connect-timeout 30 --max-time 600 \
                -o "${img_path}.tmp" "$try_url" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
            mv "${img_path}.tmp" "$img_path"
            _green "  ✓ Downloaded from pve_kvm_images: ${base_url##*/}"
            return 0
        fi
        rm -f "${img_path}.tmp" 2>/dev/null
        # 直连回退
        if curl -fsSL --connect-timeout 30 --max-time 600 \
                -o "${img_path}.tmp" "$base_url" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
            mv "${img_path}.tmp" "$img_path"
            _green "  ✓ Downloaded from pve_kvm_images (direct): ${base_url##*/}"
            return 0
        fi
        rm -f "${img_path}.tmp" 2>/dev/null
    done
    return 1
}

# 尝试从 oneclickvirt/kvm_images 下载（第二优先级）
# 该仓库手动维护，release tag = ver，文件名 = ${ver}.qcow2
try_kvm_images() {
    local ver="$1"       # e.g. debian12
    local img_path="$2"

    _yellow "Trying oneclickvirt/kvm_images for ${ver}..."
    local base_url="https://github.com/oneclickvirt/kvm_images/releases/download/${ver}/${ver}.qcow2"
    local url="${cdn_success_url}${base_url}"
    if curl -fL --progress-bar --connect-timeout 30 --max-time 600 \
            -o "${img_path}.tmp" "$url" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
        mv "${img_path}.tmp" "$img_path"
        _green "  ✓ Downloaded from kvm_images: ${ver}.qcow2"
        return 0
    fi
    rm -f "${img_path}.tmp" 2>/dev/null
    # 直连回退（无 CDN）
    if curl -fsSL --connect-timeout 30 --max-time 600 \
            -o "${img_path}.tmp" "$base_url" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
        mv "${img_path}.tmp" "$img_path"
        _green "  ✓ Downloaded from kvm_images (direct): ${ver}.qcow2"
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
    # system 已包含版本（如 debian12），en_system 为名称部分（如 debian）
    if try_pve_kvm_images "$system" "$img_path" "$en_system"; then
        return 0
    fi
    if try_kvm_images "$system" "$img_path"; then
        return 0
    fi
    _yellow "Org images unavailable, falling back to official upstream..."

    # ---- 2. 回退到官方上游地址 ----
    get_official_image_url "$en_system" "$num_system" "$ARCH_TYPE"
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
            curl -fL --progress-bar --connect-timeout 15 --max-time 600 \
                -o "$xz_path" "${cdn_success_url}${CLOUD_IMG_URL}" 2>/dev/null && \
                [[ -s "$xz_path" ]] && dl_ok=true
        fi
        if [[ "$dl_ok" != true ]]; then
            curl -fL --progress-bar --connect-timeout 15 --max-time 600 \
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
        if curl -fL --progress-bar --connect-timeout 15 --max-time 600 \
                -o "${img_path}.tmp" "${cdn_success_url}${CLOUD_IMG_URL}" 2>/dev/null && \
                [[ -s "${img_path}.tmp" ]]; then
            mv "${img_path}.tmp" "$img_path"
            _green "  ✓ Downloaded via CDN"
            return 0
        fi
        rm -f "${img_path}.tmp" 2>/dev/null
    fi
    if curl -fL --progress-bar --connect-timeout 15 --max-time 600 \
            -o "${img_path}.tmp" "$CLOUD_IMG_URL" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
        mv "${img_path}.tmp" "$img_path"
        _green "  ✓ Downloaded directly"
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
    _red "No available IP in 192.168.122.0/24" >&2
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
        _red "No ISO creation tool found (cloud-localds / genisoimage / mkisofs)" >&2
        _red "Please install: apt-get install cloud-image-utils" >&2
        exit 1
    fi

    rm -f "$tmp_yaml" "$meta_yaml"
    # 验证 ISO 确实已生成
    if [[ ! -s "$tmp_iso" ]]; then
        echo "ERROR: cloud-init ISO was not created: $tmp_iso" >&2
        exit 1
    fi
    echo "$tmp_iso"
}

# ======== 创建 VM 磁盘 ========
create_disk() {
    local vm_name="$1"
    local disk_gb="$2"
    local base_img="${images_path}/${system}.qcow2"
    local vm_disk="${images_path}/vm-${vm_name}.qcow2"

    _yellow "Creating VM disk: ${vm_disk} (${disk_gb}GB backing ${system}.qcow2)" >&2
    # 从 cloud image 创建差量磁盘（backing store）
    if ! qemu-img create -f qcow2 -b "$base_img" -F qcow2 "$vm_disk" "${disk_gb}G" >&2; then
        echo "ERROR: qemu-img create failed for $vm_disk" >&2
        exit 1
    fi
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
    # 使用行首匹配，避免 ###vm1### 结束标记被误匹
    if ! grep -qE "^#${vm_name}#$" /etc/libvirt/hooks/qemu 2>/dev/null; then
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

    # 确保 NAT 出站和通用转发规则存在（libvirt default 网络 MASQUERADE，仅需一次）
    iptables -t nat -I POSTROUTING -s "192.168.122.0/24" ! -d "192.168.122.0/24" -j MASQUERADE 2>/dev/null || true
    iptables -I FORWARD -s "192.168.122.0/24" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD -d "192.168.122.0/24" -j ACCEPT 2>/dev/null || true
    # 注意：per-VM 的 DNAT/FORWARD 端口规则不在此处立即写入，
    # 统一由 /etc/libvirt/hooks/qemu 在 virsh start 时触发，避免重复。

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

# ======== 检查 libvirt default 网络是否就绪 ========
# 网络的创建/定义由 qemuinstall.sh 负责，卸载由 qemuuninstall.sh 负责
# 此处只负责：确认 libvirtd 在跑、网络已定义、网络已激活
ensure_default_network() {
    _yellow "Checking libvirt default NAT network..."

    # 确保 libvirtd 正在运行
    if ! virsh list >/dev/null 2>&1; then
        _yellow "  libvirtd not responding, trying to start..."
        systemctl start libvirtd 2>/dev/null || \
            systemctl start libvirt-daemon 2>/dev/null || \
            service libvirtd start 2>/dev/null || true
        sleep 3
        if ! virsh list >/dev/null 2>&1; then
            _red "  libvirtd is not running. Please run qemuinstall.sh first."
            exit 1
        fi
    fi

    # 若 default 网络未定义，说明还没有执行过安装脚本
    if ! virsh net-info default >/dev/null 2>&1; then
        _red "  libvirt 'default' network is not defined."
        _red "  Please run qemuinstall.sh first to set up the environment."
        exit 1
    fi

    # 若 default 网络已定义但未激活，尝试启动（如宿主机重启后 autostart 未生效）
    if ! virsh net-list 2>/dev/null | grep -q "default.*active"; then
        _yellow "  default network is defined but not active, starting..."
        virsh net-start default 2>/dev/null || true
        sleep 2
    fi

    # 更新 bridge_name（以 libvirt 当前配置为准）
    local detected_bridge
    detected_bridge=$(virsh net-dumpxml default 2>/dev/null \
        | grep '<bridge' \
        | grep -oP 'name="\K[^"]+' \
        || echo "virbr0")
    bridge_name="$detected_bridge"
    echo "$bridge_name" > /usr/local/bin/qemu_bridge

    # 等待网桥接口出现在内核（net-start 后稍有延迟）
    if ! ip link show "$bridge_name" >/dev/null 2>&1; then
        _yellow "  Bridge $bridge_name not yet visible, waiting 3s..."
        sleep 3
    fi

    if virsh net-list 2>/dev/null | grep -q "default.*active"; then
        _green "  ✓ Default NAT network is active (bridge: $bridge_name)"
    else
        _red "  ✗ Failed to activate default NAT network."
        _red "  Please re-run qemuinstall.sh to repair the environment."
        exit 1
    fi
}

# ======== 后台守护：cloud-init 首次关机后自动重启 VM ========
# 参考 bashvm 的处理方式：不阻塞主脚本，由后台进程完成"等待关机→重启"
# 日志写入 /tmp/qemu-init-<name>.log，方便排查
spawn_restart_daemon() {
    local vm_name="$1"
    local log_file="/tmp/qemu-init-${vm_name}.log"
    # 使用 nohup + 独立子 shell，主脚本退出后仍继续运行
    nohup bash -c "
        echo \"[\$(date)] Waiting for cloud-init firstboot shutdown of ${vm_name}...\" >> \"${log_file}\"
        max_wait=600   # 最多等 10 分钟（包含 apt 安装耗时）
        elapsed=0
        while true; do
            state=\$(virsh domstate '${vm_name}' 2>/dev/null || echo 'error')
            if [[ \"\$state\" == 'shut off' ]]; then
                echo \"[\$(date)] VM ${vm_name} has shut off (cloud-init done). Starting...\" >> \"${log_file}\"
                virsh start '${vm_name}' >> \"${log_file}\" 2>&1
                echo \"[\$(date)] Done.\" >> \"${log_file}\"
                exit 0
            fi
            if (( elapsed >= max_wait )); then
                echo \"[\$(date)] Timeout \${max_wait}s waiting for shutdown. Forcing off then starting...\" >> \"${log_file}\"
                virsh destroy '${vm_name}' >> \"${log_file}\" 2>&1 || true
                sleep 3
                virsh start  '${vm_name}' >> \"${log_file}\" 2>&1
                exit 1
            fi
            sleep 5
            (( elapsed += 5 ))
        done
    " >> "$log_file" 2>&1 &
    disown
    _yellow "  Cloud-init running in background. VM will auto-restart when done."
    _yellow "  Progress: tail -f ${log_file}"
}

# ======== 主逻辑 ========
main() {
    _blue "Creating VM: name=${name} cpu=${cpu} memory=${memory}MB disk=${disk}GB system=${system}"
    _blue "SSH port: ${sshport}  port range: ${startport}-${endport}"

    # 确保 libvirt 默认 NAT 网络就绪（virbr0 必须存在才能使用 virt-install）
    ensure_default_network

    _blue "Base image: ${images_path}/${system}.qcow2"

    # 下载 cloud 基础镜像（优先使用组织预置镜像，再回退官方上游）
    download_cloud_image

    # 生成 MAC 地址
    local vm_mac
    vm_mac=$(generate_mac)
    _blue "VM MAC: $vm_mac"

    # 分配静态 IP
    local vm_ip
    vm_ip=$(allocate_ip) || { _red "Failed to allocate IP address"; exit 1; }
    _blue "VM IP: $vm_ip"

    # 创建 VM 磁盘
    local vm_disk
    vm_disk=$(create_disk "$name" "$disk") || { _red "Failed to create VM disk"; exit 1; }

    # 创建 cloud-init ISO
    _yellow "Creating cloud-init configuration..."
    local ci_iso
    ci_iso=$(create_cloudinit "$name" "$passwd") || { _red "Failed to create cloud-init ISO"; exit 1; }
    _green "  ✓ cloud-init ISO: $ci_iso"

    # ── 先配置好网络/钩子，再启动 VM（参考 bashvm 的做法）──────────────

    # 在 libvirt default 网络中设置 DHCP 固定 IP（MAC 已知，无需等待首次启动）
    _yellow "Setting DHCP reservation: $vm_mac -> $vm_ip"
    virsh net-update default add ip-dhcp-host \
        "<host mac='${vm_mac}' name='${name}' ip='${vm_ip}' />" \
        --live --config 2>/dev/null || \
    virsh net-update default add ip-dhcp-host \
        "<host mac='${vm_mac}' name='${name}' ip='${vm_ip}' />" \
        --config 2>/dev/null || true
    _green "  ✓ DHCP reservation: $vm_mac -> $vm_ip"

    # 配置端口转发（写入 /etc/libvirt/hooks/qemu）
    configure_port_forwarding "$name" "$vm_ip" "$sshport" "$startport" "$endport"

    # 重启 libvirtd 使 hooks 生效，再确认网络就绪
    _yellow "Restarting libvirtd to apply hooks..."
    systemctl restart libvirtd 2>/dev/null || systemctl restart libvirt-daemon 2>/dev/null || true
    sleep 2
    if ! virsh net-list 2>/dev/null | grep -q "default.*active"; then
        _yellow "  Restarting default network after libvirtd restart..."
        virsh net-start default 2>/dev/null || true
        sleep 2
    fi

    # ── 部署虚拟机 ──────────────────────────────────────────────────────

    _yellow "Deploying VM with virt-install..."
    local extra_args=""
    if [[ "$ARCH_TYPE" == "aarch64" || "$ARCH_TYPE" == "arm64" ]]; then
        extra_args="--boot uefi=off"
    fi

    # 检测 os_info 是否在本机 osinfo 数据库中存在，不存在则用通用值
    local effective_os_variant="$os_info"
    local osinfo_list
    osinfo_list=$(virt-install --osinfo list 2>/dev/null || virt-install --os-variant list 2>/dev/null || true)
    if [[ -n "$osinfo_list" ]]; then
        if ! echo "$osinfo_list" | grep -qw "$os_info"; then
            for _generic in linux2024 linux2022 linux2020 linux2018 linux2016; do
                if echo "$osinfo_list" | grep -qw "$_generic"; then
                    effective_os_variant="$_generic"
                    break
                fi
            done
        fi
    fi

    virt-install \
        --name "$name" \
        --memory "$memory" \
        --vcpus "$cpu" \
        --import \
        --disk "path=${vm_disk},format=qcow2,bus=virtio,cache=none" \
        --disk "path=${ci_iso},device=cdrom" \
        --network "network=default,mac=${vm_mac},model=virtio" \
        --os-variant "$effective_os_variant" \
        --graphics none \
        --serial pty \
        --console pty,target_type=serial \
        --noautoconsole \
        $extra_args \
        2>/dev/null

    if [[ $? -ne 0 ]]; then
        _red "virt-install failed! Trying with detect=on,require=off..."
        virt-install \
            --name "$name" \
            --memory "$memory" \
            --vcpus "$cpu" \
            --import \
            --disk "path=${vm_disk},format=qcow2,bus=virtio,cache=none" \
            --disk "path=${ci_iso},device=cdrom" \
            --network "network=default,mac=${vm_mac},model=virtio" \
            --os-variant detect=on,require=off \
            --graphics none \
            --serial pty \
            --console pty,target_type=serial \
            --noautoconsole \
            $extra_args
        if [[ $? -ne 0 ]]; then
            _red "VM deployment failed"
            virsh undefine "$name" 2>/dev/null || true
            rm -f "$vm_disk" "$ci_iso" 2>/dev/null || true
            exit 1
        fi
    fi

    _green "  ✓ VM created: $name"

    # 设置 VM 开机自启（cloud-init 完成后的正常启动也走 autostart 路径）
    virsh autostart "$name" 2>/dev/null || true

    # ── 不阻塞等待 cloud-init——后台守护进程负责重启 VM ──────────────────
    # cloud-init runcmd 最后执行 shutdown -P now，VM 关机后后台进程自动 virsh start
    spawn_restart_daemon "$name"

    # 检测公网 IP
    check_ipv4

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
    _green "  初始化:   cloud-init 正在后台运行，完成后 VM 将自动重启"
    _green "  进度查看: tail -f /tmp/qemu-init-${name}.log"
    _green "======================================================"

    # 记录到日志文件
    echo "${name} ${sshport} ${passwd} ${cpu} ${memory} ${disk} ${startport} ${endport} ${system} ${vm_ip}" >> /root/vmlog
    _green "VM info saved to /root/vmlog"
}

main "$@"
