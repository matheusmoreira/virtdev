#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

virtdev_home="${test_tmp}/virtdev"
config_home="${test_tmp}/config"
mkdir -p "${virtdev_home}/system" "${virtdev_home}/projects/keep" \
  "${virtdev_home}/projects/omitted" "${config_home}"
printf '7\n' > "${virtdev_home}/system/generation"
printf '7\n' > "${virtdev_home}/projects/keep/generation"
printf '7\n' > "${virtdev_home}/projects/omitted/generation"
printf '/etc/hostname\n' > "${virtdev_home}/projects/keep/manifest"

output="${test_tmp}/output"
status=0
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
  "${repository}/bin/virtdev-upgrade" --unfiltered --only=keep --yes \
  >"${output}" 2>&1 || status=$?

if (( status != 12 )); then
  printf 'expected exit 12, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

if ! grep -Fq 'Cannot reseal while coupled projects are excluded.' "${output}"; then
  printf 'missing coupled-project refusal\n' >&2
  cat "${output}" >&2
  exit 1
fi

if ! grep -Fq 'omitted' "${output}"; then
  printf 'refusal did not identify the omitted project\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - filtered upgrade refuses a coupled omitted project\n'
