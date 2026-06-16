#!/bin/bash
# from
# https://github.com/oneclickvirt/qemu
# 2026.03.02

# 批量开设 QEMU/KVM 虚拟机脚本
# 交互式或命令行创建多个 Linux 虚拟机，记录到 vmlog 日志文件
# 非交互用法：
#   ./create_qemu.sh <数量> <内存MB> <CPU> <磁盘GB> <系统类型>
#   例: ./create_qemu.sh 3 1024 1 20 debian12

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive

is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_noninteractive() {
    is_truthy "${noninteractive:-}" || [[ ! -t 0 ]]
}

BATCH_LOCK_DIR="/tmp/qemu-vm-batch.lock"
BATCH_LOCK_PID_FILE="${BATCH_LOCK_DIR}/pid"
batch_lock_acquired=false

acquire_batch_lock() {
    local timeout="${1:-600}" elapsed=0
    while ! mkdir "$BATCH_LOCK_DIR" 2>/dev/null; do
        if [[ -f "$BATCH_LOCK_PID_FILE" ]]; then
            local old_pid
            old_pid=$(cat "$BATCH_LOCK_PID_FILE" 2>/dev/null || true)
            if [[ "$old_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$old_pid" 2>/dev/null; then
                rmdir "$BATCH_LOCK_DIR" 2>/dev/null || rm -rf "$BATCH_LOCK_DIR" 2>/dev/null || true
                continue
            fi
        fi
        if (( elapsed >= timeout )); then
            _red "Failed to acquire batch creation lock after ${timeout}s"
            exit 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    batch_lock_acquired=true
    printf '%s\n' "$$" > "$BATCH_LOCK_PID_FILE" 2>/dev/null || true
}

release_batch_lock() {
    if [[ "$batch_lock_acquired" == true ]]; then
        rm -f "$BATCH_LOCK_PID_FILE" 2>/dev/null || true
        rmdir "$BATCH_LOCK_DIR" 2>/dev/null || true
        batch_lock_acquired=false
    fi
}

trap release_batch_lock EXIT

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# ======== 切换到 /root ========
cd /root || exit 1

# ======== 检查依赖 ========
pre_check() {
    if ! command -v virsh >/dev/null 2>&1; then
        _yellow "virsh not found, running qemuinstall.sh..."
        local -a install_prefix=()
        if is_noninteractive; then
            install_prefix=(env noninteractive=true)
        fi
        if [[ -f /root/qemuinstall.sh ]]; then
            "${install_prefix[@]}" bash /root/qemuinstall.sh
        else
            "${install_prefix[@]}" bash <(curl -sL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/qemu/main/qemuinstall.sh")
        fi
    fi

    # 查找 oneqemu.sh（优先同目录，再查 /root/scripts）
    local script_oneqemu=""
    if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/oneqemu.sh" ]]; then
        script_oneqemu="${SCRIPT_DIR}/oneqemu.sh"
    fi
    if [[ -z "$script_oneqemu" && ! -f /root/scripts/oneqemu.sh ]]; then
        mkdir -p /root/scripts
        curl -sL --connect-timeout 10 --max-time 60 \
            "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/qemu/main/scripts/oneqemu.sh" \
            -o /root/scripts/oneqemu.sh
        chmod +x /root/scripts/oneqemu.sh
    fi
}

# ======== CDN 检测 ========
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
cdn_success_url=""

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
        _yellow "CDN available, using CDN: $cdn_success_url"
    else
        _yellow "No CDN available, using direct connection"
    fi
}

check_cdn_file

vm_db_file() {
    if [[ -f /usr/local/bin/qemu_db_file ]]; then
        cat /usr/local/bin/qemu_db_file
    else
        printf '%s\n' "/var/lib/libvirt/qemu-vms.db"
    fi
}

apply_existing_vm_state() {
    local existing_name="$1" existing_ssh="$2" existing_endport="$3"
    local num_part
    num_part=$(echo "$existing_name" | grep -oP '\d+$' || echo "0")
    if [[ "$num_part" =~ ^[0-9]+$ ]] && (( 10#$num_part > vm_num )); then
        vm_num=$((10#$num_part))
    fi
    if [[ "$existing_ssh" =~ ^[0-9]+$ ]] && (( 10#$existing_ssh > ssh_port )); then
        ssh_port=$((10#$existing_ssh))
    fi
    if [[ "$existing_endport" =~ ^[0-9]+$ ]] && (( 10#$existing_endport > public_port_end )); then
        public_port_end=$((10#$existing_endport))
    fi
}

check_db_state() {
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local db_file
    db_file=$(vm_db_file)
    [[ -f "$db_file" ]] || return 0
    while IFS='|' read -r db_name db_ssh db_endport || [[ -n "$db_name" ]]; do
        [[ -z "$db_name" ]] && continue
        apply_existing_vm_state "$db_name" "$db_ssh" "$db_endport"
    done < <(sqlite3 -separator '|' "$db_file" "SELECT vm_name, ssh_port, end_port FROM vms;" 2>/dev/null || true)
}

# ======== 读取日志，恢复编号状态 ========
log_file="/root/vmlog"
vm_prefix="vm"
vm_num=0
ssh_port=25000
public_port_end=35000

check_log() {
    if [[ -f "$log_file" ]]; then
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            # 格式: <name> <sshport> <password> <cpu> <memory> <disk> <startport> <endport> <system> <ip>
            local existing_name existing_ssh _existing_pass _existing_cpu _existing_mem _existing_disk _existing_start existing_endport
            read -r existing_name existing_ssh _existing_pass _existing_cpu _existing_mem _existing_disk _existing_start existing_endport _ <<< "$line"
            apply_existing_vm_state "$existing_name" "$existing_ssh" "$existing_endport"
        done < "$log_file"
    fi
    check_db_state
}

# ======== 构建新虚拟机 ========
build_new_vms() {
    # 支持命令行参数的非交互模式
    # $1=数量 $2=内存MB $3=CPU $4=磁盘GB $5=系统类型
    local cli_nums="${1:-}"
    local cli_memory="${2:-}"
    local cli_cpu="${3:-}"
    local cli_disk="${4:-}"
    local cli_system="${5:-}"

    if [[ -n "$cli_nums" && "$cli_nums" =~ ^[0-9]+$ ]]; then
        new_nums="$cli_nums"
    elif [[ -n "${VM_COUNT:-}" && "${VM_COUNT}" =~ ^[0-9]+$ ]]; then
        new_nums="$VM_COUNT"
    elif is_noninteractive; then
        new_nums=1
    else
        reading "需要新增几个虚拟机？ (How many VMs to create?) [default: 1]: " new_nums
        [[ -z "$new_nums" || ! "$new_nums" =~ ^[0-9]+$ ]] && new_nums=1
    fi

    if [[ -n "$cli_memory" && "$cli_memory" =~ ^[0-9]+$ ]]; then
        memory_nums="$cli_memory"
    elif [[ -n "${VM_MEMORY:-}" && "${VM_MEMORY}" =~ ^[0-9]+$ ]]; then
        memory_nums="$VM_MEMORY"
    elif is_noninteractive; then
        memory_nums=1024
    else
        reading "每个虚拟机内存大小(MB) (Memory per VM in MB) [default: 1024]: " memory_nums
        [[ -z "$memory_nums" || ! "$memory_nums" =~ ^[0-9]+$ ]] && memory_nums=1024
    fi

    if [[ -n "$cli_cpu" && "$cli_cpu" =~ ^[0-9]+$ ]]; then
        cpu_nums="$cli_cpu"
    elif [[ -n "${VM_CPU:-}" && "${VM_CPU}" =~ ^[0-9]+$ ]]; then
        cpu_nums="$VM_CPU"
    elif is_noninteractive; then
        cpu_nums=1
    else
        reading "每个虚拟机 CPU 核数 (CPU cores per VM) [default: 1]: " cpu_nums
        [[ -z "$cpu_nums" || ! "$cpu_nums" =~ ^[0-9]+$ ]] && cpu_nums=1
    fi

    if [[ -n "$cli_disk" && "$cli_disk" =~ ^[0-9]+$ ]]; then
        disk_nums="$cli_disk"
    elif [[ -n "${VM_DISK:-}" && "${VM_DISK}" =~ ^[0-9]+$ ]]; then
        disk_nums="$VM_DISK"
    elif is_noninteractive; then
        disk_nums=20
    else
        reading "每个虚拟机磁盘大小(GB) (Disk size per VM in GB) [default: 20]: " disk_nums
        [[ -z "$disk_nums" || ! "$disk_nums" =~ ^[0-9]+$ ]] && disk_nums=20
    fi

    if [[ -n "$cli_system" ]]; then
        system_type="$cli_system"
    elif [[ -n "${VM_SYSTEM:-}" ]]; then
        system_type="$VM_SYSTEM"
    elif is_noninteractive; then
        system_type="debian12"
    else
        _blue "支持的系统 / Supported systems:"
        _blue "  1. debian12 (default)  2. ubuntu22"
        _blue "  3. almalinux9          4. rockylinux9"
        _blue "  5. openeuler"
        _blue "  可指定版本 / Version examples:"
        _blue "    debian: debian10 debian11 debian12 debian13"
        _blue "    ubuntu: ubuntu18 ubuntu20 ubuntu22 ubuntu24"
        _blue "    almalinux: almalinux8 almalinux9"
        _blue "    rockylinux: rockylinux8 rockylinux9"
        reading "系统类型 (system type) [default: debian12]: " system_type
        [[ -z "$system_type" ]] && system_type="debian12"
    fi
    system_type=$(echo "$system_type" | tr '[:upper:]' '[:lower:]')
    # 支持数字选择
    case "$system_type" in
        1) system_type="debian12" ;;
        2) system_type="ubuntu22" ;;
        3) system_type="almalinux9" ;;
        4) system_type="rockylinux9" ;;
        5) system_type="openeuler" ;;
    esac
    # 验证系统名称（只检查名称部分，版本由 oneqemu.sh 解析）
    local en_check
    en_check=$(echo "$system_type" | tr -d '_\-' | sed 's/[0-9]*$//' | sed 's/^alma$/almalinux/' | sed 's/^rocky$/rockylinux/' | sed 's/^euler$/openeuler/')
    if [[ ! "$en_check" =~ ^(debian|ubuntu|almalinux|rockylinux|openeuler)$ ]]; then
        _yellow "Unknown system '${system_type}', using debian12"
        system_type="debian12"
    fi
    new_nums=$((10#$new_nums))
    memory_nums=$((10#$memory_nums))
    cpu_nums=$((10#$cpu_nums))
    disk_nums=$((10#$disk_nums))
    if (( new_nums < 1 )); then
        _red "VM count must be greater than 0"
        exit 1
    fi
    if (( memory_nums < 1 || cpu_nums < 1 || disk_nums < 1 )); then
        _red "Memory, CPU and disk values must be greater than 0"
        exit 1
    fi

    _blue "======================================================"
    _blue "  即将创建 $new_nums 个虚拟机"
    _blue "  系统: $system_type  内存: ${memory_nums}MB  CPU: ${cpu_nums}  磁盘: ${disk_nums}GB"
    _blue "======================================================"

    local scripts_dir
    # 优先使用与 create_qemu.sh 同目录的 oneqemu.sh
    if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/oneqemu.sh" ]]; then
        scripts_dir="$SCRIPT_DIR"
    elif [[ -f /root/scripts/oneqemu.sh ]]; then
        scripts_dir="/root/scripts"
    else
        scripts_dir="/root"
    fi
    local oneqemu_path="${scripts_dir}/oneqemu.sh"
    if [[ ! -f "$oneqemu_path" ]]; then
        _red "oneqemu.sh not found. Expected: $oneqemu_path"
        exit 1
    fi
    local -a oneqemu_prefix=()
    if is_noninteractive; then
        oneqemu_prefix=(env noninteractive=true)
    fi

    for ((i = 1; i <= new_nums; i++)); do
        vm_num=$((vm_num + 1))
        local vm_name="${vm_prefix}${vm_num}"
        ssh_port=$((ssh_port + 1))
        local public_port_start=$((public_port_end + 1))
        public_port_end=$((public_port_start + 24))

        # 生成随机密码
        local ori
        ori=$(date +%s%N | md5sum 2>/dev/null || date | md5sum)
        local passwd="${ori:2:9}"

        _yellow "[${i}/${new_nums}] Creating VM: ${vm_name}  ssh:${ssh_port}  ports:${public_port_start}-${public_port_end}"

        if ! "${oneqemu_prefix[@]}" bash "$oneqemu_path" \
            "$vm_name" \
            "$cpu_nums" \
            "$memory_nums" \
            "$disk_nums" \
            "$passwd" \
            "$ssh_port" \
            "$public_port_start" \
            "$public_port_end" \
            "$system_type"; then
            _red "Failed to create VM '${vm_name}', stopping batch creation."
            exit 1
        fi

        echo ""
    done
}

# ======== 显示日志 ========
show_log() {
    if [[ -f "$log_file" ]]; then
        _blue "======================================================"
        _blue "  已有虚拟机记录 / Existing VM log:"
        _blue "======================================================"
        printf "  %-12s %-8s %-12s %-4s %-8s %-6s %-14s %-10s %-6s\n" \
            "名称" "SSH端口" "密码" "CPU" "内存(MB)" "磁盘(GB)" "端口范围" "系统" "内网IP"
        echo "  ----------------------------------------------------------------------------"
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            local n sshp pw cp mem dk sp ep sys ip
            read -r n sshp pw cp mem dk sp ep sys ip _ <<< "$line"
            printf "  %-12s %-8s %-12s %-4s %-8s %-6s %-14s %-10s %-6s\n" \
                "$n" "$sshp" "$pw" "$cp" "$mem" "$dk" "${sp}-${ep}" "$sys" "$ip"
        done < "$log_file"
        echo ""
    elif command -v sqlite3 >/dev/null 2>&1; then
        local db_file
        db_file=$(vm_db_file)
        [[ -f "$db_file" ]] || return 0
        _blue "======================================================"
        _blue "  已有虚拟机记录 / Existing VM database records:"
        _blue "======================================================"
        printf "  %-12s %-8s %-12s %-4s %-8s %-6s %-14s %-10s %-6s\n" \
            "名称" "SSH端口" "密码" "CPU" "内存(MB)" "磁盘(GB)" "端口范围" "系统" "内网IP"
        echo "  ----------------------------------------------------------------------------"
        while IFS='|' read -r n sshp pw cp mem dk sp ep sys ip || [[ -n "$n" ]]; do
            [[ -z "$n" ]] && continue
            printf "  %-12s %-8s %-12s %-4s %-8s %-6s %-14s %-10s %-6s\n" \
                "$n" "$sshp" "$pw" "$cp" "$mem" "$dk" "${sp}-${ep}" "$sys" "$ip"
        done < <(sqlite3 -separator '|' "$db_file" "SELECT vm_name, ssh_port, password, cpu, memory, disk, start_port, end_port, system, ipv4 FROM vms ORDER BY id;" 2>/dev/null || true)
        echo ""
    fi
}

# ======== 主流程 ========
main() {
    acquire_batch_lock 600
    pre_check
    check_log
    show_log
    build_new_vms "$@"
    check_log
    show_log
}

main "$@"
