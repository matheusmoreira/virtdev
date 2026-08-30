#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
qmp_pid_file="${test_tmp}/qmp-server.pid"
cleanup() {
  if [[ -s "${qmp_pid_file}" ]]; then
    qmp_pid="$(< "${qmp_pid_file}")"
    kill "${qmp_pid}" 2>/dev/null || true
    wait "${qmp_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

virtdev_home="${test_tmp}/virtdev"
system_directory="${virtdev_home}/system"
fixture_bin="${test_tmp}/bin"
config_home="${test_tmp}/config"
state_file="${test_tmp}/unit.state"
event_log="${test_tmp}/qmp-events"
boot_count_file="${test_tmp}/boot-count"
output="${test_tmp}/output"
hook_captures="${test_tmp}/hook-captures"

mkdir -p "${system_directory}" "${virtdev_home}/projects" \
  "${virtdev_home}/ssh" "${fixture_bin}" \
  "${config_home}/virtdev/maintenance"
for image in system.qcow2 home.qcow2 nvram; do
  : > "${system_directory}/${image}"
done
printf '0\n' > "${system_directory}/generation"
printf 'ssh-host-identity=1\n' > "${system_directory}/guest-contract"
printf 'test key\n' > "${virtdev_home}/ssh/id"
chmod 600 "${virtdev_home}/ssh/id"
: > "${test_tmp}/OVMF_CODE.fd"
printf 'inactive\n' > "${state_file}"
printf "printf 'frozen-inventory\\n'\n" \
  > "${config_home}/virtdev/maintenance/inventory"
mkdir -p -- "${hook_captures}"

cp "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
cp "${repository}/tests/fixtures/systemd-run-maintenance" \
  "${fixture_bin}/systemd-run"
cp "${repository}/tests/fixtures/ssh-maintenance" "${fixture_bin}/ssh"
cp "${repository}/tests/fixtures/ss-empty" "${fixture_bin}/ss"
cp "${repository}/tests/fixtures/qemu-img" "${fixture_bin}/qemu-img"
cp "${repository}/tests/fixtures/qmp-maintenance-server" \
  "${fixture_bin}/qmp-maintenance-server"
chmod +x "${fixture_bin}"/*

status=0
VIRTDEV_MAINTENANCE_HOOK_KILL_AFTER=61 \
  "${repository}/bin/virtdev-maintain" >"${output}" 2>&1 || status=$?
if (( status != 64 )) \
    || ! grep -Fq 'must be an integer from 1 through 60' "${output}"; then
  printf 'maintenance accepted an excessive hook termination grace\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - maintenance bounds hook termination grace\n'

status=0
PATH="${fixture_bin}:${PATH}" \
  HOME="${test_tmp}" \
  XDG_CONFIG_HOME="${config_home}" \
  VIRTDEV_HOME="${virtdev_home}" \
  VIRTDEV_CACHE="${test_tmp}/cache" \
  VIRTDEV_SSH_KEY="${virtdev_home}/ssh/id" \
  VIRTDEV_WAIT_TIMEOUT=5 \
  VIRTDEV_STOP_TIMEOUT=5 \
  OVMF_CODE="${test_tmp}/OVMF_CODE.fd" \
  SYSTEMCTL_STATE_FILE="${state_file}" \
  MAINTENANCE_RUNTIME_DIRECTORY="${virtdev_home}/projects/maintenance" \
  MAINTENANCE_SSH_MODE=ready \
  MAINTENANCE_QMP_HANDLER="${fixture_bin}/qmp-maintenance-server" \
  MAINTENANCE_QMP_SERVER_PID_FILE="${qmp_pid_file}" \
  MAINTENANCE_QMP_EVENT_LOG="${event_log}" \
  MAINTENANCE_BOOT_COUNT_FILE="${boot_count_file}" \
  MAINTENANCE_EXECUTE_HOOKS=1 \
  MAINTENANCE_HOOK_CAPTURE_DIRECTORY="${hook_captures}" \
  MAINTENANCE_HOOK_REPLACE_SOURCE="${config_home}/virtdev/maintenance/inventory" \
  QEMU_OTHER_STATUS=0 \
  NO_COLOR=1 \
  "${repository}/bin/virtdev-maintain" \
    --yes --unfiltered --no-provision >"${output}" 2>&1 || status=$?

if (( status != 0 )); then
  printf 'expected attested two-boot maintenance success, got %d\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ "$(< "${system_directory}/generation")" != 1 ]]; then
  printf 'successful attested maintenance did not publish generation 1\n' >&2
  exit 1
fi
if [[ -e "${virtdev_home}/maintenance" ]]; then
  printf 'successful reseal left the previous base cleanup tree behind\n' >&2
  exit 1
fi

mapfile -t qmp_events < "${event_log}"
expected_events=(query-status quit query-status quit)
if [[ "${qmp_events[*]}" != "${expected_events[*]}" ]]; then
  printf 'expected independent Boot 1/Boot 2 QMP proofs, got: %s\n' \
    "${qmp_events[*]}" >&2
  exit 1
fi
if ! grep -Fq \
    'Guest-originated shutdown and QEMU termination confirmed.' "${output}"; then
  printf 'successful path did not report the two-part shutdown proof\n' >&2
  cat "${output}" >&2
  exit 1
fi
if [[ ! -f "${hook_captures}/1" || ! -f "${hook_captures}/2" ]] \
    || ! cmp -s -- "${hook_captures}/1" "${hook_captures}/2"; then
  printf 'maintenance did not reuse the exact frozen inventory hook\n' >&2
  exit 1
fi
if ! grep -Fq 'replacement-inventory' \
    "${config_home}/virtdev/maintenance/inventory"; then
  printf 'fixture did not replace the mutable inventory source\n' >&2
  exit 1
fi
if find "${virtdev_home}/transactions" -mindepth 1 -maxdepth 1 \
    -name 'maintain.*' -print -quit | grep -q .; then
  printf 'successful maintenance stranded its hook transaction\n' >&2
  exit 1
fi

printf 'ok - both maintenance boots require independent QMP shutdown proof\n'
printf 'ok - maintenance reuses one frozen hook and cleans its transaction\n'

run_hook_case() {
  local -r case_output="${1}" case_captures="${2}"
  shift 2
  hook_case_status=0
  printf 'inactive\n' > "${state_file}"
  printf '0\n' > "${boot_count_file}"
  : > "${event_log}"
  : > "${qmp_pid_file}"
  mkdir -p -- "${case_captures}"
  env \
    PATH="${fixture_bin}:${PATH}" \
    HOME="${test_tmp}" \
    XDG_CONFIG_HOME="${config_home}" \
    VIRTDEV_HOME="${virtdev_home}" \
    VIRTDEV_CACHE="${test_tmp}/cache" \
    VIRTDEV_SSH_KEY="${virtdev_home}/ssh/id" \
    VIRTDEV_WAIT_TIMEOUT=5 \
    VIRTDEV_STOP_TIMEOUT=5 \
    OVMF_CODE="${test_tmp}/OVMF_CODE.fd" \
    SYSTEMCTL_STATE_FILE="${state_file}" \
    MAINTENANCE_RUNTIME_DIRECTORY="${virtdev_home}/projects/maintenance" \
    MAINTENANCE_SSH_MODE=ready \
    MAINTENANCE_QMP_HANDLER="${fixture_bin}/qmp-maintenance-server" \
    MAINTENANCE_QMP_SERVER_PID_FILE="${qmp_pid_file}" \
    MAINTENANCE_QMP_EVENT_LOG="${event_log}" \
    MAINTENANCE_BOOT_COUNT_FILE="${boot_count_file}" \
    MAINTENANCE_EXECUTE_HOOKS=1 \
    MAINTENANCE_HOOK_CAPTURE_DIRECTORY="${case_captures}" \
    QEMU_OTHER_STATUS=0 \
    NO_COLOR=1 \
    "$@" \
    "${repository}/bin/virtdev-maintain" \
      --yes --unfiltered --no-inventory >"${case_output}" 2>&1 \
    || hook_case_status=$?
}

provision_hook="${config_home}/virtdev/maintenance/provision"
printf "/usr/bin/head -c 65 /dev/zero | /usr/bin/tr '\\0' x\n" \
  > "${provision_hook}"
overflow_output="${test_tmp}/overflow-output"
run_hook_case "${overflow_output}" "${test_tmp}/overflow-hooks" \
  VIRTDEV_MAINTENANCE_HOOK_OUTPUT_MAX_BYTES=64
if (( hook_case_status != 0 )) \
    || ! grep -Fq 'stdout exceeded 64 bytes' "${overflow_output}"; then
  printf 'bounded provision stdout did not fail non-fatally\n' >&2
  cat "${overflow_output}" >&2
  exit 1
fi

printf 'sleep 10\n' > "${provision_hook}"
timeout_output="${test_tmp}/timeout-output"
run_hook_case "${timeout_output}" "${test_tmp}/timeout-hooks" \
  VIRTDEV_MAINTENANCE_HOOK_TIMEOUT=1 \
  VIRTDEV_MAINTENANCE_HOOK_KILL_AFTER=1
if (( hook_case_status != 0 )) \
    || ! grep -Fq 'execution exceeded 1 seconds' "${timeout_output}"; then
  printf 'timed provision hook did not fail non-fatally\n' >&2
  cat "${timeout_output}" >&2
  exit 1
fi
if find "${virtdev_home}/transactions" -mindepth 1 -maxdepth 1 \
    -name 'maintain.*' -print -quit | grep -q .; then
  printf 'bounded hook failures stranded a transaction\n' >&2
  exit 1
fi

printf 'ok - maintenance hook stdout and execution time are bounded\n'

oversize_home="${test_tmp}/oversize-virtdev"
oversize_system="${oversize_home}/system"
oversize_state="${test_tmp}/oversize-unit.state"
oversize_output="${test_tmp}/oversize-output"
oversize_submission="${test_tmp}/oversize-submission"
mkdir -p "${oversize_system}" "${oversize_home}/projects" \
  "${oversize_home}/ssh"
for image in system.qcow2 home.qcow2 nvram; do
  : > "${oversize_system}/${image}"
done
printf '0\n' > "${oversize_system}/generation"
printf 'ssh-host-identity=1\n' > "${oversize_system}/guest-contract"
printf 'test key\n' > "${oversize_home}/ssh/id"
chmod 600 "${oversize_home}/ssh/id"
printf 'inactive\n' > "${oversize_state}"
truncate -s 1048577 -- "${provision_hook}"
status=0
PATH="${fixture_bin}:${PATH}" \
  HOME="${test_tmp}" \
  XDG_CONFIG_HOME="${config_home}" \
  VIRTDEV_HOME="${oversize_home}" \
  VIRTDEV_CACHE="${test_tmp}/oversize-cache" \
  VIRTDEV_SSH_KEY="${oversize_home}/ssh/id" \
  OVMF_CODE="${test_tmp}/OVMF_CODE.fd" \
  SYSTEMCTL_STATE_FILE="${oversize_state}" \
  SYSTEMD_RUN_MARKER="${oversize_submission}" \
  NO_COLOR=1 \
  "${repository}/bin/virtdev-maintain" \
    --yes --unfiltered --no-inventory >"${oversize_output}" 2>&1 || status=$?
if (( status != 35 )) || [[ -e "${oversize_submission}" ]] \
    || [[ -e "${oversize_home}/maintenance" ]] \
    || find "${oversize_home}/transactions" -mindepth 1 -maxdepth 1 \
      -name 'maintain.*' -print -quit | grep -q .; then
  printf 'oversized hook did not fail cleanly before staging/submission\n' >&2
  cat "${oversize_output}" >&2
  exit 1
fi

printf 'ok - oversized maintenance hooks fail before mutation\n'

interrupt_marker="${test_tmp}/interrupt-hook-started"
interrupt_output="${test_tmp}/interrupt-output"
interrupt_captures="${test_tmp}/interrupt-hooks"
printf '%s\n' ": > \"${interrupt_marker}\"" 'sleep 10' > "${provision_hook}"
printf 'inactive\n' > "${state_file}"
printf '0\n' > "${boot_count_file}"
: > "${event_log}"
: > "${qmp_pid_file}"
mkdir -p -- "${interrupt_captures}"
env \
  PATH="${fixture_bin}:${PATH}" \
  HOME="${test_tmp}" \
  XDG_CONFIG_HOME="${config_home}" \
  VIRTDEV_HOME="${virtdev_home}" \
  VIRTDEV_CACHE="${test_tmp}/cache" \
  VIRTDEV_SSH_KEY="${virtdev_home}/ssh/id" \
  VIRTDEV_WAIT_TIMEOUT=5 \
  VIRTDEV_STOP_TIMEOUT=5 \
  VIRTDEV_MAINTENANCE_HOOK_TIMEOUT=2 \
  VIRTDEV_MAINTENANCE_HOOK_KILL_AFTER=1 \
  OVMF_CODE="${test_tmp}/OVMF_CODE.fd" \
  SYSTEMCTL_STATE_FILE="${state_file}" \
  MAINTENANCE_RUNTIME_DIRECTORY="${virtdev_home}/projects/maintenance" \
  MAINTENANCE_SSH_MODE=ready \
  MAINTENANCE_QMP_HANDLER="${fixture_bin}/qmp-maintenance-server" \
  MAINTENANCE_QMP_SERVER_PID_FILE="${qmp_pid_file}" \
  MAINTENANCE_QMP_EVENT_LOG="${event_log}" \
  MAINTENANCE_BOOT_COUNT_FILE="${boot_count_file}" \
  MAINTENANCE_EXECUTE_HOOKS=1 \
  MAINTENANCE_HOOK_CAPTURE_DIRECTORY="${interrupt_captures}" \
  QEMU_OTHER_STATUS=0 \
  NO_COLOR=1 \
  "${repository}/bin/virtdev-maintain" \
    --yes --unfiltered --no-inventory >"${interrupt_output}" 2>&1 &
maintain_pid=$!
for (( attempt = 0; attempt < 200; attempt++ )); do
  [[ ! -e "${interrupt_marker}" ]] || break
  sleep 0.01
done
if [[ ! -e "${interrupt_marker}" ]]; then
  printf 'interrupt fixture did not reach the provision hook\n' >&2
  kill "${maintain_pid}" 2>/dev/null || true
  wait "${maintain_pid}" 2>/dev/null || true
  cat "${interrupt_output}" >&2
  exit 1
fi
kill -TERM "${maintain_pid}"
interrupt_status=0
wait "${maintain_pid}" || interrupt_status=$?
if (( interrupt_status != 143 )); then
  printf 'expected interrupted maintenance status 143, got %d\n' \
    "${interrupt_status}" >&2
  cat "${interrupt_output}" >&2
  exit 1
fi
if find "${virtdev_home}/transactions" -mindepth 1 -maxdepth 1 \
    -name 'maintain.*' -print -quit | grep -q .; then
  printf 'interrupted maintenance stranded its hook transaction\n' >&2
  exit 1
fi

printf 'ok - maintenance interruption cleans bounded hook captures\n'

# Boot 2 exit zero must not reuse Boot 1's proof.
reject_home="${test_tmp}/reject-virtdev"
reject_system="${reject_home}/system"
reject_state="${test_tmp}/reject-unit.state"
reject_events="${test_tmp}/reject-qmp-events"
reject_boot_count="${test_tmp}/reject-boot-count"
reject_output="${test_tmp}/reject-output"
mkdir -p "${reject_system}" "${reject_home}/projects" "${reject_home}/ssh"
for image in system.qcow2 home.qcow2 nvram; do
  : > "${reject_system}/${image}"
done
printf '0\n' > "${reject_system}/generation"
printf 'ssh-host-identity=1\n' > "${reject_system}/guest-contract"
printf 'test key\n' > "${reject_home}/ssh/id"
chmod 600 "${reject_home}/ssh/id"
printf 'inactive\n' > "${reject_state}"

status=0
PATH="${fixture_bin}:${PATH}" \
  HOME="${test_tmp}" \
  XDG_CONFIG_HOME="${config_home}" \
  VIRTDEV_HOME="${reject_home}" \
  VIRTDEV_CACHE="${test_tmp}/reject-cache" \
  VIRTDEV_SSH_KEY="${reject_home}/ssh/id" \
  VIRTDEV_WAIT_TIMEOUT=5 \
  VIRTDEV_STOP_TIMEOUT=5 \
  OVMF_CODE="${test_tmp}/OVMF_CODE.fd" \
  SYSTEMCTL_STATE_FILE="${reject_state}" \
  MAINTENANCE_RUNTIME_DIRECTORY="${reject_home}/projects/maintenance" \
  MAINTENANCE_SSH_MODE=ready-boot2-exit \
  MAINTENANCE_QMP_HANDLER="${fixture_bin}/qmp-maintenance-server" \
  MAINTENANCE_QMP_SERVER_PID_FILE="${qmp_pid_file}" \
  MAINTENANCE_QMP_EVENT_LOG="${reject_events}" \
  MAINTENANCE_BOOT_COUNT_FILE="${reject_boot_count}" \
  QEMU_OTHER_STATUS=0 \
  NO_COLOR=1 \
  "${repository}/bin/virtdev-maintain" \
    --yes --unfiltered --no-provision >"${reject_output}" 2>&1 || status=$?

if (( status != 24 )); then
  printf 'expected unattested Boot 2 refusal 24, got %d\n' "${status}" >&2
  cat "${reject_output}" >&2
  exit 1
fi
if [[ "$(< "${reject_system}/generation")" != 0 ]]; then
  printf 'unattested Boot 2 changed the sealed base generation\n' >&2
  exit 1
fi
if [[ ! -d "${reject_home}/maintenance" ]]; then
  printf 'unattested Boot 2 did not preserve staging\n' >&2
  exit 1
fi
mapfile -t reject_qmp_events < "${reject_events}"
expected_reject_events=(query-status quit)
if [[ "${reject_qmp_events[*]}" != "${expected_reject_events[*]}" ]]; then
  printf 'Boot 2 reused or fabricated QMP proof events: %s\n' \
    "${reject_qmp_events[*]}" >&2
  exit 1
fi
if ! grep -Fq \
    'Inventory boot QEMU exited with status 0, but QMP did not prove guest shutdown.' \
    "${reject_output}"; then
  printf 'unattested Boot 2 did not reach the proof-specific refusal\n' >&2
  cat "${reject_output}" >&2
  exit 1
fi

if grep -Fq 'will be cleaned up on next virtdev-maintain run' \
    "${repository}/bin/virtdev-maintain" \
    || grep -Fq "rm -rf '\${maintenance_directory}'" \
      "${repository}/bin/virtdev-maintain"; then
  printf 'post-reseal cleanup guidance promises an unsupported retry\n' >&2
  exit 1
fi
if ! grep -Fq 'mount_remove_tree' \
    "${repository}/bin/virtdev-maintain"; then
  printf 'maintenance has no filesystem-bounded removal path\n' >&2
  exit 1
fi

printf 'ok - Boot 2 cannot reuse Boot 1 shutdown proof\n'
printf 'ok - post-reseal cleanup guidance requires manual recovery\n'
