#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for helper in create_cloudinit_yaml create_cloudinit_iso; do
    # shellcheck disable=SC1090 # Exercise seed creation without starting a VM.
    source <(awk -v name="$helper" '$0==name"() {" {p=1} p {print} p && /^}$/ {exit}' "$root/scripts/oneqemu.sh")
done
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
# shellcheck disable=SC2034 # Read by the sourced ISO helper.
images_path="$fixture"
cloud-localds() {
    cp "${1#--network-config=}" "$fixture/network-data"
    cp "$3" "$fixture/user-data"
    printf seed > "$2"
}
password="a:b'c\$(touch /tmp/ocv-not-executed)"
create_cloudinit_iso vm-fixture "$password" 52:54:00:11:22:33 >/dev/null
python3 - "$fixture" "$password" <<'PY'
import json, os, pathlib, subprocess, sys
p=pathlib.Path(sys.argv[1])
data=(p/'user-data').read_text()
assert 'chpasswd:\n' not in data
assert 'lock_passwd: false' in data
network=(p/'network-data').read_text()
assert '52:54:00:11:22:33' in network and 'dhcp6: true' in network
command=next(json.loads(line.strip()[2:]) for line in data.splitlines() if line.startswith('  - "printf'))
stub=p/'chpasswd'
stub.write_text('#!/bin/sh\ncat > "$CAPTURE"\n')
stub.chmod(0o700)
env=dict(os.environ, PATH=str(p)+os.pathsep+os.environ['PATH'], CAPTURE=str(p/'password-input'))
subprocess.run(['sh','-c',command],check=True,env=env)
assert (p/'password-input').read_text()=='root:'+sys.argv[2]+'\n'
PY
echo 'Cloud-init seed: MAC matching, DHCPv6 and literal password initialization passed'
