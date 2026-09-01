#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly source_dir="${build_dir}/src/go-ethereum"
readonly patch_dir="${root_dir}/patches/go-ethereum"
readonly geth_repository="${GETH_REPOSITORY:-https://github.com/ethereum/go-ethereum.git}"
readonly geth_version="${GETH_VERSION:-v1.17.5}"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || fail "git is required"
[[ -d "${patch_dir}" ]] || fail "patch directory not found: ${patch_dir}"

shopt -s nullglob
patches=("${patch_dir}"/*.patch)
(( ${#patches[@]} > 0 )) || fail "no patches found under ${patch_dir}"

mkdir -p "$(dirname "${source_dir}")"
if [[ ! -e "${source_dir}" ]]; then
    printf 'Cloning go-ethereum %s from %s\n' "${geth_version}" "${geth_repository}"
    git clone --filter=blob:none --no-checkout "${geth_repository}" "${source_dir}"
elif [[ ! -d "${source_dir}/.git" ]]; then
    fail "generated source path exists but is not a Git checkout: ${source_dir}; run make clean"
fi

git -C "${source_dir}" remote set-url origin "${geth_repository}"
git -C "${source_dir}" fetch --force --tags origin "refs/tags/${geth_version}:refs/tags/${geth_version}" \
    || fail "unable to fetch go-ethereum tag ${geth_version}"
git -C "${source_dir}" checkout --force --detach "${geth_version}"
git -C "${source_dir}" reset --hard "${geth_version}" >/dev/null
git -C "${source_dir}" clean -fdx >/dev/null

for patch in "${patches[@]}"; do
    printf 'Checking patch %s against go-ethereum %s\n' "$(basename "${patch}")" "${geth_version}"
    if ! check_output="$(git -C "${source_dir}" apply --check "${patch}" 2>&1)"; then
        printf 'ERROR: git apply --check failed for %s against go-ethereum %s.\n' \
            "${patch}" "${geth_version}" >&2
        [[ -z "${check_output}" ]] || printf '%s\n' "${check_output}" >&2
        exit 1
    fi
    git -C "${source_dir}" apply "${patch}" \
        || fail "failed to apply ${patch} after a successful check"
done

printf 'Prepared patched go-ethereum source at %s\n' "${source_dir}"
