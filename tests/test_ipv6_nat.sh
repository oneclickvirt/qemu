#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/qemuinstall.sh"
creator="$repo_root/scripts/oneqemu.sh"

extract_function() {
    local file="$1" name="$2"
    awk -v name="$name" '
        $0 == name "() {" { printing = 1 }
        printing {
            print
            if ($0 == "}") {
                exit
            }
        }
    ' "$file"
}

# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
source <(extract_function "$installer" host_has_ipv6_default_route)
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
source <(extract_function "$installer" ipv6_default_route_interface)
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
source <(extract_function "$installer" qemu_ipv6_network_xml)
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
source <(extract_function "$installer" default_network_has_qemu_ipv6)
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
source <(extract_function "$installer" ensure_default_network_ipv6)
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
source <(extract_function "$installer" configure_ipv6_nat_nft)
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
source <(extract_function "$installer" configure_ipv6_nat_iptables)
# shellcheck disable=SC1090 # The test intentionally loads the creator helper.
source <(extract_function "$creator" vm_ipv6_from_lease)

QEMU_IPV6_SUBNET="fd42:122::/64"
QEMU_IPV6_GATEWAY="fd42:122::1"
QEMU_IPV6_DHCP_START="fd42:122::100"
QEMU_IPV6_DHCP_END="fd42:122::1ff"
_yellow() { :; }
_green() { :; }

ip() {
    printf '%s\n' '2001:4860:4860::8888 via fe80::1 dev eth0 src 2a14:6781:a::9 metric 1024'
}
if ! host_has_ipv6_default_route; then
    printf 'a usable IPv6 route with a global source was rejected\n' >&2
    exit 1
fi

ip() {
    printf '%s\n' 'unreachable 2001:4860:4860::8888 dev lo src ::1 metric 4294967295'
}
if host_has_ipv6_default_route; then
    printf 'an unreachable IPv6 route was accepted for NAT66\n' >&2
    exit 1
fi

ip() {
    printf '%s\n' '2001:4860:4860::8888 via fe80::1 dev eth0 src fd42::1 metric 1024'
}
if host_has_ipv6_default_route; then
    printf 'a ULA-only IPv6 route was accepted for NAT66\n' >&2
    exit 1
fi

ip() {
    printf '%s\n' 'default via fe80::1 dev eth0 proto ra metric 1024'
}
if [[ "$(ipv6_default_route_interface)" != eth0 ]]; then
    printf 'IPv6 default-route interface detection did not select eth0\n' >&2
    exit 1
fi
if ! grep -Fq 'accept_ra = 2' "$installer"; then
    printf 'QEMU IPv6 forwarding must preserve router advertisements on its uplink\n' >&2
    exit 1
fi

network_has_ipv6=false
net_update_seen=false
virsh() {
    case "$1:$2" in
        net-dumpxml:default)
            if [[ "$network_has_ipv6" == true ]]; then
                printf '%s\n' "<network><ip family='ipv6' address='${QEMU_IPV6_GATEWAY}' prefix='64'/></network>"
            else
                printf '%s\n' '<network><ip address="192.168.122.1"/></network>'
            fi
            ;;
        net-update:default)
            [[ "$3" == add && "$4" == ip && "$5" == *"${QEMU_IPV6_GATEWAY}"* && "$6" == --live && "$7" == --config ]] || return 1
            network_has_ipv6=true
            net_update_seen=true
            ;;
        domifaddr:vm1)
            printf '%s\n' 'vnet0 52:54:00:11:22:33 ipv6 fd42:122::102/64'
            ;;
        *)
            printf 'unexpected virsh invocation: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
if ! ensure_default_network_ipv6; then
    printf 'existing default network did not receive its managed ULA IPv6 range\n' >&2
    exit 1
fi
[[ "$net_update_seen" == true ]] || {
    printf 'IPv6 migration did not use a live and persistent net-update\n' >&2
    exit 1
}
if ! default_network_has_qemu_ipv6; then
    printf 'managed ULA IPv6 range was not verified after migration\n' >&2
    exit 1
fi

if [[ "$(qemu_ipv6_network_xml)" != *"${QEMU_IPV6_DHCP_START}"* ]]; then
    printf 'managed IPv6 network XML does not include the DHCPv6 range\n' >&2
    exit 1
fi
if [[ "$(vm_ipv6_from_lease vm1 52:54:00:11:22:33)" != 'fd42:122::102' ]]; then
    printf 'VM IPv6 lease parsing did not return the actual DHCPv6 address\n' >&2
    exit 1
fi

nft_postrouting='masquerade'
nft_forward=''
nft() {
    case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
        add:table:ip6:qemu6:*)
            return 0
            ;;
        list:table:ip6:qemu6:*)
            return 0
            ;;
        add:chain:ip6:qemu6:*)
            return 0
            ;;
        list:chain:ip6:qemu6:postrouting)
            printf '%s\n' "$nft_postrouting"
            return 0
            ;;
        list:chain:ip6:qemu6:forward)
            printf '%s\n' "$nft_forward"
            return 0
            ;;
        add:rule:ip6:qemu6:postrouting)
            nft_postrouting="ip6 saddr ${QEMU_IPV6_SUBNET} ip6 daddr != ${QEMU_IPV6_SUBNET} masquerade"
            return 0
            ;;
        add:rule:ip6:qemu6:forward)
            case "$*" in
                *'ip6 daddr '*) nft_forward+=" ip6 daddr ${QEMU_IPV6_SUBNET} accept" ;;
                *'ip6 saddr '*) nft_forward+=" ip6 saddr ${QEMU_IPV6_SUBNET} accept" ;;
                *) nft_forward+=' ct state established,related accept' ;;
            esac
            return 0
            ;;
        *)
            printf 'unexpected nft invocation: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
if ! configure_ipv6_nat_nft; then
    printf 'nft NAT66 helper did not verify a complete managed rule set\n' >&2
    exit 1
fi
[[ "$nft_postrouting" == *"ip6 saddr ${QEMU_IPV6_SUBNET}"* ]] || {
    printf 'an unrelated nft masquerade rule was accepted without adding the managed subnet rule\n' >&2
    exit 1
}

nft() { return 1; }
if configure_ipv6_nat_nft; then
    printf 'nft NAT66 helper accepted an unavailable IPv6 nftables family\n' >&2
    exit 1
fi

ip6tables_rules_ready=false
ip6tables() {
    case "$*" in
        *'-C '*) "$ip6tables_rules_ready" ;;
        *'-I '*) ip6tables_rules_ready=true ;;
        *) return 1 ;;
    esac
}
if ! configure_ipv6_nat_iptables; then
    printf 'ip6tables NAT66 helper did not verify its installed rule set\n' >&2
    exit 1
fi

ip6tables() { return 1; }
if configure_ipv6_nat_iptables; then
    printf 'ip6tables NAT66 helper accepted a failed rule installation\n' >&2
    exit 1
fi

printf '%s\n' 'qemu IPv6 NAT tests passed'
