#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
listener_pid=''
guest_pid=''
hook_pid=''
cleanup() {
  if [[ -n "${hook_pid}" ]]; then
    kill "${hook_pid}" 2>/dev/null || true
    wait "${hook_pid}" 2>/dev/null || true
  fi
  if [[ -n "${guest_pid}" ]]; then
    kill "${guest_pid}" 2>/dev/null || true
    wait "${guest_pid}" 2>/dev/null || true
  fi
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

SYSTEMCTL_ACTIVE_STATE=active SYSTEMCTL_MAIN_PID="${BASHPID}" \
  VIRTDEV_STOP_MONITOR_SOCK="${monitor_sock}" \
  PATH="${fixture_bin}:${PATH}" \
  "${repository}/libexec/virtdev/virtdev-stop-acpi" probe "${BASHPID}"
[[ ! -e "${capture}" ]]

sleep 30 &
guest_pid=$!
SYSTEMCTL_ACTIVE_STATE=deactivating SYSTEMCTL_MAIN_PID="${guest_pid}" \
  VIRTDEV_HOME="${test_tmp}/wrong-home" \
  VIRTDEV_STOP_MONITOR_SOCK="${monitor_sock}" \
  PATH="${fixture_bin}:${PATH}" \
  "${repository}/libexec/virtdev/virtdev-stop-acpi" probe "${guest_pid}" &
hook_pid=$!
for _ in {1..50}; do
  [[ -e "${capture}" ]] && break
  sleep 0.02
done
[[ -e "${capture}" ]]
sleep 0.2
kill -0 "${guest_pid}"
kill -0 "${hook_pid}"

kill "${guest_pid}"
wait "${guest_pid}" 2>/dev/null || true
guest_pid=''
wait "${hook_pid}"
hook_pid=''
wait "${listener_pid}"
listener_pid=''
[[ "$(< "${capture}")" == system_powerdown ]]

sleep 30 &
guest_pid=$!
SYSTEMCTL_ACTIVE_STATE=deactivating SYSTEMCTL_MAIN_PID="${guest_pid}" \
  VIRTDEV_STOP_MONITOR_SOCK="${test_tmp}/missing/monitor.sock" \
  PATH="${fixture_bin}:${PATH}" \
  "${repository}/libexec/virtdev/virtdev-stop-acpi" probe "${guest_pid}" &
hook_pid=$!
sleep 0.2
kill -0 "${guest_pid}"
kill -0 "${hook_pid}"
kill "${guest_pid}"
wait "${guest_pid}" 2>/dev/null || true
guest_pid=''
wait "${hook_pid}"
hook_pid=''

printf 'ok - private ACPI hook uses the bound monitor and waits for QEMU exit\n'
