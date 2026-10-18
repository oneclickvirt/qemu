#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090 # Load the actual installer helper without running main.
source <(awk '/^redefine_idle_network_ipv6\(\) \{/ {p=1} p {print} p && /^}$/ {exit}' "$root/qemuinstall.sh")
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/network.xml" <<'XML'
<network><name>default</name><uuid>keep-uuid</uuid><forward mode="nat"/><bridge name="virbr0"/><ip address="192.168.122.1"><dhcp><host mac="52:54:00:00:00:01" ip="192.168.122.2"/></dhcp></ip></network>
XML
cp "$fixture/network.xml" "$fixture/original.xml"
running=0
fail_start=0
virsh() {
    echo "$*" >> "$fixture/calls"
    case "$1" in
        list) if ((running)); then echo busy; fi ;;
        domiflist) echo 'vnet0 network default virtio 52:54:00:00:00:01' ;;
        net-dumpxml) cat "$fixture/network.xml" ;;
        net-define) cp "$2" "$fixture/network.xml" ;;
        net-destroy) : ;;
        net-start) if ((fail_start)); then fail_start=0; return 1; fi ;;
        *) return 1 ;;
    esac
}
xml='<ip family="ipv6" address="fd42:122::1" prefix="64"/>'
running=1
if redefine_idle_network_ipv6 "$xml"; then exit 1; fi
! grep -q net-destroy "$fixture/calls"
running=0
redefine_idle_network_ipv6 "$xml"
python3 - "$fixture/network.xml" <<'PY'
import sys, xml.etree.ElementTree as E
r=E.parse(sys.argv[1]).getroot()
assert r.findtext('uuid')=='keep-uuid'
assert r.find('ip/dhcp/host').get('ip')=='192.168.122.2'
assert len(r.findall('ip'))==2
assert r.find('forward/nat').get('ipv6')=='yes'
PY
# Administrator IPv6 must be preserved without a network restart.
: > "$fixture/calls"
if redefine_idle_network_ipv6 "$xml"; then exit 1; fi
! grep -q net-destroy "$fixture/calls"
cp "$fixture/original.xml" "$fixture/network.xml"
fail_start=1
if redefine_idle_network_ipv6 "$xml"; then exit 1; fi
cmp "$fixture/original.xml" "$fixture/network.xml"
echo 'Network redefinition: active guest protection, XML preservation and rollback passed'
