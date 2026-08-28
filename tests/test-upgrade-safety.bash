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
printf 'ssh-host-identity=1\n' > "${virtdev_home}/system/guest-contract"
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

# A genuinely detached exclusion is safe for backing identity, but maintenance
# still requires it stopped. This must fail before Phase 1 touches `keep`.
printf 'detached\n' > "${virtdev_home}/projects/omitted/generation"
: > "${virtdev_home}/projects/omitted/system.qcow2"
: > "${virtdev_home}/projects/omitted/home.qcow2"
output="${test_tmp}/running-detached.output"
status=0
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${repository}/tests/fixtures:${PATH}" QEMU_HAS_BACKING=0 \
SYSTEMCTL_ACTIVE_STATE=active \
  "${repository}/bin/virtdev-upgrade" --unfiltered --only=keep --yes \
  >"${output}" 2>&1 || status=$?

if (( status != 13 )); then
  printf 'expected exit 13 for running detached exclusion, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if ! grep -Fq 'Excluded detached projects must be stopped before upgrade' "${output}"; then
  printf 'missing early running-exclusion refusal\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - upgrade preflights running excluded projects before Phase 1\n'
