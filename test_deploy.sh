#!/bin/bash
# 远程部署 + 完整测试脚本
# 在本地执行，自动 SSH 到远程机器完成：部署代码→安装环境→创建VM→验证NAT→清理
#
# 用法（在本地项目目录执行）：
#   bash test_deploy.sh <host> <user> <password>
# 例如：
#   bash test_deploy.sh 46.226.166.223 root doyku5HFjy6dN2an

set -euo pipefail

HOST="${1:?Usage: $0 <host> <user> <password>}"
USER="${2:?Usage: $0 <host> <user> <password>}"
PASS="${3:?Usage: $0 <host> <user> <password>}"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
NC='\033[0m'

log()  { echo -e "${BLUE}[TEST]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# SSH 封装
SSH_OPT="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30"

rssh() {
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$PASS" ssh $SSH_OPT "${USER}@${HOST}" "$@"
    else
        ssh $SSH_OPT "${USER}@${HOST}" "$@"
    fi
}

rscp() {
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$PASS" scp $SSH_OPT -r "$@"
    else
        scp $SSH_OPT -r "$@"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
log "=============================================="
log "  QEMU Project Deploy & Test"
log "  Target: ${USER}@${HOST}"
log "=============================================="
echo ""

# ======== 阶段 0: 连通性检查 ========
log "[0/8] Testing SSH connectivity..."
if rssh "echo 'SSH OK' && uname -a"; then
    pass "SSH connection successful"
else
    fail "Cannot SSH to ${HOST}"
    exit 1
fi

# ======== 阶段 1: 清理之前的环境 ========
log "[1/8] Cleaning previous installation (if any)..."
rssh "bash -c '
    export DEBIAN_FRONTEND=noninteractive
    # 如果有旧的卸载脚本就先执行
    if [[ -f /root/qemu/qemuuninstall.sh ]]; then
        bash /root/qemu/qemuuninstall.sh -y 2>&1 || true
    fi
    # 清除残留目录
    rm -rf /root/qemu 2>/dev/null || true
    rm -f /root/vmlog 2>/dev/null || true
    echo \"Previous environment cleaned\"
'" || warn "Clean step had errors (may be first run)"

# ======== 阶段 2: 上传项目文件 ========
log "[2/8] Uploading project files to remote..."
rssh "mkdir -p /root/qemu/scripts"
rscp "${SCRIPT_DIR}/qemuinstall.sh" "${USER}@${HOST}:/root/qemu/qemuinstall.sh"
rscp "${SCRIPT_DIR}/qemuuninstall.sh" "${USER}@${HOST}:/root/qemu/qemuuninstall.sh"
rscp "${SCRIPT_DIR}/scripts/oneqemu.sh" "${USER}@${HOST}:/root/qemu/scripts/oneqemu.sh"
rscp "${SCRIPT_DIR}/scripts/create_qemu.sh" "${USER}@${HOST}:/root/qemu/scripts/create_qemu.sh"
rscp "${SCRIPT_DIR}/scripts/delete_qemu.sh" "${USER}@${HOST}:/root/qemu/scripts/delete_qemu.sh"
rssh "chmod +x /root/qemu/*.sh /root/qemu/scripts/*.sh"
pass "Project files uploaded"

# ======== 阶段 3: 非交互安装 ========
log "[3/8] Running qemuinstall.sh (non-interactive)..."
rssh "bash -c '
    export DEBIAN_FRONTEND=noninteractive
    cd /root/qemu
    bash qemuinstall.sh /var/lib/libvirt/images 2>&1
'" 2>&1
INSTALL_RC=$?
if [[ $INSTALL_RC -eq 0 ]]; then
    pass "qemuinstall.sh completed (rc=0)"
else
    fail "qemuinstall.sh exited with rc=$INSTALL_RC"
fi

# ======== 阶段 4: 验证安装 ========
log "[4/8] Verifying installation..."
rssh "bash -c '
    echo \"=== virsh ===\"
    which virsh && virsh version 2>&1 | head -5
    echo \"=== virt-install ===\"
    which virt-install
    echo \"=== qemu-img ===\"
    which qemu-img
    echo \"=== KVM ===\"
    if [[ -e /dev/kvm ]]; then
        echo \"KVM: available\"
        ls -la /dev/kvm
    else
        echo \"KVM: not available (TCG mode)\"
    fi
    echo \"=== libvirtd ===\"
    systemctl is-active libvirtd 2>&1 || systemctl is-active libvirt-daemon 2>&1 || echo \"not running\"
    echo \"=== default network ===\"
    virsh net-list --all 2>&1
    echo \"=== storage pool ===\"
    virsh pool-list --all 2>&1
    echo \"=== sysctl ===\"
    sysctl net.ipv4.ip_forward 2>&1
    echo \"=== bridge ===\"
    ip link show virbr0 2>&1 | head -3
'" 2>&1
pass "Installation verification done"

# ======== 阶段 5: 创建测试 VM ========
log "[5/8] Creating test VM (vm1) via oneqemu.sh..."
rssh "bash -c '
    export DEBIAN_FRONTEND=noninteractive
    cd /root/qemu
    # 也复制到 /root/scripts 便于 create_qemu.sh 查找
    mkdir -p /root/scripts
    cp scripts/oneqemu.sh /root/scripts/oneqemu.sh
    chmod +x /root/scripts/oneqemu.sh
    bash scripts/oneqemu.sh vm1 1 512 10 TestPass123 25001 35001 35025 debian12 2>&1
'" 2>&1
CREATE_RC=$?
if [[ $CREATE_RC -eq 0 ]]; then
    pass "VM vm1 created (rc=0)"
else
    fail "VM vm1 creation failed (rc=$CREATE_RC)"
fi

# ======== 阶段 6: 验证 VM + NAT ========
log "[6/8] Verifying VM and NAT port mapping..."
rssh "bash -c '
    echo \"=== VM list ===\"
    virsh list --all 2>&1
    echo \"\"
    echo \"=== VM state ===\"
    virsh domstate vm1 2>&1
    echo \"\"
    echo \"=== VM IP (DHCP leases) ===\"
    virsh net-dhcp-leases default 2>&1 || true
    echo \"\"
    echo \"=== DHCP reservations ===\"
    virsh net-dumpxml default 2>&1 | grep -A2 \"<host \" || true
    echo \"\"
    echo \"=== iptables NAT/PREROUTING (SSH port 25001) ===\"
    iptables -t nat -L PREROUTING -n --line-numbers 2>&1 | grep -E \"25001|dpt:\" | head -10
    echo \"\"
    echo \"=== iptables FORWARD ===\"
    iptables -L FORWARD -n --line-numbers 2>&1 | head -15
    echo \"\"
    echo \"=== iptables NAT/POSTROUTING (MASQUERADE) ===\"
    iptables -t nat -L POSTROUTING -n --line-numbers 2>&1 | head -10
    echo \"\"
    echo \"=== libvirt hooks file ===\"
    head -30 /etc/libvirt/hooks/qemu 2>&1 || echo \"No hooks file\"
    echo \"\"
    echo \"=== vmlog ===\"
    cat /root/vmlog 2>&1 || echo \"No vmlog\"
    echo \"\"
    echo \"=== Port 25001 connectivity test (local) ===\"
    # 测试本地是否能连到 NAT 端口（可能 VM 还在 cloud-init 阶段）
    timeout 5 bash -c \"echo | nc -w3 127.0.0.1 25001\" 2>&1 && echo \"Port 25001 reachable\" || echo \"Port 25001 not yet reachable (VM may still be initializing)\"
'" 2>&1
pass "NAT verification done"

# ======== 阶段 7: 删除测试 VM ========
log "[7/8] Deleting test VM (vm1) via delete_qemu.sh..."
rssh "bash -c '
    export DEBIAN_FRONTEND=noninteractive
    cd /root/qemu
    bash scripts/delete_qemu.sh vm1 -y 2>&1
'" 2>&1
DELETE_RC=$?
if [[ $DELETE_RC -eq 0 ]]; then
    pass "VM vm1 deleted (rc=0)"
else
    fail "VM vm1 deletion failed (rc=$DELETE_RC)"
fi

# 验证删除干净
rssh "bash -c '
    echo \"=== VM list after delete ===\"
    virsh list --all 2>&1
    echo \"=== iptables after delete ===\"
    iptables -t nat -L PREROUTING -n 2>&1 | grep 25001 && echo \"WARN: port 25001 rules still exist\" || echo \"OK: port 25001 rules cleaned\"
    echo \"=== vmlog after delete ===\"
    cat /root/vmlog 2>&1 || echo \"vmlog empty/not exist\"
'" 2>&1

# ======== 阶段 8: 完整卸载测试 ========
log "[8/8] Running qemuuninstall.sh -y..."
rssh "bash -c '
    export DEBIAN_FRONTEND=noninteractive
    cd /root/qemu
    bash qemuuninstall.sh -y 2>&1
'" 2>&1
UNINSTALL_RC=$?
if [[ $UNINSTALL_RC -eq 0 ]]; then
    pass "qemuuninstall.sh completed (rc=0)"
else
    fail "qemuuninstall.sh exited with rc=$UNINSTALL_RC"
fi

# 验证卸载干净
rssh "bash -c '
    echo \"=== Post-uninstall checks ===\"
    which virsh 2>/dev/null && echo \"WARN: virsh still installed\" || echo \"OK: virsh removed\"
    systemctl is-active libvirtd 2>/dev/null && echo \"WARN: libvirtd still running\" || echo \"OK: libvirtd stopped\"
    ls /var/lib/libvirt 2>/dev/null && echo \"WARN: /var/lib/libvirt still exists\" || echo \"OK: /var/lib/libvirt cleaned\"
    ls /etc/libvirt 2>/dev/null && echo \"WARN: /etc/libvirt still exists\" || echo \"OK: /etc/libvirt cleaned\"
    cat /etc/sysctl.d/99-qemu.conf 2>/dev/null && echo \"WARN: sysctl config still exists\" || echo \"OK: sysctl cleaned\"
'" 2>&1

echo ""
log "=============================================="
log "  Test Summary"
log "=============================================="
[[ ${INSTALL_RC:-1} -eq 0 ]] && pass "Install: OK" || fail "Install: FAILED"
[[ ${CREATE_RC:-1} -eq 0 ]] && pass "VM Create: OK" || fail "VM Create: FAILED"
[[ ${DELETE_RC:-1} -eq 0 ]] && pass "VM Delete: OK" || fail "VM Delete: FAILED"
[[ ${UNINSTALL_RC:-1} -eq 0 ]] && pass "Uninstall: OK" || fail "Uninstall: FAILED"
echo ""
