#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
listener_pid=''
cleanup() {
  if [[ -n "${listener_pid}" ]]; then
    kill "${listener_pid}" 2>/dev/null || true
    wait "${listener_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

fixture_bin="${test_tmp}/bin"
runtime_dir="${test_tmp}/home/projects/probe"
monitor_sock="${runtime_dir}/monitor.sock"
capture="${test_tmp}/capture"
mkdir -p "${fixture_bin}" "${runtime_dir}"
ln -s "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"

socat UNIX-LISTEN:"${monitor_sock}" SYSTEM:"cat >${capture}" &
listener_pid=$!
for _ in {1..50}; do
  [[ -S "${monitor_sock}" ]] && break
  sleep 0.02
done
[[ -S "${monitor_sock}" ]]

SYSTEMCTL_ACTIVE_STATE=active VIRTDEV_HOME="${test_tmp}/home" \
  PATH="${fixture_bin}:${PATH}" \
  "${repository}/libexec/virtdev/virtdev-stop-acpi" probe
[[ ! -e "${capture}" ]]

SYSTEMCTL_ACTIVE_STATE=deactivating VIRTDEV_HOME="${test_tmp}/home" \
  PATH="${fixture_bin}:${PATH}" \
  "${repository}/libexec/virtdev/virtdev-stop-acpi" probe
wait "${listener_pid}"
listener_pid=''
[[ "$(< "${capture}")" == system_powerdown ]]

rm -f -- "${monitor_sock}"
SYSTEMCTL_ACTIVE_STATE=deactivating VIRTDEV_HOME="${test_tmp}/home" \
  PATH="${fixture_bin}:${PATH}" \
  "${repository}/libexec/virtdev/virtdev-stop-acpi" probe

printf 'ok - private ACPI hook requires deactivating context and is best effort\n'
