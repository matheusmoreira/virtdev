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

mkdir -p "${system_directory}" "${virtdev_home}/projects" \
  "${virtdev_home}/ssh" "${fixture_bin}" \
  "${config_home}/virtdev/maintenance"
for image in system.qcow2 home.qcow2 nvram; do
  : > "${system_directory}/${image}"
done
printf '0\n' > "${system_directory}/generation"
printf 'test key\n' > "${virtdev_home}/ssh/id"
chmod 600 "${virtdev_home}/ssh/id"
: > "${test_tmp}/OVMF_CODE.fd"
printf 'inactive\n' > "${state_file}"
printf '# inventory fixture\n' > "${config_home}/virtdev/maintenance/inventory"

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

printf 'ok - both maintenance boots require independent QMP shutdown proof\n'

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
    || ! grep -Fq \
      'remove it manually before the next virtdev-maintain run' \
      "${repository}/bin/virtdev-maintain"; then
  printf 'post-reseal cleanup guidance promises an unsupported retry\n' >&2
  exit 1
fi

printf 'ok - Boot 2 cannot reuse Boot 1 shutdown proof\n'
printf 'ok - post-reseal cleanup guidance requires manual recovery\n'
