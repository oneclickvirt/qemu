#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Load only the pure download functions, never the installer entry point.
load_function() { eval "$(awk -v name="$1" '$0 ~ "^" name "\\(\\)" {p=1} p {print} p && /^}/ {exit}' "$repo_root/scripts/oneqemu.sh")"; }
for fn in try_pve_kvm_images try_kvm_images download_cloud_image; do load_function "$fn"; done
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
_yellow() { :; }; _green() { :; }; _red() { :; }
write_image_checksum() { :; }
cdn_success_url=""
calls=()
accepted=""
curl() {
    local output="" url="${!#}"
    calls+=("$url")
    while (($#)); do
        if [[ "$1" == -o ]]; then output="$2"; shift; fi
        shift
    done
    [[ -n "$output" ]] && printf 'partial' >"$output"
    [[ "$url" == "$accepted" ]] || return 22
    printf 'valid-image' >"$output"
}
assert_url() { [[ "$1" == "$2" ]] || { printf 'URL mismatch: %s != %s\n' "$1" "$2" >&2; exit 1; }; }
accepted="https://github.com/oneclickvirt/pve_kvm_images/releases/download/ubuntu/ubuntu2204.qcow2"
try_pve_kvm_images ubuntu22 "$work_dir/image" ubuntu
assert_url "${calls[0]}" "$accepted"
cdn_success_url="https://cdn.invalid/"
calls=()
try_pve_kvm_images ubuntu22 "$work_dir/image" ubuntu
[[ ${#calls[@]} == 2 ]]
assert_url "${calls[1]}" "$accepted"
calls=(); cdn_success_url=""
accepted="https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/debian12.qcow2"
try_pve_kvm_images debian12 "$work_dir/image" debian
assert_url "${calls[-1]}" "$accepted"
accepted="https://github.com/oneclickvirt/kvm_images/releases/download/v2.0/debian12.qcow2"
calls=(); try_kvm_images debian12 "$work_dir/image"
assert_url "${calls[0]}" "$accepted"
accepted="https://github.com/oneclickvirt/kvm_images/releases/download/v1.0/opensuse-leap-15.qcow2"
calls=(); try_kvm_images opensuse-leap-15 "$work_dir/image"
assert_url "${calls[0]}" "$accepted"
calls=(); if try_kvm_images ubuntu24 "$work_dir/image"; then exit 1; fi
[[ ${#calls[@]} == 0 ]]
printf 'existing' >"$work_dir/image"
accepted="unavailable"; if try_pve_kvm_images debian12 "$work_dir/image" debian; then exit 1; fi
[[ $(cat "$work_dir/image") == existing && ! -e "$work_dir/image.tmp" ]]
# ARM never downloads the x86-only organization assets.
try_pve_kvm_images() { echo 'wrong architecture' >&2; exit 9; }
try_kvm_images() { echo 'wrong architecture' >&2; exit 9; }
get_official_image_url() { CLOUD_IMG_URL="https://upstream.invalid/debian-arm64.qcow2"; }
ARCH_TYPE=arm64; system=debian12; en_system=debian; num_system=12; images_path="$work_dir"
accepted="https://upstream.invalid/debian-arm64.qcow2"; calls=()
download_cloud_image
assert_url "${calls[0]}" "$accepted"
echo 'QEMU published image source and fallback tests passed'
