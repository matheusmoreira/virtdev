#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

virtdev_home="${test_tmp}/virtdev"
project_directory="${virtdev_home}/projects/probe"
mkdir -p "${virtdev_home}/system" "${project_directory}"
printf '8\n' > "${virtdev_home}/system/generation"
printf '7\n' > "${project_directory}/generation"
: > "${project_directory}/system.qcow2"
: > "${project_directory}/home.qcow2"

output="${test_tmp}/output"
qemu_log="${test_tmp}/qemu.log"
status=0
VIRTDEV_HOME="${virtdev_home}" \
PATH="${repository}/tests/fixtures:${PATH}" \
QEMU_LOG="${qemu_log}" \
  "${repository}/bin/virtdev-detach" --yes probe >"${output}" 2>&1 \
  || status=$?

if (( status != 7 )); then
  printf 'expected exit 7, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

if ! grep -Fq 'Detaching now would flatten the delta against replacement base bytes' "${output}"; then
  printf 'missing generation-mismatch refusal\n' >&2
  cat "${output}" >&2
  exit 1
fi

if [[ -e "${qemu_log}" ]]; then
  printf 'detach invoked a mutating qemu-img operation after refusing mismatch\n' >&2
  cat "${qemu_log}" >&2
  exit 1
fi

printf 'ok - detach refuses generation-mismatched deltas before mutation\n'

printf '8\n' > "${project_directory}/generation"
status=0
VIRTDEV_HOME="${virtdev_home}" \
PATH="${repository}/tests/fixtures:${PATH}" \
QEMU_INFO_STATUS=5 \
QEMU_LOG="${qemu_log}" \
  "${repository}/bin/virtdev-detach" --yes probe >"${output}" 2>&1 \
  || status=$?

if (( status != 9 )) \
    || ! grep -Fq 'Could not inspect system disk backing topology' "${output}" \
    || grep -Fq 'has no backing file' "${output}"; then
  printf 'detach misdiagnosed a topology inspection failure (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ -e "${qemu_log}" ]]; then
  printf 'detach mutated a disk after topology inspection failure\n' >&2
  cat "${qemu_log}" >&2
  exit 1
fi

printf 'ok - detach distinguishes inspection failure from no backing file\n'
