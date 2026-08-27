#!/usr/bin/env bash
# shellcheck disable=SC2154  # runtime constants provided by imported qemu/runtime

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

export PATH="${repository}/tests/fixtures:${PATH}"
# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import qemu

runtime_directory="${test_tmp}/runtime"
mkdir "${runtime_directory}"
for name in "${runtime_socket_basenames[@]}" "${runtime_port_name}"; do
  : > "${runtime_directory}/${name}"
done

SYSTEMCTL_ACTIVE_STATE=activating
export SYSTEMCTL_ACTIVE_STATE
if qemu_stop_unit_then_clean_runtime virtdev-probe "${runtime_directory}" 0; then
  printf 'transitional unit was incorrectly accepted as terminal\n' >&2
  exit 1
fi
for name in "${runtime_socket_basenames[@]}" "${runtime_port_name}"; do
  if [[ ! -e "${runtime_directory}/${name}" ]]; then
    printf 'runtime control %s was removed before terminal proof\n' "${name}" >&2
    exit 1
  fi
done

SYSTEMCTL_ACTIVE_STATE=inactive
export SYSTEMCTL_ACTIVE_STATE
if ! qemu_stop_unit_then_clean_runtime virtdev-probe "${runtime_directory}" 0; then
  printf 'inactive unit was not accepted as terminal\n' >&2
  exit 1
fi
for name in "${runtime_socket_basenames[@]}" "${runtime_port_name}"; do
  if [[ -e "${runtime_directory}/${name}" ]]; then
    printf 'runtime control %s survived confirmed terminal cleanup\n' "${name}" >&2
    exit 1
  fi
done

printf 'ok - failed-start cleanup preserves controls until terminal proof\n'
