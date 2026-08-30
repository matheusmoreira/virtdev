#!/usr/bin/env bash
# shellcheck disable=SC2154  # generation_max is provided by the imported project library

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

virtdev_home="${test_tmp}/virtdev"
project_directory="${virtdev_home}/projects/probe"
mkdir -p "${project_directory}"
printf 'detached\n' > "${project_directory}/generation"
: > "${project_directory}/system.qcow2"
: > "${project_directory}/home.qcow2"

qemu-img() {
if [[ "${QEMU_HAS_BACKING:-0}" == 1 ]]; then
  printf '{"backing-filename":"/base/system.qcow2"}\n'
else
  printf '{}\n'
fi
}

export VIRTDEV_HOME="${virtdev_home}"
# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import project

QEMU_HAS_BACKING=1
export QEMU_HAS_BACKING
if project_is_detached probe; then
  printf 'text marker bypassed a real backing dependency\n' >&2
  exit 1
fi

QEMU_HAS_BACKING=0
export QEMU_HAS_BACKING
if ! project_is_detached probe; then
  printf 'standalone disks with detached marker were not recognized\n' >&2
  exit 1
fi

mkdir -p "${virtdev_home}/system"
printf '1\n' > "${virtdev_home}/system/generation"
printf '1\n' > "${project_directory}/generation"
if project_is_outdated probe; then
  printf 'matching generation was classified outdated\n' >&2
  exit 1
fi
rm -f "${project_directory}/generation"
status=0
project_is_outdated probe || status=$?
if (( status != 2 )); then
  printf 'missing project generation returned %d instead of corrupt state\n' \
    "${status}" >&2
  exit 1
fi
printf '1\n' > "${project_directory}/generation"
rm -f "${virtdev_home}/system/generation"
status=0
project_is_outdated probe || status=$?
if (( status != 3 )); then
  printf 'missing base generation returned %d instead of corrupt state\n' \
    "${status}" >&2
  exit 1
fi

generation_case="${test_tmp}/generation"
output="${test_tmp}/output"

expect_corrupt() {
  local -r reader="${1}"
  local status=0
  ( "${reader}" "${generation_case}" ) >"${output}" 2>&1 || status=$?
  if (( status != 82 )); then
    printf '%s accepted corrupt generation (status %d): ' "${reader}" "${status}" >&2
    cat "${output}" >&2
    exit 1
  fi
}

printf 'detached\n' > "${generation_case}"
expect_corrupt generation_read_base
if [[ "$(generation_read_project "${generation_case}")" != detached ]]; then
  printf 'project reader rejected its detached marker\n' >&2
  exit 1
fi

printf '01\n' > "${generation_case}"
expect_corrupt generation_read_base
expect_corrupt generation_read_project

printf '2147483648\n' > "${generation_case}"
expect_corrupt generation_read_base

printf '2147483647\n' > "${generation_case}"
if [[ "$(generation_read_base "${generation_case}")" != "${generation_max}" ]]; then
  printf 'base reader rejected the maximum safe generation\n' >&2
  exit 1
fi

printf '7\n\n' > "${generation_case}"
expect_corrupt generation_read_base

truncate -s 1048576 "${generation_case}"
expect_corrupt generation_read_base
if (( $(stat -c '%s' "${output}") > 1024 )); then
  printf 'corrupt scalar diagnostic was not bounded\n' >&2
  exit 1
fi

printf 'ok - detached state requires standalone disk topology\n'
printf 'ok - generation schemas are type-separated, canonical, and bounded\n'
printf 'ok - missing generation metadata is corrupt rather than current\n'
