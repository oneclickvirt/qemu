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

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_positive_uint() {
    is_uint "$1" && (( 10#$1 > 0 ))
}

is_port() {
    is_uint "$1" && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

generate_password() {
    local seed hash
    seed="$(date +%s%N)-${RANDOM}-${RANDOM}-${RANDOM}"
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(printf '%s' "$seed" | sha256sum | awk '{print $1}')
    elif command -v md5sum >/dev/null 2>&1; then
        hash=$(printf '%s' "$seed" | md5sum | awk '{print $1}')
    else
        hash="${seed//[^a-zA-Z0-9]/}"
    fi
    printf '%s\n' "${hash:0:20}"
}

LOCK_DIR="/tmp/qemu-vm-state.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
RESERVATION_FILE="/tmp/qemu-vm-reservations"
QEMU_IPV6_SUBNET="fd42:122::/64"
QEMU_IPV6_PREFIX="fd42:122::"
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

range_overlaps() {
    local a_start="$1" a_end="$2" b_start="$3" b_end="$4"
    (( 10#$a_start <= 10#$b_end && 10#$b_start <= 10#$a_end ))
}

prune_state_reservations() {
    [[ -f "$RESERVATION_FILE" ]] || return 0
    local tmpfile
    tmpfile=$(mktemp) || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local r_name r_ssh r_start r_end _r_ip _r_mac r_pid
        read -r r_name r_ssh r_start r_end _r_ip _r_mac r_pid _ <<< "$line"
        if [[ "$r_pid" =~ ^[0-9]+$ ]] && kill -0 "$r_pid" 2>/dev/null; then
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < "$RESERVATION_FILE"
    mv "$tmpfile" "$RESERVATION_FILE"
}

ports_overlap_existing() {
    local new_ssh="$1" new_start="$2" new_end="$3" old_ssh="$4" old_start="$5" old_end="$6"
    [[ "$old_ssh" =~ ^[0-9]+$ && "$old_start" =~ ^[0-9]+$ && "$old_end" =~ ^[0-9]+$ ]] || return 1
    range_overlaps "$new_ssh" "$new_ssh" "$old_ssh" "$old_ssh" || \
        range_overlaps "$new_ssh" "$new_ssh" "$old_start" "$old_end" || \
        range_overlaps "$new_start" "$new_end" "$old_ssh" "$old_ssh" || \
        range_overlaps "$new_start" "$new_end" "$old_start" "$old_end"
}

state_conflict_message=""
check_state_conflicts() {
    local new_name="$1" new_ssh="$2" new_start="$3" new_end="$4"
    state_conflict_message=""

    if [[ -f /root/vmlog ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            local logged_name logged_ssh _logged_pass _logged_cpu _logged_mem _logged_disk logged_start logged_end
            read -r logged_name logged_ssh _logged_pass _logged_cpu _logged_mem _logged_disk logged_start logged_end _ <<< "$line"
            [[ "$logged_name" == "$new_name" ]] && continue
            if ports_overlap_existing "$new_ssh" "$new_start" "$new_end" "$logged_ssh" "$logged_start" "$logged_end"; then
                state_conflict_message="Requested ports overlap existing VM '${logged_name}' in /root/vmlog"
                return 1
            fi
        done < /root/vmlog
    fi

    if command -v sqlite3 >/dev/null 2>&1; then
        local db_file
        db_file=$(vm_db_file)
        if [[ -f "$db_file" ]]; then
            while IFS='|' read -r db_name db_ssh db_start db_end || [[ -n "$db_name" ]]; do
                [[ -z "$db_name" || "$db_name" == "$new_name" ]] && continue
                if ports_overlap_existing "$new_ssh" "$new_start" "$new_end" "$db_ssh" "$db_start" "$db_end"; then
                    state_conflict_message="Requested ports overlap existing VM '${db_name}' in SQLite VM database"
                    return 1
                fi
            done < <(sqlite3 -separator '|' "$db_file" "SELECT vm_name, ssh_port, start_port, end_port FROM vms;" 2>/dev/null || true)
        fi
    fi

    prune_state_reservations
    if [[ -f "$RESERVATION_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            local r_name r_ssh r_start r_end _r_ip _r_mac r_pid
            read -r r_name r_ssh r_start r_end _r_ip _r_mac r_pid _ <<< "$line"
            [[ "$r_pid" == "$$" ]] && continue
            if [[ "$r_name" == "$new_name" ]]; then
                state_conflict_message="VM name '${new_name}' is already reserved by another creation process"
                return 1
            fi
            if ports_overlap_existing "$new_ssh" "$new_start" "$new_end" "$r_ssh" "$r_start" "$r_end"; then
                state_conflict_message="Requested ports overlap in-progress VM '${r_name}'"
                return 1
            fi
        done < "$RESERVATION_FILE"
    fi
    return 0
}

add_state_reservation() {
    local vm_name="$1" ssh_port="$2" start_p="$3" end_p="$4" ip_addr="$5" mac_addr="$6"
    printf '%s %s %s %s %s %s %s\n' "$vm_name" "$ssh_port" "$start_p" "$end_p" "$ip_addr" "$mac_addr" "$$" >> "$RESERVATION_FILE"
}

remove_state_reservation() {
    local vm_name="$1"
    [[ -f "$RESERVATION_FILE" ]] || return 0
    local tmpfile
    tmpfile=$(mktemp) || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local r_name _r_ssh _r_start _r_end _r_ip _r_mac r_pid
        read -r r_name _r_ssh _r_start _r_end _r_ip _r_mac r_pid _ <<< "$line"
        if [[ "$r_name" != "$vm_name" && "$r_pid" != "$$" ]]; then
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < "$RESERVATION_FILE"
    mv "$tmpfile" "$RESERVATION_FILE"
}

is_ipv6_nat_enabled() {
    [[ -f /usr/local/bin/qemu_ipv6_nat_enabled ]] && grep -q '^true$' /usr/local/bin/qemu_ipv6_nat_enabled 2>/dev/null
}

vm_expected_ipv6() {
    local ipv4="$1" last_octet
    last_octet="${ipv4##*.}"
    if [[ "$last_octet" =~ ^[0-9]+$ ]]; then
        printf '%s%x\n' "$QEMU_IPV6_PREFIX" "$((10#$last_octet))"
    else
        printf 'unknown\n'
    fi
}

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

# ======== 参数 ========
name="${1:-${VM_NAME:-vm1}}"
cpu="${2:-${VM_CPU:-1}}"
memory="${3:-${VM_MEMORY:-1024}}"
disk="${4:-${VM_DISK:-20}}"
passwd="${5:-${VM_PASSWORD:-}}"
sshport="${6:-${VM_SSH_PORT:-25001}}"
startport="${7:-${VM_START_PORT:-35001}}"
endport="${8:-${VM_END_PORT:-35025}}"
if [[ -z "$passwd" ]]; then
    passwd="$(generate_password)"
fi
# $9 可能为附加标志（如 y/n），$10 可能才是系统名
# 若 $9 非空且不像 y/n/yes/no 这类纯标志，则作为系统名；否则取 $10
_raw9="${9:-}"
_raw10="${10:-}"
if [[ -n "$_raw10" && ("$_raw9" == "y" || "$_raw9" == "n" || "$_raw9" == "yes" || "$_raw9" == "no") ]]; then
    system="$_raw10"
elif [[ -n "$_raw9" ]]; then
    system="$_raw9"
else
    system="${VM_SYSTEM:-debian}"
fi

# ======== 参数验证 ========
if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    _red "VM name must start with a letter and contain only letters, digits, underscore, hyphen"
    exit 1
fi
if [[ ! "$passwd" =~ ^[a-zA-Z0-9@%+=.,/_:-]+$ ]]; then
    _red "Password contains unsafe characters. Allowed: a-zA-Z0-9@%+=.,/_:-"
    exit 1
fi
if ! is_positive_uint "$cpu"; then
    _red "CPU cores must be a positive integer"
    exit 1
fi
if ! is_positive_uint "$memory"; then
    _red "Memory must be a positive integer in MB"
    exit 1
fi
if ! is_positive_uint "$disk"; then
    _red "Disk size must be a positive integer in GB"
    exit 1
fi
if ! is_port "$sshport"; then
    _red "SSH port must be an integer between 1 and 65535"
    exit 1
fi
if ! is_port "$startport" || ! is_port "$endport"; then
    _red "Port range must use integers between 1 and 65535"
    exit 1
fi
if (( 10#$startport > 10#$endport )); then
    _red "Port range start must be less than or equal to end"
    exit 1
fi
if (( 10#$sshport >= 10#$startport && 10#$sshport <= 10#$endport )); then
    _red "SSH port must not overlap the extra port range"
    exit 1
fi
cpu=$((10#$cpu))
memory=$((10#$memory))
disk=$((10#$disk))
sshport=$((10#$sshport))
startport=$((10#$startport))
endport=$((10#$endport))

# ======== 系统检测 ========
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "Alpine")
# shellcheck disable=SC2034
PACKAGE_UPDATE=(
    "! apt-get update && apt-get --fix-broken install -y && apt-get update"
    "apt-get update"
    "yum -y update"
    "yum -y update"
    "yum -y update"
    "pacman -Sy"
    "apk update"
)
# shellcheck disable=SC2034
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
    local shuffled_cdn_urls=()
    if command -v shuf >/dev/null 2>&1; then
        while IFS= read -r cdn_url; do
            shuffled_cdn_urls+=("$cdn_url")
        done < <(printf '%s\n' "${cdn_urls[@]}" | shuf)
    else
        shuffled_cdn_urls=("${cdn_urls[@]}")
    fi
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
if virsh dominfo "$name" >/dev/null 2>&1; then
    _red "VM '$name' already exists. Delete it first or choose another name."
    exit 1
fi
if [[ -f "${images_path}/vm-${name}.qcow2" || -f "${images_path}/vm-${name}-cloudinit.iso" ]]; then
    _red "VM disk or cloud-init ISO for '$name' already exists in $images_path"
    exit 1
fi

# ======== 解析 system 名称与版本 ========
# 支持格式：debian / debian12 / debian-12 / ubuntu22 / ubuntu2204 / almalinux9 / rocky8 等
system=$(echo "$system" | tr '[:upper:]' '[:lower:]')

# 规范化别名（alma→almalinux，rocky→rockylinux，euler→openeuler）
case "$system" in
    alma*) system="almalinux${system#alma}" ;;
    rocky*) system="rockylinux${system#rocky}" ;;
    euler*) system="openeuler" ;;
esac

# 去掉分隔符（ubuntu-22→ubuntu22，ubuntu_22→ubuntu22）
# 注意：tr -d '-_' 中 - 开头会被误判为选项，需将 - 置于末尾
system=$(echo "$system" | tr -d '_-')

# 4 位 Ubuntu 版本号缩短（ubuntu2204→ubuntu22，ubuntu2404→ubuntu24）
if [[ "$system" =~ ^(ubuntu)([0-9][0-9])[0-9][0-9]$ ]]; then
    system="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
fi

# 拆分名称部分与版本部分
en_system="${system%%[0-9]*}"
num_system="${system#"$en_system"}"

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

image_checksum_path() {
    local img_path="$1"
    printf '%s.sha256\n' "$img_path"
}

write_image_checksum() {
    local img_path="$1" checksum_path
    checksum_path=$(image_checksum_path "$img_path")
    if ! command -v sha256sum >/dev/null 2>&1; then
        _yellow "  sha256sum not found, skipping checksum record for $img_path"
        return 0
    fi
    sha256sum "$img_path" > "$checksum_path"
}

verify_cached_image() {
    local img_path="$1" checksum_path
    checksum_path=$(image_checksum_path "$img_path")
    if ! command -v sha256sum >/dev/null 2>&1; then
        _yellow "  sha256sum not found, using cached image without checksum verification"
        return 0
    fi
    if [[ -f "$checksum_path" ]]; then
        if sha256sum -c "$checksum_path" >/dev/null 2>&1; then
            _green "  ✓ Cached image checksum verified"
            return 0
        fi
        _yellow "  Cached image checksum mismatch, removing stale image"
        rm -f "$img_path" "$checksum_path" 2>/dev/null || true
        return 1
    fi
    _yellow "  Cached image has no checksum record, creating one"
    write_image_checksum "$img_path"
    return 0
}

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
            write_image_checksum "$img_path"
            _green "  ✓ Downloaded from pve_kvm_images: ${base_url##*/}"
            return 0
        fi
        rm -f "${img_path}.tmp" 2>/dev/null
        # 直连回退
        if curl -fsSL --connect-timeout 30 --max-time 600 \
                -o "${img_path}.tmp" "$base_url" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
            mv "${img_path}.tmp" "$img_path"
            write_image_checksum "$img_path"
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
        write_image_checksum "$img_path"
        _green "  ✓ Downloaded from kvm_images: ${ver}.qcow2"
        return 0
    fi
    rm -f "${img_path}.tmp" 2>/dev/null
    # 直连回退（无 CDN）
    if curl -fsSL --connect-timeout 30 --max-time 600 \
            -o "${img_path}.tmp" "$base_url" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
        mv "${img_path}.tmp" "$img_path"
        write_image_checksum "$img_path"
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
        if ! verify_cached_image "$img_path"; then
            _yellow "Base image cache invalid, downloading again for system '${system}'..."
        else
            _green "Base image already cached: $img_path"
            return 0
        fi
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
                write_image_checksum "$img_path"
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
            write_image_checksum "$img_path"
            _green "  ✓ Downloaded via CDN"
            return 0
        fi
        rm -f "${img_path}.tmp" 2>/dev/null
    fi
    if curl -fL --progress-bar --connect-timeout 15 --max-time 600 \
            -o "${img_path}.tmp" "$CLOUD_IMG_URL" 2>/dev/null && [[ -s "${img_path}.tmp" ]]; then
        mv "${img_path}.tmp" "$img_path"
        write_image_checksum "$img_path"
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
#   1. 使用 --cloud-init user-data=...,disable=on 传入（virt-install >= 4.0）
#   2. 不安装额外软件包（避免在 TCG 模式下极其缓慢）
#   3. VM 保持运行，由后台守护进程等待 cloud-init 配置后 SSH 就绪
# 回退方案：若 virt-install 不支持 --cloud-init，则手动创建 ISO

create_cloudinit_yaml() {
    local vm_name="$1"
    local password="$2"
    local tmp_yaml="/tmp/qemu-cloudinit-${vm_name}.yaml"

    cat > "$tmp_yaml" <<CIEOF
#cloud-config
hostname: ${vm_name}
locale: en_US.UTF-8
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
runcmd:
  - systemctl enable --now serial-getty@ttyS0.service 2>/dev/null || true
  - echo 'root:${password}' | chpasswd
  - |
    if [ -f /etc/ssh/sshd_config ]; then
      sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
      sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    fi
  - systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
final_message: "cloud-init done after \$UPTIME seconds"
CIEOF

    echo "$tmp_yaml"
}

# 检测 virt-install 是否支持 --cloud-init 参数
check_cloudinit_support() {
    if virt-install --cloud-init help 2>/dev/null | grep -q "user-data"; then
        return 0
    fi
    return 1
}

# 回退方案：手动创建 cloud-init ISO（用于不支持 --cloud-init 的旧版 virt-install）
create_cloudinit_iso() {
    local vm_name="$1"
    local password="$2"
    local tmp_yaml
    tmp_yaml=$(create_cloudinit_yaml "$vm_name" "$password")
    local tmp_iso="${images_path}/vm-${vm_name}-cloudinit.iso"

    local meta_yaml="/tmp/qemu-cloudinit-${vm_name}-meta.yaml"
    cat > "$meta_yaml" <<METAEOF
instance-id: ${vm_name}
local-hostname: ${vm_name}
METAEOF

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

# ======== 防火墙检测与管理 ========
FW_BACKEND=""
detect_fw() {
    if [[ -f /usr/local/bin/qemu_fw_backend ]]; then
        FW_BACKEND=$(cat /usr/local/bin/qemu_fw_backend)
    fi
    if [[ "$FW_BACKEND" != "nft" && "$FW_BACKEND" != "iptables" ]]; then
        if command -v nft >/dev/null 2>&1; then
            FW_BACKEND="nft"
        elif command -v iptables >/dev/null 2>&1; then
            FW_BACKEND="iptables"
        else
            _red "No firewall tool available (nft or iptables)"
            exit 1
        fi
    fi
}

fw_init_table() {
    if [[ "$FW_BACKEND" == "nft" ]]; then
        nft add table ip qemu 2>/dev/null || true
        nft 'add chain ip qemu prerouting { type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
        nft 'add chain ip qemu postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
        nft 'add chain ip qemu forward { type filter hook forward priority 0; policy accept; }' 2>/dev/null || true
        if ! nft list chain ip qemu postrouting 2>/dev/null | grep -q masquerade; then
            nft add rule ip qemu postrouting ip saddr 192.168.122.0/24 ip daddr != 192.168.122.0/24 masquerade 2>/dev/null || true
        fi
        if ! nft list chain ip qemu forward 2>/dev/null | grep -q "ct state"; then
            nft add rule ip qemu forward ct state established,related accept 2>/dev/null || true
            nft add rule ip qemu forward ip daddr 192.168.122.0/24 accept 2>/dev/null || true
            nft add rule ip qemu forward ip saddr 192.168.122.0/24 accept 2>/dev/null || true
        fi
        if is_ipv6_nat_enabled; then
            nft add table ip6 qemu6 2>/dev/null || true
            nft 'add chain ip6 qemu6 postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
            nft 'add chain ip6 qemu6 forward { type filter hook forward priority 0; policy accept; }' 2>/dev/null || true
            if ! nft list chain ip6 qemu6 postrouting 2>/dev/null | grep -q masquerade; then
                nft add rule ip6 qemu6 postrouting ip6 saddr "$QEMU_IPV6_SUBNET" ip6 daddr != "$QEMU_IPV6_SUBNET" masquerade 2>/dev/null || true
            fi
            if ! nft list chain ip6 qemu6 forward 2>/dev/null | grep -q "ct state"; then
                nft add rule ip6 qemu6 forward ct state established,related accept 2>/dev/null || true
                nft add rule ip6 qemu6 forward ip6 daddr "$QEMU_IPV6_SUBNET" accept 2>/dev/null || true
                nft add rule ip6 qemu6 forward ip6 saddr "$QEMU_IPV6_SUBNET" accept 2>/dev/null || true
            fi
        fi
    else
        iptables -t nat -C POSTROUTING -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE 2>/dev/null || \
            iptables -t nat -I POSTROUTING -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE 2>/dev/null || true
        iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -d 192.168.122.0/24 -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -d 192.168.122.0/24 -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -s 192.168.122.0/24 -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -s 192.168.122.0/24 -j ACCEPT 2>/dev/null || true
        if is_ipv6_nat_enabled && command -v ip6tables >/dev/null 2>&1; then
            ip6tables -t nat -C POSTROUTING -s "$QEMU_IPV6_SUBNET" ! -d "$QEMU_IPV6_SUBNET" -j MASQUERADE 2>/dev/null || \
                ip6tables -t nat -I POSTROUTING -s "$QEMU_IPV6_SUBNET" ! -d "$QEMU_IPV6_SUBNET" -j MASQUERADE 2>/dev/null || true
            ip6tables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                ip6tables -I FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
            ip6tables -C FORWARD -d "$QEMU_IPV6_SUBNET" -j ACCEPT 2>/dev/null || \
                ip6tables -I FORWARD -d "$QEMU_IPV6_SUBNET" -j ACCEPT 2>/dev/null || true
            ip6tables -C FORWARD -s "$QEMU_IPV6_SUBNET" -j ACCEPT 2>/dev/null || \
                ip6tables -I FORWARD -s "$QEMU_IPV6_SUBNET" -j ACCEPT 2>/dev/null || true
        fi
    fi
}

fw_delete_vm_rules() {
    local vm_name="$1" vm_ip="${2:-}"
    if [[ "$FW_BACKEND" == "nft" ]]; then
        nft -a list chain ip qemu prerouting 2>/dev/null \
            | grep "\"vm:${vm_name}\"" \
            | grep -oP '# handle \K[0-9]+' \
            | while read -r h; do
                nft delete rule ip qemu prerouting handle "$h" 2>/dev/null || true
            done
    elif [[ "$FW_BACKEND" == "iptables" && -n "$vm_ip" ]]; then
        while iptables -t nat -S PREROUTING 2>/dev/null | grep -Fq -- "--to-destination ${vm_ip}"; do
            local rule
            rule=$(iptables -t nat -S PREROUTING 2>/dev/null \
                | grep -F -- "--to-destination ${vm_ip}" \
                | head -1 \
                | sed 's/^-A /-D /')
            local -a rule_args=()
            read -r -a rule_args <<< "$rule"
            iptables -t nat "${rule_args[@]}" 2>/dev/null || break
        done
    fi
}

fw_add_vm() {
    local vm_name="$1" vm_ip="$2" ssh_port="$3" start_p="$4" end_p="$5"
    _yellow "Adding firewall rules for ${vm_name} (${FW_BACKEND})..."
    fw_delete_vm_rules "$vm_name" "$vm_ip"
    if [[ "$FW_BACKEND" == "nft" ]]; then
        # SSH DNAT (single port → port 22)
        nft add rule ip qemu prerouting tcp dport "$ssh_port" dnat to "${vm_ip}:22" comment "\"vm:${vm_name}\"" 2>/dev/null || true
        nft add rule ip qemu prerouting udp dport "$ssh_port" dnat to "${vm_ip}:22" comment "\"vm:${vm_name}\"" 2>/dev/null || true
        # Port range DNAT (identity mapping: keep original port)
        if (( 10#$start_p <= 10#$end_p )); then
            nft add rule ip qemu prerouting tcp dport "${start_p}-${end_p}" dnat to "${vm_ip}" comment "\"vm:${vm_name}\"" 2>/dev/null || true
            nft add rule ip qemu prerouting udp dport "${start_p}-${end_p}" dnat to "${vm_ip}" comment "\"vm:${vm_name}\"" 2>/dev/null || true
        fi
    else
        iptables -t nat -C PREROUTING -p tcp --dport "$ssh_port" -j DNAT --to-destination "${vm_ip}:22" 2>/dev/null || \
            iptables -t nat -I PREROUTING -p tcp --dport "$ssh_port" -j DNAT --to-destination "${vm_ip}:22" 2>/dev/null || true
        iptables -t nat -C PREROUTING -p udp --dport "$ssh_port" -j DNAT --to-destination "${vm_ip}:22" 2>/dev/null || \
            iptables -t nat -I PREROUTING -p udp --dport "$ssh_port" -j DNAT --to-destination "${vm_ip}:22" 2>/dev/null || true
        if (( 10#$start_p <= 10#$end_p )); then
            iptables -t nat -C PREROUTING -p tcp --dport "${start_p}:${end_p}" -j DNAT --to-destination "$vm_ip" 2>/dev/null || \
                iptables -t nat -I PREROUTING -p tcp --dport "${start_p}:${end_p}" -j DNAT --to-destination "$vm_ip" 2>/dev/null || true
            iptables -t nat -C PREROUTING -p udp --dport "${start_p}:${end_p}" -j DNAT --to-destination "$vm_ip" 2>/dev/null || \
                iptables -t nat -I PREROUTING -p udp --dport "${start_p}:${end_p}" -j DNAT --to-destination "$vm_ip" 2>/dev/null || true
        fi
    fi
    _green "  ✓ Port forwarding rules applied"
}

fw_save() {
    if [[ "$FW_BACKEND" == "nft" ]]; then
        mkdir -p /etc/nftables.d
        {
            echo "# QEMU VM port forwarding - managed by oneclickvirt/qemu"
            echo "table ip qemu"
            echo "delete table ip qemu"
            nft list table ip qemu
            if is_ipv6_nat_enabled; then
                echo "table ip6 qemu6"
                echo "delete table ip6 qemu6"
                nft list table ip6 qemu6
            fi
        } > /etc/nftables.d/qemu.nft 2>/dev/null || true
    else
        # Save both IPv4 and IPv6 rules
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        # Also save for CentOS/Fedora iptables-services
        service iptables save 2>/dev/null || true
        service ip6tables save 2>/dev/null || true
        # Trigger netfilter-persistent save (Debian/Ubuntu)
        netfilter-persistent save 2>/dev/null || true
    fi
}

remove_dhcp_reservation() {
    local vm_name="$1" vm_mac="${2:-}" vm_ip="${3:-}"
    local dhcp_mac="$vm_mac" dhcp_ip="$vm_ip"

    acquire_state_lock 60
    if [[ -z "$dhcp_mac" || -z "$dhcp_ip" ]]; then
        dhcp_mac=$(virsh net-dumpxml default 2>/dev/null | grep "name='${vm_name}'" | grep -oP "mac='[^']+'" | cut -d"'" -f2 | head -1 || true)
        dhcp_ip=$(virsh net-dumpxml default 2>/dev/null | grep "name='${vm_name}'" | grep -oP "ip='[^']+'" | cut -d"'" -f2 | head -1 || true)
    fi

    if [[ -n "$dhcp_mac" && -n "$dhcp_ip" ]]; then
        virsh net-update default delete ip-dhcp-host \
            "<host mac='${dhcp_mac}' name='${vm_name}' ip='${dhcp_ip}' />" \
            --live --config 2>/dev/null || \
        virsh net-update default delete ip-dhcp-host \
            "<host mac='${dhcp_mac}' name='${vm_name}' ip='${dhcp_ip}' />" \
            --config 2>/dev/null || true
    fi
    release_state_lock
}

cleanup_partial_vm() {
    local vm_name="$1" vm_ip="${2:-}" vm_mac="${3:-}" vm_disk="${4:-}" ci_iso="${5:-}"
    _yellow "Cleaning partial VM state for ${vm_name}..."
    virsh destroy "$vm_name" 2>/dev/null || true
    virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || virsh undefine "$vm_name" 2>/dev/null || true
    if [[ "$FW_BACKEND" == "nft" || "$FW_BACKEND" == "iptables" ]]; then
        fw_delete_vm_rules "$vm_name" "$vm_ip"
        fw_save
    fi
    remove_dhcp_reservation "$vm_name" "$vm_mac" "$vm_ip"
    acquire_state_lock 60
    remove_state_reservation "$vm_name"
    release_state_lock
    rm -f "$vm_disk" "$ci_iso" \
        "/tmp/qemu-cloudinit-${vm_name}.yaml" \
        "/tmp/qemu-cloudinit-${vm_name}-meta.yaml" 2>/dev/null || true
}

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

ensure_vm_db_schema() {
    local db_file="$1"
    command -v sqlite3 >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$db_file")"
    sqlite3 "$db_file" <<'SQLEOF' >/dev/null 2>&1 || return 1
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS vms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vm_name TEXT UNIQUE NOT NULL,
    ipv4 TEXT,
    ipv6 TEXT,
    mac TEXT,
    bridge TEXT,
    fw_backend TEXT,
    ipv6_nat INTEGER DEFAULT 0,
    ssh_port INTEGER,
    start_port INTEGER,
    end_port INTEGER,
    cpu INTEGER,
    memory INTEGER,
    disk INTEGER,
    system TEXT,
    password TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_vms_ports ON vms(ssh_port, start_port, end_port);
CREATE INDEX IF NOT EXISTS idx_vms_ipv4 ON vms(ipv4);
SQLEOF
    local column
    for column in \
        "ipv6 TEXT" \
        "bridge TEXT" \
        "fw_backend TEXT" \
        "ipv6_nat INTEGER DEFAULT 0" \
        "updated_at DATETIME"; do
        local column_name="${column%% *}"
        if ! sqlite3 "$db_file" "PRAGMA table_info(vms);" 2>/dev/null | awk -F'|' '{print $2}' | grep -qx "$column_name"; then
            sqlite3 "$db_file" "ALTER TABLE vms ADD COLUMN ${column};" >/dev/null 2>&1 || true
        fi
    done
}

upsert_vm_db() {
    local vm_name="$1" ssh_port="$2" password="$3" cpu_count="$4" mem_mb="$5" disk_gb="$6" start_p="$7" end_p="$8" sys="$9" ip_addr="${10}"
    local mac_addr="${11:-unknown}" bridge="${12:-unknown}" fw_backend="${13:-unknown}" ipv6_addr="${14:-unknown}" ipv6_nat="${15:-false}"
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local db_file ipv6_nat_value
    db_file=$(vm_db_file)
    ensure_vm_db_schema "$db_file" || return 0
    ipv6_nat_value=0
    [[ "$ipv6_nat" == true ]] && ipv6_nat_value=1
    if ! sqlite3 "$db_file" >/dev/null 2>&1 <<SQLEOF
INSERT INTO vms (
    vm_name, ipv4, ipv6, mac, bridge, fw_backend, ipv6_nat,
    ssh_port, start_port, end_port, cpu, memory, disk, system, password,
    updated_at
) VALUES (
    '$(sql_escape "$vm_name")',
    '$(sql_escape "$ip_addr")',
    '$(sql_escape "$ipv6_addr")',
    '$(sql_escape "$mac_addr")',
    '$(sql_escape "$bridge")',
    '$(sql_escape "$fw_backend")',
    ${ipv6_nat_value},
    ${ssh_port},
    ${start_p},
    ${end_p},
    ${cpu_count},
    ${mem_mb},
    ${disk_gb},
    '$(sql_escape "$sys")',
    '$(sql_escape "$password")',
    CURRENT_TIMESTAMP
)
ON CONFLICT(vm_name) DO UPDATE SET
    ipv4=excluded.ipv4,
    ipv6=excluded.ipv6,
    mac=excluded.mac,
    bridge=excluded.bridge,
    fw_backend=excluded.fw_backend,
    ipv6_nat=excluded.ipv6_nat,
    ssh_port=excluded.ssh_port,
    start_port=excluded.start_port,
    end_port=excluded.end_port,
    cpu=excluded.cpu,
    memory=excluded.memory,
    disk=excluded.disk,
    system=excluded.system,
    password=excluded.password,
    updated_at=CURRENT_TIMESTAMP;
SQLEOF
    then
        if ! sqlite3 "$db_file" >/dev/null 2>&1 <<SQLEOF
DELETE FROM vms WHERE vm_name='$(sql_escape "$vm_name")';
INSERT INTO vms (
    vm_name, ipv4, ipv6, mac, bridge, fw_backend, ipv6_nat,
    ssh_port, start_port, end_port, cpu, memory, disk, system, password,
    created_at, updated_at
) VALUES (
    '$(sql_escape "$vm_name")',
    '$(sql_escape "$ip_addr")',
    '$(sql_escape "$ipv6_addr")',
    '$(sql_escape "$mac_addr")',
    '$(sql_escape "$bridge")',
    '$(sql_escape "$fw_backend")',
    ${ipv6_nat_value},
    ${ssh_port},
    ${start_p},
    ${end_p},
    ${cpu_count},
    ${mem_mb},
    ${disk_gb},
    '$(sql_escape "$sys")',
    '$(sql_escape "$password")',
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
);
SQLEOF
        then
            _yellow "  SQLite VM database update skipped for ${vm_name}"
        fi
    fi
}

append_vmlog() {
    local vm_name="$1" ssh_port="$2" password="$3" cpu_count="$4" mem_mb="$5" disk_gb="$6" start_p="$7" end_p="$8" sys="$9" ip_addr="${10}"
    local mac_addr="${11:-unknown}" bridge="${12:-unknown}" fw_backend="${13:-unknown}" ipv6_addr="${14:-unknown}" ipv6_nat="${15:-false}"
    local tmpfile
    acquire_state_lock 60
    tmpfile=$(mktemp)
    if [[ -f /root/vmlog ]]; then
        grep -v "^${vm_name} " /root/vmlog > "$tmpfile" 2>/dev/null || true
    fi
    printf '%s %s %s %s %s %s %s %s %s %s mac=%s bridge=%s fw=%s ipv6=%s ipv6_nat=%s\n' \
        "$vm_name" "$ssh_port" "$password" "$cpu_count" "$mem_mb" "$disk_gb" "$start_p" "$end_p" "$sys" "$ip_addr" \
        "$mac_addr" "$bridge" "$fw_backend" "$ipv6_addr" "$ipv6_nat" >> "$tmpfile"
    mv "$tmpfile" /root/vmlog
    upsert_vm_db "$vm_name" "$ssh_port" "$password" "$cpu_count" "$mem_mb" "$disk_gb" "$start_p" "$end_p" "$sys" "$ip_addr" "$mac_addr" "$bridge" "$fw_backend" "$ipv6_addr" "$ipv6_nat"
    remove_state_reservation "$vm_name"
    release_state_lock
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

# ======== 后台守护：等待 VM 准备就绪（SSH 可用） ========
# 不再依赖 cloud-init shutdown + restart 循环（在 TCG 模式下极其缓慢）
# VM 保持运行，cloud-init 在后台配置完成后 SSH 即可用
spawn_readiness_daemon() {
    local vm_name="$1"
    local vm_ip="$2"
    local ssh_port="$3"
    local log_file="/tmp/qemu-init-${vm_name}.log"
    local max_wait_time=900
    if [[ -e /dev/kvm ]]; then
        max_wait_time=300  # KVM 模式 5 分钟就够了
    fi
    nohup bash -c "
        echo \"[\$(date)] Waiting for VM ${vm_name} to become ready (SSH on ${vm_ip}:22)...\" >> \"${log_file}\"
        echo \"[\$(date)] Max wait: ${max_wait_time}s\" >> \"${log_file}\"
        max_wait=${max_wait_time}
        elapsed=0
        while true; do
            state=\$(virsh domstate '${vm_name}' 2>/dev/null || echo 'error')
            if [[ \"\$state\" != 'running' ]]; then
                echo \"[\$(date)] VM ${vm_name} is not running (state=\${state}). Trying to start...\" >> \"${log_file}\"
                virsh start '${vm_name}' >> \"${log_file}\" 2>&1 || true
                sleep 10
                (( elapsed += 10 ))
                continue
            fi
            # 检查 SSH 是否可用
            if timeout 3 bash -c \": >/dev/tcp/${vm_ip}/22\" >/dev/null 2>&1; then
                echo \"[\$(date)] VM ${vm_name} is ready! SSH available on ${vm_ip}:22\" >> \"${log_file}\"
                echo \"[\$(date)] Done.\" >> \"${log_file}\"
                exit 0
            fi
            if (( elapsed >= max_wait )); then
                echo \"[\$(date)] Timeout \${max_wait}s waiting for SSH. VM may need more time in TCG mode.\" >> \"${log_file}\"
                exit 1
            fi
            sleep 10
            (( elapsed += 10 ))
            if (( elapsed % 60 == 0 )); then
                echo \"[\$(date)] Still waiting... elapsed=\${elapsed}s state=\${state}\" >> \"${log_file}\"
            fi
        done
    " >> "$log_file" 2>&1 &
    disown
    _yellow "  VM booting in background. SSH will become available when cloud-init finishes."
    _yellow "  Progress: tail -f ${log_file}"
    if [[ ! -e /dev/kvm ]]; then
        _yellow "  ⚠ TCG mode: boot may take 10-20+ minutes without KVM acceleration"
    fi
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

    # 分配静态 IP 并写入 DHCP 预留。该段加锁，避免并发创建分到相同 IP。
    local vm_ip
    acquire_state_lock 60
    if ! check_state_conflicts "$name" "$sshport" "$startport" "$endport"; then
        release_state_lock
        _red "$state_conflict_message"
        exit 1
    fi
    vm_ip=$(allocate_ip) || { release_state_lock; _red "Failed to allocate IP address"; exit 1; }
    _blue "VM IP: $vm_ip"
    local vm_ipv6
    vm_ipv6=$(vm_expected_ipv6 "$vm_ip")

    # ── 先配置好网络/钩子，再启动 VM──────────────

    # 在 libvirt default 网络中设置 DHCP 固定 IP（MAC 已知，无需等待首次启动）
    # 先删除旧的 DHCP 预留（若同名 VM 之前创建过但未完整清理）
    _yellow "Setting DHCP reservation: $vm_mac -> $vm_ip"
    local old_dhcp_mac old_dhcp_ip
    old_dhcp_mac=$(virsh net-dumpxml default 2>/dev/null | grep "name='${name}'" | grep -oP "mac='[^']+'" | cut -d"'" -f2 || true)
    if [[ -n "$old_dhcp_mac" ]]; then
        old_dhcp_ip=$(virsh net-dumpxml default 2>/dev/null | grep "name='${name}'" | grep -oP "ip='[^']+'" | cut -d"'" -f2 || true)
        _yellow "  Removing stale DHCP reservation: ${old_dhcp_mac} -> ${old_dhcp_ip}"
        remove_dhcp_reservation "$name" "$old_dhcp_mac" "$old_dhcp_ip"
    fi
    if ! virsh net-update default add ip-dhcp-host \
        "<host mac='${vm_mac}' name='${name}' ip='${vm_ip}' />" \
        --live --config 2>/dev/null && \
        ! virsh net-update default add ip-dhcp-host \
            "<host mac='${vm_mac}' name='${name}' ip='${vm_ip}' />" \
            --config 2>/dev/null; then
        release_state_lock
        cleanup_partial_vm "$name" "$vm_ip" "$vm_mac" "" ""
        _red "Failed to add DHCP reservation"
        exit 1
    fi
    add_state_reservation "$name" "$sshport" "$startport" "$endport" "$vm_ip" "$vm_mac"
    release_state_lock
    _green "  ✓ DHCP reservation: $vm_mac -> $vm_ip"

    # 创建 VM 磁盘
    local vm_disk
    vm_disk=$(create_disk "$name" "$disk") || { cleanup_partial_vm "$name" "$vm_ip" "$vm_mac" "" ""; _red "Failed to create VM disk"; exit 1; }

    # 创建 cloud-init 配置
    _yellow "Creating cloud-init configuration..."
    local ci_iso=""
    # 始终使用手动创建 ISO 的方式（更可靠，virt-install --cloud-init 存在 user-data 为空的 bug）
    ci_iso=$(create_cloudinit_iso "$name" "$passwd") || { cleanup_partial_vm "$name" "$vm_ip" "$vm_mac" "$vm_disk" ""; _red "Failed to create cloud-init ISO"; exit 1; }
    _green "  ✓ cloud-init ISO: $ci_iso"

    # 配置端口转发
    detect_fw
    fw_init_table
    fw_add_vm "$name" "$vm_ip" "$sshport" "$startport" "$endport"
    fw_save

    # 清除目标 IP 的旧 dnsmasq 租约（防止旧 MAC 的租约阻止新 MAC 获取预留 IP）
    # 使用 python3 精确删除，不影响其他 VM 的租约
    local lease_file="/var/lib/libvirt/dnsmasq/${bridge_name}.status"
    acquire_state_lock 60
    if [[ -f "$lease_file" ]]; then
        python3 -c "
import json, sys
try:
    with open('$lease_file') as f:
        leases = json.load(f)
    new_leases = [l for l in leases if l.get('ip-address') != '$vm_ip']
    if len(new_leases) != len(leases):
        with open('$lease_file', 'w') as f:
            json.dump(new_leases, f, indent=2)
        print('  Cleared stale DHCP lease for $vm_ip')
except:
    pass
" 2>/dev/null || true
    fi
    # 刷新 dnsmasq 使其重新读取租约（发送 SIGHUP）
    pkill -HUP dnsmasq 2>/dev/null || true
    release_state_lock

    # ── 部署虚拟机 ──────────────────────────────────────────────────────

    _yellow "Deploying VM with virt-install..."

    # 检测 KVM 加速是否可用，自动选择 virt-type
    local virt_type="qemu"
    if [[ -e /dev/kvm ]] && [[ -w /dev/kvm ]]; then
        virt_type="kvm"
        _green "  KVM acceleration available, using --virt-type kvm"
    else
        # 尝试加载 KVM 模块
        modprobe kvm 2>/dev/null || true
        modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
        sleep 1
        if [[ -e /dev/kvm ]] && [[ -w /dev/kvm ]]; then
            virt_type="kvm"
            _green "  KVM acceleration available (after modprobe), using --virt-type kvm"
        else
            _yellow "  KVM not available, using TCG (--virt-type qemu) - performance will be slower"
        fi
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

    # 构建 virt-install 命令参数
    # 使用手动创建的 cloud-init ISO（比 --cloud-init 更可靠）
    # --sysinfo 添加 NoCloud DMI 提示，让 cloud-init 识别 NoCloud 数据源
    # cloud-init ISO 使用 virtio 总线（而非 CDROM/SATA），因为部分 guest 镜像没有 AHCI 驱动
    local -a extra_opts=()
    if [[ "$ARCH_TYPE" == "aarch64" || "$ARCH_TYPE" == "arm64" ]]; then
        extra_opts=(--boot uefi=off)
    fi

    local -a virt_cmd=(
        virt-install
        --name "$name"
        --memory "$memory"
        --vcpus "$cpu"
        --virt-type "$virt_type"
        --import
        --disk "path=${vm_disk},format=qcow2,bus=virtio,cache=none"
        --disk "path=${ci_iso},format=raw,bus=virtio,readonly=on"
        --network "network=default,mac=${vm_mac},model=virtio"
        --os-variant "$effective_os_variant"
        --sysinfo "type=smbios,system.serial=ds=nocloud"
        --graphics none
        --serial pty
        --console "pty,target_type=serial"
        --noautoconsole
        "${extra_opts[@]}"
    )

    "${virt_cmd[@]}" 2>&1
    local virt_rc=$?

    if [[ $virt_rc -ne 0 ]]; then
        _yellow "virt-install failed (rc=$virt_rc), retrying with detect=on,require=off..."
        virsh undefine "$name" --remove-all-storage 2>/dev/null || virsh undefine "$name" 2>/dev/null || true
        # 重建磁盘（可能被 undefine --remove-all-storage 删除）
        if [[ ! -f "$vm_disk" ]]; then
            vm_disk=$(create_disk "$name" "$disk") || { _red "Failed to re-create VM disk"; exit 1; }
        fi
        virt_cmd=(
            virt-install
            --name "$name"
            --memory "$memory"
            --vcpus "$cpu"
            --virt-type "$virt_type"
            --import
            --disk "path=${vm_disk},format=qcow2,bus=virtio,cache=none"
            --disk "path=${ci_iso},format=raw,bus=virtio,readonly=on"
            --network "network=default,mac=${vm_mac},model=virtio"
            --os-variant "detect=on,require=off"
            --sysinfo "type=smbios,system.serial=ds=nocloud"
            --graphics none
            --serial pty
            --console "pty,target_type=serial"
            --noautoconsole
            "${extra_opts[@]}"
        )
        "${virt_cmd[@]}" 2>&1
        virt_rc=$?
    fi

    # 如果 KVM 模式失败，自动降级到 TCG
    if [[ $virt_rc -ne 0 && "$virt_type" == "kvm" ]]; then
        _yellow "KVM mode failed, falling back to TCG (--virt-type qemu)..."
        virt_type="qemu"
        virsh undefine "$name" --remove-all-storage 2>/dev/null || virsh undefine "$name" 2>/dev/null || true
        if [[ ! -f "$vm_disk" ]]; then
            vm_disk=$(create_disk "$name" "$disk") || { _red "Failed to re-create VM disk"; exit 1; }
        fi
        virt_cmd=(
            virt-install
            --name "$name"
            --memory "$memory"
            --vcpus "$cpu"
            --virt-type qemu
            --import
            --disk "path=${vm_disk},format=qcow2,bus=virtio,cache=none"
            --disk "path=${ci_iso},format=raw,bus=virtio,readonly=on"
            --network "network=default,mac=${vm_mac},model=virtio"
            --os-variant "detect=on,require=off"
            --sysinfo "type=smbios,system.serial=ds=nocloud"
            --graphics none
            --serial pty
            --console "pty,target_type=serial"
            --noautoconsole
            "${extra_opts[@]}"
        )
        "${virt_cmd[@]}" 2>&1
        virt_rc=$?
    fi

    # 清理临时文件
    rm -f "/tmp/qemu-cloudinit-${name}.yaml" "/tmp/qemu-cloudinit-${name}-meta.yaml" 2>/dev/null || true

    if [[ $virt_rc -ne 0 ]]; then
        _red "VM deployment failed"
        cleanup_partial_vm "$name" "$vm_ip" "$vm_mac" "$vm_disk" "$ci_iso"
        exit 1
    fi

    _green "  ✓ VM created: $name"

    # 设置 VM 开机自启
    virsh autostart "$name" 2>/dev/null || true

    # ── 后台守护进程监控 VM 就绪状态 ────────────────────
    # VM 保持运行，cloud-init 在后台配置，完成后 SSH 即可用
    spawn_readiness_daemon "$name" "$vm_ip" "$sshport"

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
    _green "  初始化:   cloud-init 正在后台运行，SSH 就绪后可连接"
    _green "  进度查看: tail -f /tmp/qemu-init-${name}.log"
    _green "======================================================"

    # 记录到日志文件
    local ipv6_nat_state=false
    if is_ipv6_nat_enabled; then
        ipv6_nat_state=true
    fi
    append_vmlog "$name" "$sshport" "$passwd" "$cpu" "$memory" "$disk" "$startport" "$endport" "$system" "$vm_ip" "$vm_mac" "$bridge_name" "${FW_BACKEND:-unknown}" "$vm_ipv6" "$ipv6_nat_state"
    _green "VM info saved to /root/vmlog"
}

main "$@"
