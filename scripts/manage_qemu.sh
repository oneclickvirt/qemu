#!/bin/bash
# QEMU VM management helper for oneclickvirt/qemu.

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }
export DEBIAN_FRONTEND=noninteractive

usage() {
    cat <<'EOF'
Usage:
  manage_qemu.sh info [vm_name|all]
  manage_qemu.sh snapshot <vm_name> [snapshot_name]
  manage_qemu.sh set-resources <vm_name> <cpu> <memory_mb>

Examples:
  manage_qemu.sh info all
  manage_qemu.sh info vm1
  manage_qemu.sh snapshot vm1 before-upgrade
  manage_qemu.sh set-resources vm1 2 2048
EOF
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_positive_uint() {
    is_uint "$1" && (( 10#$1 > 0 ))
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

validate_vm_name() {
    local vm_name="$1"
    [[ "$vm_name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]
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

db_query_vm() {
    local vm_name="$1" db_file
    command -v sqlite3 >/dev/null 2>&1 || return 0
    db_file=$(vm_db_file)
    [[ -f "$db_file" ]] || return 0
    sqlite3 -separator '|' "$db_file" \
        "SELECT ssh_port, password, cpu, memory, disk, start_port, end_port, system, ipv4, mac, bridge, fw_backend, ipv6, ipv6_nat FROM vms WHERE vm_name='$(sql_escape "$vm_name")' LIMIT 1;" \
        2>/dev/null || \
    sqlite3 -separator '|' "$db_file" \
        "SELECT ssh_port, password, cpu, memory, disk, start_port, end_port, system, ipv4, mac, '', '', '', 0 FROM vms WHERE vm_name='$(sql_escape "$vm_name")' LIMIT 1;" \
        2>/dev/null || true
}

db_list_vm_names() {
    local db_file
    command -v sqlite3 >/dev/null 2>&1 || return 0
    db_file=$(vm_db_file)
    [[ -f "$db_file" ]] || return 0
    sqlite3 "$db_file" "SELECT vm_name FROM vms ORDER BY id;" 2>/dev/null || true
}

update_vm_db_resources() {
    local vm_name="$1" cpu="$2" memory_mb="$3" db_file
    command -v sqlite3 >/dev/null 2>&1 || return 0
    db_file=$(vm_db_file)
    [[ -f "$db_file" ]] || return 0
    sqlite3 "$db_file" \
        "UPDATE vms SET cpu=${cpu}, memory=${memory_mb}, updated_at=CURRENT_TIMESTAMP WHERE vm_name='$(sql_escape "$vm_name")';" \
        >/dev/null 2>&1 || \
    sqlite3 "$db_file" \
        "UPDATE vms SET cpu=${cpu}, memory=${memory_mb} WHERE vm_name='$(sql_escape "$vm_name")';" \
        >/dev/null 2>&1 || _yellow "  SQLite VM database resource update skipped for ${vm_name}"
}

update_vmlog_resources() {
    local vm_name="$1" cpu="$2" memory_mb="$3"
    [[ -f /root/vmlog ]] || return 0
    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local n sshp pw _old_cpu _old_mem dk sp ep sys ip rest
        read -r n sshp pw _old_cpu _old_mem dk sp ep sys ip rest <<< "$line"
        if [[ "$n" == "$vm_name" ]]; then
            printf '%s %s %s %s %s %s %s %s %s %s' \
                "$n" "$sshp" "$pw" "$cpu" "$memory_mb" "$dk" "$sp" "$ep" "$sys" "$ip" >> "$tmpfile"
            if [[ -n "$rest" ]]; then
                printf ' %s' "$rest" >> "$tmpfile"
            fi
            printf '\n' >> "$tmpfile"
        else
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < /root/vmlog
    mv "$tmpfile" /root/vmlog
}

update_state_resources() {
    local vm_name="$1" cpu="$2" memory_mb="$3"
    acquire_state_lock 60
    update_vmlog_resources "$vm_name" "$cpu" "$memory_mb"
    update_vm_db_resources "$vm_name" "$cpu" "$memory_mb"
    release_state_lock
}

require_root() {
    if [[ "$(id -u)" != "0" ]]; then
        _red "This script must be run as root"
        exit 1
    fi
}

require_virsh() {
    if ! command -v virsh >/dev/null 2>&1; then
        _red "virsh not found. Please run qemuinstall.sh first."
        exit 1
    fi
}

require_vm() {
    local vm_name="$1"
    if ! validate_vm_name "$vm_name"; then
        _red "Invalid VM name: $vm_name"
        exit 1
    fi
    if ! virsh dominfo "$vm_name" >/dev/null 2>&1; then
        _red "VM '$vm_name' does not exist."
        exit 1
    fi
}

print_vm_info() {
    local vm_name="$1"
    local allow_missing="${2:-false}"
    if ! validate_vm_name "$vm_name"; then
        _red "Invalid VM name: $vm_name"
        exit 1
    fi

    local log_line db_line state mac ip ssh_port start_port end_port system cpu memory disk extra_info
    local log_mac bridge fw_backend ipv6 ipv6_nat
    log_line=$(grep "^${vm_name} " /root/vmlog 2>/dev/null | tail -1 || true)
    if [[ -n "$log_line" ]]; then
        read -r _ ssh_port _ cpu memory disk start_port end_port system ip extra_info <<< "$log_line"
        for item in $extra_info; do
            case "$item" in
                mac=*) log_mac="${item#mac=}" ;;
                bridge=*) bridge="${item#bridge=}" ;;
                fw=*) fw_backend="${item#fw=}" ;;
                ipv6=*) ipv6="${item#ipv6=}" ;;
                ipv6_nat=*) ipv6_nat="${item#ipv6_nat=}" ;;
            esac
        done
    else
        db_line=$(db_query_vm "$vm_name")
        if [[ -n "$db_line" ]]; then
            IFS='|' read -r ssh_port _ cpu memory disk start_port end_port system ip log_mac bridge fw_backend ipv6 ipv6_nat <<< "$db_line"
            [[ "$ipv6_nat" == "1" ]] && ipv6_nat=true
            [[ "$ipv6_nat" == "0" ]] && ipv6_nat=false
        fi
    fi
    if virsh dominfo "$vm_name" >/dev/null 2>&1; then
        state=$(virsh domstate "$vm_name" 2>/dev/null || echo "unknown")
        mac=$(virsh domiflist "$vm_name" 2>/dev/null | awk '/virtio/{print $5; exit}')
        [[ -z "$mac" ]] && mac="$log_mac"
        if [[ -z "$ip" ]]; then
            ip=$(virsh net-dumpxml default 2>/dev/null | grep "name='${vm_name}'" | grep -oP "ip='[^']+'" | cut -d"'" -f2 | head -1 || true)
        fi
    elif [[ "$allow_missing" == true ]]; then
        state="missing"
        mac="$log_mac"
    else
        _red "VM '$vm_name' does not exist."
        exit 1
    fi

    printf '%s\n' "name=${vm_name}"
    printf '%s\n' "state=${state:-unknown}"
    printf '%s\n' "system=${system:-unknown}"
    printf '%s\n' "cpu=${cpu:-unknown}"
    printf '%s\n' "memory_mb=${memory:-unknown}"
    printf '%s\n' "disk_gb=${disk:-unknown}"
    printf '%s\n' "mac=${mac:-unknown}"
    printf '%s\n' "ip=${ip:-unknown}"
    printf '%s\n' "ipv6=${ipv6:-unknown}"
    printf '%s\n' "ipv6_nat=${ipv6_nat:-unknown}"
    printf '%s\n' "bridge=${bridge:-unknown}"
    printf '%s\n' "firewall=${fw_backend:-unknown}"
    printf '%s\n' "ssh_port=${ssh_port:-unknown}"
    printf '%s\n' "extra_ports=${start_port:-unknown}-${end_port:-unknown}"
}

info_command() {
    local target="${1:-all}"
    if [[ "$target" == "all" ]]; then
        if [[ ! -f /root/vmlog ]]; then
            local listed=false vm_name
            while IFS= read -r vm_name || [[ -n "$vm_name" ]]; do
                [[ -z "$vm_name" ]] && continue
                listed=true
                print_vm_info "$vm_name" true
                echo "---"
            done < <(db_list_vm_names)
            if [[ "$listed" != true ]]; then
                _yellow "No /root/vmlog or VM database records found."
            fi
            return 0
        fi
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            local vm_name
            read -r vm_name _ <<< "$line"
            print_vm_info "$vm_name" true
            echo "---"
        done < /root/vmlog
    else
        print_vm_info "$target"
    fi
}

snapshot_command() {
    local vm_name="${1:-}" snapshot_name="${2:-}"
    if [[ -z "$vm_name" ]]; then
        usage
        exit 1
    fi
    require_vm "$vm_name"
    if [[ -z "$snapshot_name" ]]; then
        snapshot_name="${vm_name}-$(date +%Y%m%d%H%M%S)"
    fi
    if [[ ! "$snapshot_name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        _red "Invalid snapshot name: $snapshot_name"
        exit 1
    fi
    if ! virsh snapshot-create-as "$vm_name" "$snapshot_name" --atomic 2>/dev/null && \
        ! virsh snapshot-create-as "$vm_name" "$snapshot_name"; then
        _red "Failed to create snapshot: ${vm_name}/${snapshot_name}"
        exit 1
    fi
    _green "Snapshot created: ${vm_name}/${snapshot_name}"
}

set_resources_command() {
    local vm_name="${1:-}" cpu="${2:-}" memory_mb="${3:-}"
    if [[ -z "$vm_name" || -z "$cpu" || -z "$memory_mb" ]]; then
        usage
        exit 1
    fi
    require_vm "$vm_name"
    if ! is_positive_uint "$cpu" || ! is_positive_uint "$memory_mb"; then
        _red "CPU and memory_mb must be positive integers."
        exit 1
    fi
    cpu=$((10#$cpu))
    memory_mb=$((10#$memory_mb))
    local memory_kib=$((memory_mb * 1024))

    if ! virsh setvcpus "$vm_name" "$cpu" --live --config 2>/dev/null && \
        ! virsh setvcpus "$vm_name" "$cpu" --config; then
        _red "Failed to update CPU for $vm_name"
        exit 1
    fi
    virsh setmaxmem "$vm_name" "$memory_kib" --config 2>/dev/null || true
    if ! virsh setmem "$vm_name" "$memory_kib" --live --config 2>/dev/null && \
        ! virsh setmem "$vm_name" "$memory_kib" --config; then
        _red "Failed to update memory for $vm_name"
        exit 1
    fi
    update_state_resources "$vm_name" "$cpu" "$memory_mb"
    _green "Resources updated: ${vm_name} cpu=${cpu} memory_mb=${memory_mb}"
}

main() {
    local command="${1:-}"
    shift || true
    case "$command" in
        -h|--help|help|"") usage; return 0 ;;
    esac

    require_root
    require_virsh

    case "$command" in
        info) info_command "$@" ;;
        snapshot) snapshot_command "$@" ;;
        set-resources|resize|resources) set_resources_command "$@" ;;
        *)
            _red "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
