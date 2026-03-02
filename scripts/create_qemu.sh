#!/bin/bash
# from
# https://github.com/oneclickvirt/qemu
# 2026.03.02

# 批量开设 QEMU/KVM 虚拟机脚本
# 交互式创建多个 Linux 虚拟机，记录到 vmlog 日志文件

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

# ======== 切换到 /root ========
cd /root || exit 1

# ======== 检查依赖 ========
pre_check() {
    if ! command -v virsh >/dev/null 2>&1; then
        _yellow "virsh not found, running qemuinstall.sh..."
        if [[ -f /root/qemuinstall.sh ]]; then
            bash /root/qemuinstall.sh
        else
            bash <(curl -sL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/qemu/main/qemuinstall.sh")
        fi
    fi

    # 下载 oneqemu.sh（如果不存在）
    if [[ ! -f /root/scripts/oneqemu.sh ]]; then
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

check_cdn_file

# ======== 读取日志，恢复编号状态 ========
log_file="/root/vmlog"
vm_prefix="vm"
vm_num=0
ssh_port=25000
public_port_end=35000

check_log() {
    if [[ -f "$log_file" ]]; then
        local last_line
        last_line=$(tail -n 1 "$log_file" 2>/dev/null || true)
        if [[ -n "$last_line" ]]; then
            # 格式: <name> <sshport> <password> <cpu> <memory> <disk> <startport> <endport> <system> <ip>
            local last_name last_ssh last_endport
            last_name=$(echo "$last_line" | awk '{print $1}')
            last_ssh=$(echo "$last_line" | awk '{print $2}')
            last_endport=$(echo "$last_line" | awk '{print $8}')

            # 从日志名称提取编号
            local num_part
            num_part=$(echo "$last_name" | grep -oP '\d+$' || echo "0")
            if [[ "$num_part" =~ ^[0-9]+$ ]]; then
                vm_num="$num_part"
            fi
            if [[ "$last_ssh" =~ ^[0-9]+$ ]]; then
                ssh_port="$last_ssh"
            fi
            if [[ "$last_endport" =~ ^[0-9]+$ ]]; then
                public_port_end="$last_endport"
            fi
        fi
    fi
}

# ======== 构建新虚拟机 ========
build_new_vms() {
    # 询问数量
    reading "需要新增几个虚拟机？ (How many VMs to create?) [default: 1]: " new_nums
    [[ -z "$new_nums" || ! "$new_nums" =~ ^[0-9]+$ ]] && new_nums=1

    # 询问内存大小
    reading "每个虚拟机内存大小(MB) (Memory per VM in MB) [default: 1024]: " memory_nums
    [[ -z "$memory_nums" || ! "$memory_nums" =~ ^[0-9]+$ ]] && memory_nums=1024

    # 询问 CPU
    reading "每个虚拟机 CPU 核数 (CPU cores per VM) [default: 1]: " cpu_nums
    [[ -z "$cpu_nums" || ! "$cpu_nums" =~ ^[0-9]+$ ]] && cpu_nums=1

    # 询问磁盘大小
    reading "每个虚拟机磁盘大小(GB) (Disk size per VM in GB) [default: 20]: " disk_nums
    [[ -z "$disk_nums" || ! "$disk_nums" =~ ^[0-9]+$ ]] && disk_nums=20

    # 询问系统
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
    en_check=$(echo "$system_type" | tr -d '-_' | sed 's/[0-9]*$//' | sed 's/^alma$/almalinux/' | sed 's/^rocky$/rockylinux/' | sed 's/^euler$/openeuler/')
    if [[ ! "$en_check" =~ ^(debian|ubuntu|almalinux|rockylinux|openeuler)$ ]]; then
        _yellow "Unknown system '${system_type}', using debian12"
        system_type="debian12"
    fi

    _blue "======================================================"
    _blue "  即将创建 $new_nums 个虚拟机"
    _blue "  系统: $system_type  内存: ${memory_nums}MB  CPU: ${cpu_nums}  磁盘: ${disk_nums}GB"
    _blue "======================================================"

    local scripts_dir
    if [[ -f /root/scripts/oneqemu.sh ]]; then
        scripts_dir="/root/scripts"
    elif [[ -f "$(dirname "$0")/oneqemu.sh" ]]; then
        scripts_dir="$(dirname "$0")"
    else
        scripts_dir="/root"
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

        bash "${scripts_dir}/oneqemu.sh" \
            "$vm_name" \
            "$cpu_nums" \
            "$memory_nums" \
            "$disk_nums" \
            "$passwd" \
            "$ssh_port" \
            "$public_port_start" \
            "$public_port_end" \
            "$system_type"

        echo ""
    done
}

# ======== 显示日志 ========
show_log() {
    if [[ -f "$log_file" ]]; then
        _blue "======================================================"
        _blue "  已有虚拟机记录 / Existing VM log:"
        _blue "======================================================"
        local header
        printf "  %-12s %-8s %-12s %-4s %-8s %-6s %-14s %-10s %-6s\n" \
            "名称" "SSH端口" "密码" "CPU" "内存(MB)" "磁盘(GB)" "端口范围" "系统" "内网IP"
        echo "  ----------------------------------------------------------------------------"
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            local n sshp pw cp mem dk sp ep sys ip
            n=$(echo "$line"    | awk '{print $1}')
            sshp=$(echo "$line" | awk '{print $2}')
            pw=$(echo "$line"   | awk '{print $3}')
            cp=$(echo "$line"   | awk '{print $4}')
            mem=$(echo "$line"  | awk '{print $5}')
            dk=$(echo "$line"   | awk '{print $6}')
            sp=$(echo "$line"   | awk '{print $7}')
            ep=$(echo "$line"   | awk '{print $8}')
            sys=$(echo "$line"  | awk '{print $9}')
            ip=$(echo "$line"   | awk '{print $10}')
            printf "  %-12s %-8s %-12s %-4s %-8s %-6s %-14s %-10s %-6s\n" \
                "$n" "$sshp" "$pw" "$cp" "$mem" "$dk" "${sp}-${ep}" "$sys" "$ip"
        done < "$log_file"
        echo ""
    fi
}

# ======== 主流程 ========
main() {
    pre_check
    check_log
    show_log
    build_new_vms
    check_log
    show_log
}

main "$@"
