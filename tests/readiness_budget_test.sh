#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090 # Load the readiness worker without running creation.
source <(awk '/^wait_for_vm_ssh\(\) \{/ {p=1} p {print} p && /^}$/ {exit}' "$root/scripts/oneqemu.sh")
export QEMU_READY_KNOWN_HOSTS=/tmp/not-used-by-fixture
fixture_state=running
virsh() { echo "$fixture_state"; }
timeout() {
    [[ "$2" == sshpass && "$3" == -e && "$4" == ssh ]] || return 1
    [[ "$*" == *'cloud-init status --wait'* && "$*" != *secret-fixture* ]]
}
SSHPASS=secret-fixture wait_for_vm_ssh fixture 192.0.2.1 1
fixture_state='shut off'
began=$SECONDS
if wait_for_vm_ssh fixture 192.0.2.1 1; then
    echo 'Stopped guest unexpectedly reported SSH readiness' >&2
    exit 1
fi
(( SECONDS - began <= 3 ))
echo 'Readiness: authenticated probe and stopped-guest deadline passed'
# Check the real daemon shell boundary too: nested quoting must preserve the
# function and all positional arguments, without placing credentials in logs.
# shellcheck disable=SC1090
source <(awk '/^spawn_readiness_daemon\(\) \{/ {p=1} p {print} p && /^}$/ {exit}' "$root/scripts/oneqemu.sh")
export fixture_state=running
export -f virsh timeout
sshpass() { :; }
disown() { :; }
_yellow() { :; }
_red() { echo "$*" >&2; }
export passwd=secret-fixture
test_vm="fixture$$"
spawn_readiness_daemon "$test_vm" 192.0.2.1 25001
wait "$!"
logs=(/tmp/qemu-init-"$test_vm".*.log)
trap 'rm -f "${logs[@]}"' EXIT
grep -Fq "VM ${test_vm} is ready: root password SSH and cloud-init verified" "${logs[0]}"
! grep -Fq secret-fixture "${logs[0]}"
echo 'Readiness daemon: arguments and log confidentiality passed'
