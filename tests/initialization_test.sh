#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/qemuinstall.sh"
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$installer")
}
load_function configure_storage_pool
load_function configure_default_network
_green() { :; }
_yellow() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
QEMU_STATE_DIR=$(mktemp -d)
trap 'rm -f -- "$QEMU_STATE_DIR/qemu_bridge"; rmdir -- "$QEMU_STATE_DIR"' EXIT
qemu_images_path="$QEMU_STATE_DIR"
mock_pool_active=false mock_net_active=false mock_start_fails=false mock_starts=0
select_qemu_ipv6_subnet() { return 1; }
virsh() {
    case "$*" in
        'pool-info default'|'net-info default') return 0 ;;
        'pool-list --name') if $mock_pool_active; then printf '%s\n' default; fi ;;
        'net-list --name') if $mock_net_active; then printf '%s\n' default; fi ;;
        'pool-list --all'|'net-list --all') printf '%s\n' 'default inactive no yes' ;;
        'pool-start default')
            $mock_start_fails && return 1
            mock_pool_active=true; mock_starts=$((mock_starts + 1)) ;;
        'net-start default')
            $mock_start_fails && return 1
            mock_net_active=true; mock_starts=$((mock_starts + 1)) ;;
        'pool-autostart default'|'net-autostart default') return 0 ;;
        'net-dumpxml default') printf '%s\n' '<bridge name="virbr0"/>' ;;
        *) fail "Unexpected virsh command: $*" ;;
    esac
}
configure_storage_pool || fail 'inactive existing pool must be started'
configure_default_network || fail 'inactive existing network must be started'
[[ "$mock_starts" == 2 ]] || fail 'inactive must not be mistaken for active'
configure_storage_pool || fail 'active pool should succeed'
configure_default_network || fail 'active network should succeed'
[[ "$mock_starts" == 2 ]] || fail 'active resources must not be restarted'
mock_start_fails=true mock_pool_active=false mock_net_active=false
if configure_storage_pool; then fail 'pool-start failure must propagate'; fi
if configure_default_network; then fail 'net-start failure must propagate'; fi
qemu_source=$(<"$installer")
grep -Fq 'include "/etc/nftables.d/qemu.nft"' <<<"$qemu_source" ||
    fail 'QEMU nftables rules must have a persistent include target'
grep -Fq 'cat > /etc/nftables.conf' <<<"$qemu_source" ||
    fail 'QEMU must create the nftables main config when it is absent'
printf 'QEMU installation fault-injection tests passed (4 scenarios)\n'
# Exercise the real Debian update expression as well as installation. In
# particular, a successful first update must not enter the repair branch.
source <(awk '/^PACKAGE_UPDATE=\(/ { printing=1 } printing { print } printing && /^\)/ { exit }' "$installer")
source <(awk '/^PACKAGE_INSTALL=\(/ { printing=1 } printing { print } printing && /^\)/ { exit }' "$installer")
for name in install_base_deps install_qemu_stack; do
    load_function "$name"
    for scenario in success recovered update_failed repair_failed install_failed; do
        (
            SYSTEM=Debian int=0 mock_updates=0 mock_repairs=0 mock_installs=0
            apt-get() {
                case "$*" in
                    update)
                        mock_updates=$((mock_updates + 1))
                        case "$scenario:$mock_updates" in
                            recovered:1|update_failed:*|repair_failed:1) return 100 ;;
                        esac
                        ;;
                    '--fix-broken install -y')
                        mock_repairs=$((mock_repairs + 1))
                        [[ "$scenario" != repair_failed ]] || return 100
                        ;;
                    '-y install '*)
                        mock_installs=$((mock_installs + 1))
                        if [[ "$name" == install_qemu_stack ]]; then
                            [[ " $* " == *" libvirt-daemon-driver-lxc "* ]] || fail "Debian QEMU container driver missing"
                        fi
                        [[ "$scenario" != install_failed ]] || return 100
                        ;;
                    *) fail "Unexpected apt-get: $*" ;;
                esac
                return 0
            }
            rc=0
            "$name" || rc=$?
            case "$scenario" in
                success) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 0:1:0:1 ]] ;;
                recovered) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 0:2:1:1 ]] ;;
                update_failed) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 1:2:1:0 ]] ;;
                repair_failed) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 1:1:1:0 ]] ;;
                install_failed) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 1:1:0:1 ]] ;;
            esac || fail "$name/$scenario returned $rc with updates=$mock_updates repairs=$mock_repairs installs=$mock_installs"
        )
    done
done
printf 'Debian package-update and repair paths passed\n'
