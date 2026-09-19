#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
files=(
    "$repo_root/qemuinstall.sh"
    "$repo_root/scripts/create_qemu.sh"
    "$repo_root/qemuuninstall.sh"
    "$repo_root/scripts/delete_qemu.sh"
)

extract_normalizer() {
    awk '
        /^normalize_noninteractive\(\)/ { in_fn=1 }
        in_fn { print }
        in_fn && /^}/ { exit }
    ' "$1"
}

for file in "${files[@]}"; do
    normalizer=$(extract_normalizer "$file")
    [[ -n "$normalizer" ]] || { echo "normalizer missing: $file" >&2; exit 1; }
    run_case() {
        local expected=$1 canonical=$2 alias=$3 env_args="PATH=$PATH HOME=/tmp"
        [[ "$canonical" == __unset__ ]] || env_args+=" noninteractive=$canonical"
        [[ "$alias" == __unset__ ]] || env_args+=" NONINTERACTIVE=$alias"
        local result
        result=$(env -i $env_args bash -c "${normalizer}; normalize_noninteractive; printf '%s' \"\$noninteractive\"")
        [[ "$result" == "$expected" ]] || {
            echo "unexpected mode for $file: expected=$expected got=$result" >&2
            exit 1
        }
    }
    run_case true true false
    run_case false false true
    run_case true __unset__ true
    run_case false __unset__ false
    child=$(env -i PATH="$PATH" HOME=/tmp noninteractive=true NONINTERACTIVE=false \
        bash -c "${normalizer}; normalize_noninteractive; bash -c 'printf %s \"\$noninteractive\"'")
    [[ "$child" == true ]] || { echo "child mode was not exported: $file" >&2; exit 1; }
done

echo "QEMU noninteractive mode tests passed"
