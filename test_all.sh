#!/bin/bash
# 完整测试脚本 — 在目标机器上执行
# 测试内容：安装 → 创建VM → 验证NAT → 删除VM → 卸载
# 用法: bash test_all.sh

set -euo pipefail

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }

PASS=0
FAIL=0
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        _green "  [PASS] $desc"
        PASS=$((PASS + 1))
    else
        _red "  [FAIL] $desc"
        FAIL=$((FAIL + 1))
    fi
}

check_output() {
    local desc="$1"
    local expected="$2"
    shift 2
    local out
    out=$("$@" 2>&1 || true)
    if echo "$out" | grep -qE "$expected"; then
        _green "  [PASS] $desc"
        PASS=$((PASS + 1))
    else
        _red "  [FAIL] $desc (got: ${out:0:120})"
        FAIL=$((FAIL + 1))
    fi
}

# ================== 环境检测 ==================
_blue "=========================================="
_blue " Step 0: 环境检测"
_blue "=========================================="
echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"
echo "Arch: $(uname -m)"
echo "KVM: $(ls -la /dev/kvm 2>&1 || echo 'not available')"
echo ""

# ================== 测试 1: 安装 ==================
_blue "=========================================="
_blue " Step 1: 非交互安装 (qemuinstall.sh)"
_blue "=========================================="

# 先卸载（如果之前有安装）
if command -v virsh >/dev/null 2>&1; then
    _yellow "Detected existing installation, cleaning up first..."
    virsh list --name 2>/dev/null | while read -r v; do
        [[ -z "$v" ]] && continue
        virsh destroy "$v" 2>/dev/null || true
        virsh undefine "$v" --remove-all-storage 2>/dev/null || true
    done
    rm -f /root/vmlog
fi

cd /root
# 使用管道模拟非交互执行
cat /root/qemuinstall.sh | bash
INSTALL_RC=$?

_blue " --- 安装验证 ---"
check "安装退出码为0" test "$INSTALL_RC" -eq 0
check "virsh 可用" command -v virsh
check "virt-install 可用" command -v virt-install
check "qemu-img 可用" command -v qemu-img
check "libvirtd 运行中" systemctl is-active --quiet libvirtd
check "default 网络活跃" virsh net-list --name | grep -q default
check "virbr0 接口存在" ip link show virbr0
check "IP 转发已开启" test "$(sysctl -n net.ipv4.ip_forward)" = "1"
check "hooks 文件存在" test -f /etc/libvirt/hooks/qemu
check "hooks 文件可执行" test -x /etc/libvirt/hooks/qemu
check "存储池就绪" virsh pool-list | grep -q default

echo ""

# ================== 测试 2: 创建 VM ==================
_blue "=========================================="
_blue " Step 2: 创建虚拟机 (oneqemu.sh)"
_blue "=========================================="

# 使用 oneqemu.sh 非交互创建 VM
bash /root/scripts/oneqemu.sh vm1 1 512 10 TestPass123 25001 35001 35010 debian12
VM_RC=$?

_blue " --- 创建验证 ---"
check "创建退出码为0" test "$VM_RC" -eq 0
check "VM vm1 已注册" virsh dominfo vm1
check "VM 已设置 autostart" virsh dominfo vm1 | grep -q "Autostart.*enable"
check "vmlog 已记录" test -f /root/vmlog
check "vmlog 包含 vm1" grep -q "^vm1 " /root/vmlog

# 等一下让 VM 启动
sleep 5

# 检查 VM 状态（可能是 running 或者 shut off 如果 cloud-init 已完成）
VM_STATE=$(virsh domstate vm1 2>/dev/null || echo "unknown")
_yellow "  VM state: $VM_STATE"
check "VM 状态正常" test "$VM_STATE" = "running" -o "$VM_STATE" = "shut off"

echo ""

# ================== 测试 3: NAT 端口验证 ==================
_blue "=========================================="
_blue " Step 3: NAT 端口映射验证"
_blue "=========================================="

_blue " --- iptables PREROUTING 规则 ---"
echo "  当前 PREROUTING 规则:"
iptables -t nat -L PREROUTING -n --line-numbers 2>&1 | head -30
echo ""

check "SSH DNAT 规则存在 (tcp:25001→22)" iptables -t nat -C PREROUTING -p tcp --dport 25001 -j DNAT --to 192.168.122.2:22
check "SSH DNAT 规则存在 (udp:25001→22)" iptables -t nat -C PREROUTING -p udp --dport 25001 -j DNAT --to 192.168.122.2:22

# 验证端口范围 NAT
check "端口35001 DNAT 存在 (tcp)" iptables -t nat -C PREROUTING -p tcp --dport 35001 -j DNAT --to 192.168.122.2:35001
check "端口35010 DNAT 存在 (tcp)" iptables -t nat -C PREROUTING -p tcp --dport 35010 -j DNAT --to 192.168.122.2:35010
check "端口35001 DNAT 存在 (udp)" iptables -t nat -C PREROUTING -p udp --dport 35001 -j DNAT --to 192.168.122.2:35001

_blue " --- FORWARD 规则 ---"
check "FORWARD 全子网 dst 规则" iptables -C FORWARD -d 192.168.122.0/24 -j ACCEPT
check "FORWARD 全子网 src 规则" iptables -C FORWARD -s 192.168.122.0/24 -j ACCEPT
check "MASQUERADE 规则存在" iptables -t nat -C POSTROUTING -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE

_blue " --- hooks 文件验证 ---"
check "hooks 包含 vm1 规则" grep -q "vm1" /etc/libvirt/hooks/qemu

# 验证 iptables 持久化
check "iptables 规则已持久化" test -f /etc/iptables/rules.v4 -o -f /etc/sysconfig/iptables

echo ""

# ================== 测试 4: KVM/TCG 检测 ==================
_blue "=========================================="
_blue " Step 4: KVM/TCG 检测验证"
_blue "=========================================="

if [[ -e /dev/kvm ]]; then
    _green "  KVM 可用 — 应使用 kvm 加速"
    check_output "VM 使用 KVM 模式" "kvm|qemu" virsh dumpxml vm1 | grep -i "type="
else
    _yellow "  KVM 不可用 — 应使用 TCG 模式"
    check_output "VM 使用 TCG/QEMU 模式" "qemu" virsh dumpxml vm1 | grep "<domain"
fi

echo ""

# ================== 测试 5: 等待 cloud-init 完成并验证 SSH ==================
_blue "=========================================="
_blue " Step 5: 等待 cloud-init 并验证连接"
_blue "=========================================="

_yellow "等待 cloud-init 完成（最多5分钟）..."
MAX_WAIT=300
WAITED=0
while true; do
    STATE=$(virsh domstate vm1 2>/dev/null || echo "error")
    # cloud-init 完成后 VM 会关机，后台进程会重启它
    if [[ "$STATE" == "running" && $WAITED -gt 30 ]]; then
        # VM 已重启（cloud-init 完成后的第二次 running 状态）
        # 或者 VM 还在首次运行中
        # 检查 cloud-init 守护进程日志
        if [[ -f /tmp/qemu-init-vm1.log ]] && grep -q "Done" /tmp/qemu-init-vm1.log; then
            _green "  cloud-init 已完成，VM 已重启"
            break
        fi
    fi
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        _yellow "  等待超时，继续测试..."
        break
    fi
    sleep 10
    WAITED=$((WAITED + 10))
    _yellow "  已等待 ${WAITED}s (VM state: $STATE)"
done

# 尝试 SSH 连接
_blue " --- SSH 连接测试 ---"
sleep 10
if command -v sshpass >/dev/null 2>&1 || apt-get install -y sshpass >/dev/null 2>&1; then
    SSH_OUT=$(sshpass -p 'TestPass123' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p 25001 root@127.0.0.1 "echo SSH_OK" 2>&1 || true)
    if echo "$SSH_OUT" | grep -q "SSH_OK"; then
        _green "  [PASS] SSH 通过 NAT 端口 25001 连接成功"
        PASS=$((PASS + 1))
    else
        _red "  [FAIL] SSH 连接失败: ${SSH_OUT:0:100}"
        FAIL=$((FAIL + 1))
    fi
else
    _yellow "  [SKIP] sshpass 不可用，跳过 SSH 测试"
fi

echo ""

# ================== 测试 6: 删除 VM ==================
_blue "=========================================="
_blue " Step 6: 删除虚拟机 (delete_qemu.sh)"
_blue "=========================================="

bash /root/scripts/delete_qemu.sh vm1 -y
DEL_RC=$?

check "删除退出码为0" test "$DEL_RC" -eq 0
check "VM vm1 已不存在" bash -c "! virsh dominfo vm1 2>/dev/null"
check "vmlog 不再包含 vm1" bash -c "! grep -q '^vm1 ' /root/vmlog 2>/dev/null"
check "DNAT 规则已清除" bash -c "! iptables -t nat -C PREROUTING -p tcp --dport 25001 -j DNAT --to 192.168.122.2:22 2>/dev/null"
check "hooks 中 vm1 已移除" bash -c "! grep -q '#vm1#' /etc/libvirt/hooks/qemu 2>/dev/null"

echo ""

# ================== 测试 7: 批量创建 ==================
_blue "=========================================="
_blue " Step 7: 批量创建测试 (create_qemu.sh)"
_blue "=========================================="

bash /root/scripts/create_qemu.sh 2 512 1 10 debian12
BATCH_RC=$?

check "批量创建退出码为0" test "$BATCH_RC" -eq 0
check "vm1 已创建" virsh dominfo vm1
check "vm2 已创建" virsh dominfo vm2
check "vmlog 有2条记录" test "$(wc -l < /root/vmlog)" -ge 2

echo ""

# ================== 测试 8: 卸载 ==================
_blue "=========================================="
_blue " Step 8: 完整卸载 (qemuuninstall.sh -y)"
_blue "=========================================="

bash /root/qemuuninstall.sh -y
UNINSTALL_RC=$?

check "卸载退出码为0" test "$UNINSTALL_RC" -eq 0
check "virsh 已卸载或 VM 全清" bash -c "! virsh list --all 2>/dev/null | grep -q 'vm'"
check "libvirtd 已停止" bash -c "! systemctl is-active --quiet libvirtd 2>/dev/null"

echo ""

# ================== 汇总 ==================
_blue "=========================================="
_blue " 测试汇总"
_blue "=========================================="
_green "  通过: $PASS"
if [[ $FAIL -gt 0 ]]; then
    _red "  失败: $FAIL"
else
    _green "  失败: $FAIL"
fi
echo ""
if [[ $FAIL -eq 0 ]]; then
    _green "  ✓ 所有测试通过！"
else
    _red "  ✗ 有 $FAIL 个测试失败，请检查上方日志"
fi
