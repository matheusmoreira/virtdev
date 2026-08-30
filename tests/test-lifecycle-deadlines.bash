#!/usr/bin/env bash
# shellcheck disable=SC2154  # imported lifecycle constants

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
mkdir "${fixture_bin}"
ln -s "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
export PATH="${fixture_bin}:${PATH}"

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import lifecycle

runtime_directory="${test_tmp}/runtime"
mkdir "${runtime_directory}"
status=0
started="${BASH_MONOSECONDS}"
SYSTEMCTL_ACTIVE_STATE=active SYSTEMCTL_SHOW_DELAY=5 \
  lifecycle_wait_active virtdev-probe "${runtime_directory}" 1 \
  || status=$?
elapsed=$(( BASH_MONOSECONDS - started ))
if (( status != lifecycle_activation_timeout || elapsed > 3 )) \
    || [[ "${VIRTDEV_LIFECYCLE_ACTIVE_STATE}" != timeout ]]; then
  printf 'hanging activation probe escaped its deadline (status %d, %ds)\n' \
    "${status}" "${elapsed}" >&2
  exit 1
fi

status=0
started="${BASH_MONOSECONDS}"
SYSTEMCTL_ACTIVE_STATE=active SYSTEMCTL_STOP_DELAY=5 \
  lifecycle_stop_and_confirm virtdev-probe 1 || status=$?
elapsed=$(( BASH_MONOSECONDS - started ))
if (( status != lifecycle_stop_timeout || elapsed > 3 )) \
    || [[ "${VIRTDEV_LIFECYCLE_STOP_STATE}" != timeout ]]; then
  printf 'hanging stop submission escaped its deadline (status %d, %ds)\n' \
    "${status}" "${elapsed}" >&2
  exit 1
fi

stall_bin="${test_tmp}/stall-bin"
stop_home="${test_tmp}/stop-home"
stop_runtime="${stop_home}/projects/probe"
monitor_sock="${stop_runtime}/monitor.sock"
state_file="${test_tmp}/state"
stop_file="${test_tmp}/stop"
socat_marker="${test_tmp}/socat"
mkdir "${stall_bin}"
mkdir -p "${stop_runtime}"
ln -s "${repository}/tests/fixtures/systemctl" "${stall_bin}/systemctl"
ln -s "${repository}/tests/fixtures/socat-stall" "${stall_bin}/socat"
printf 'active\n' > "${state_file}"
/usr/bin/socat UNIX-LISTEN:"${monitor_sock}" EXEC:/bin/cat 2>/dev/null &
listener_pid=$!
for _ in {1..50}; do
  [[ -S "${monitor_sock}" ]] && break
  sleep 0.02
done
[[ -S "${monitor_sock}" ]]

status=0
started="${BASH_MONOSECONDS}"
PATH="${stall_bin}:/usr/bin" \
VIRTDEV_HOME="${stop_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/locks" \
VIRTDEV_STOP_TIMEOUT=1 \
SYSTEMCTL_STATE_FILE="${state_file}" \
SYSTEMCTL_STOP_FILE="${stop_file}" \
SOCAT_STALL_MARKER="${socat_marker}" \
SOCAT_STALL_DELAY=5 \
NO_COLOR=1 \
  timeout 6 "${repository}/bin/virtdev-stop" -- probe \
  > "${test_tmp}/stop.output" 2>&1 || status=$?
elapsed=$(( BASH_MONOSECONDS - started ))
if (( status != 0 || elapsed > 5 )) || [[ ! -e "${socat_marker}" \
      || ! -e "${stop_file}" || "$(< "${state_file}")" != inactive ]]; then
  printf 'hanging ACPI send did not reach bounded SIGTERM fallback (status %d, %ds)\n' \
    "${status}" "${elapsed}" >&2
  cat "${test_tmp}/stop.output" >&2
  exit 1
fi

printf 'ok - lifecycle probes, stop submission, and ACPI send are deadline-bounded\n'
