#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly source_dir="${build_dir}/src/reth"
readonly patch_dir="${root_dir}/patches/reth"
readonly reth_repository="${RETH_REPOSITORY:-https://github.com/paradigmxyz/reth.git}"
readonly reth_source_commit="${RETH_SOURCE_COMMIT:-1136e1140023de2468e395a2633cf90cd3d03780}"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || fail "git is required"
[[ "${reth_source_commit}" =~ ^[0-9a-f]{40}$ ]] \
    || fail "RETH_SOURCE_COMMIT must be a full 40-character Git commit SHA"
[[ -d "${patch_dir}" ]] || fail "patch directory not found: ${patch_dir}"

shopt -s nullglob
patches=("${patch_dir}"/*.patch)
(( ${#patches[@]} > 0 )) || fail "no patches found under ${patch_dir}"

mkdir -p "$(dirname "${source_dir}")"

if [[ ! -e "${source_dir}" ]]; then
    printf 'Cloning Reth source from %s\n' "${reth_repository}"
    git clone --filter=blob:none --no-checkout "${reth_repository}" "${source_dir}"
elif [[ ! -d "${source_dir}/.git" ]]; then
    fail "generated source path exists but is not a Git checkout: ${source_dir}; run make clean"
fi

git -C "${source_dir}" remote set-url origin "${reth_repository}"

printf 'Fetching Reth source commit %s\n' "${reth_source_commit}"
git -C "${source_dir}" fetch --force origin "${reth_source_commit}" \
    || fail "unable to fetch Reth source commit ${reth_source_commit}"

git -C "${source_dir}" checkout --force --detach "${reth_source_commit}"
git -C "${source_dir}" reset --hard "${reth_source_commit}" >/dev/null
git -C "${source_dir}" clean -fdx >/dev/null

[[ "$(git -C "${source_dir}" rev-parse HEAD)" == "${reth_source_commit}" ]] \
    || fail "Reth source HEAD does not match RETH_SOURCE_COMMIT"

for patch in "${patches[@]}"; do
    printf 'Checking patch %s against Reth %s\n' \
        "$(basename "${patch}")" "${reth_source_commit}"

    if ! check_output="$(git -C "${source_dir}" apply --check "${patch}" 2>&1)"; then
        printf 'ERROR: git apply --check failed for %s against Reth %s.\n' \
            "${patch}" "${reth_source_commit}" >&2
        [[ -z "${check_output}" ]] || printf '%s\n' "${check_output}" >&2
        exit 1
    fi

    git -C "${source_dir}" apply "${patch}" \
        || fail "failed to apply ${patch} after a successful check"
done

printf 'Prepared patched Reth source at %s\n' "${source_dir}"
