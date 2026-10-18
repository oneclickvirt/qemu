#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090
source <(awk '$0=="create_disk() {" {p=1} p {print} p && /^}$/ {exit}' "$root/scripts/oneqemu.sh")
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
# shellcheck disable=SC2034
images_path="$fixture" system=debian13
_yellow() { :; }
qemu-img() {
    if [[ "$1" == info ]]; then
        printf '%s\n' "$image_info"
    else
        touch "$fixture/created"
    fi
}
image_info='{"virtual-size":3221225472}'
if create_disk test 1 >/dev/null 2>&1; then echo 'undersized disk accepted' >&2; exit 1; fi
[[ ! -e "$fixture/created" ]]
create_disk test 8 >/dev/null
[[ -e "$fixture/created" ]]
rm "$fixture/created"
image_info='{}'
if create_disk test 8 >/dev/null 2>&1; then echo 'invalid image metadata accepted' >&2; exit 1; fi
[[ ! -e "$fixture/created" ]]
echo 'Disk capacity: backing truncation and invalid metadata rejected'
