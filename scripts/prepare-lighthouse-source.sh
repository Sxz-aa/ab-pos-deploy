#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly source_dir="${build_dir}/src/lighthouse"
readonly patch_dir="${root_dir}/patches/lighthouse"
readonly lighthouse_repository="${LIGHTHOUSE_REPOSITORY:-https://github.com/sigp/lighthouse.git}"
readonly lighthouse_version="${LIGHTHOUSE_VERSION:-v8.2.2}"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || fail "git is required"
[[ "${lighthouse_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "LIGHTHOUSE_VERSION must be an upstream vMAJOR.MINOR.PATCH tag"
[[ -d "${patch_dir}" ]] || fail "patch directory not found: ${patch_dir}"

shopt -s nullglob
patches=("${patch_dir}"/*.patch)
(( ${#patches[@]} > 0 )) || fail "no patches found under ${patch_dir}"

mkdir -p "$(dirname "${source_dir}")"
if [[ ! -e "${source_dir}" ]]; then
    printf 'Cloning lighthouse %s from %s\n' "${lighthouse_version}" "${lighthouse_repository}"
    git clone --depth 1 --branch "${lighthouse_version}" "${lighthouse_repository}" "${source_dir}"
elif [[ ! -d "${source_dir}/.git" ]]; then
    fail "generated source path exists but is not a Git checkout: ${source_dir}; run make clean"
fi

git -C "${source_dir}" remote set-url origin "${lighthouse_repository}"
git -C "${source_dir}" fetch --depth 1 origin "refs/tags/${lighthouse_version}:refs/tags/${lighthouse_version}" \
    || fail "unable to fetch lighthouse tag ${lighthouse_version}"
git -C "${source_dir}" checkout --force --detach "${lighthouse_version}"
git -C "${source_dir}" reset --hard "${lighthouse_version}" >/dev/null
git -C "${source_dir}" clean -fdx >/dev/null

for patch in "${patches[@]}"; do
    printf 'Checking patch %s against lighthouse %s\n' "$(basename "${patch}")" "${lighthouse_version}"
    if ! check_output="$(git -C "${source_dir}" apply --check "${patch}" 2>&1)"; then
        printf 'ERROR: git apply --check failed for %s against lighthouse %s.\n' \
            "${patch}" "${lighthouse_version}" >&2
        [[ -z "${check_output}" ]] || printf '%s\n' "${check_output}" >&2
        exit 1
    fi
    git -C "${source_dir}" apply "${patch}" \
        || fail "failed to apply ${patch} after a successful check"
done

printf 'Prepared patched lighthouse source at %s\n' "${source_dir}"
