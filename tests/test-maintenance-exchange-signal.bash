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

test_root="${test_tmp}/root"
virtdev_home="${test_tmp}/virtdev"
system_directory="${virtdev_home}/system"
maintenance_directory="${virtdev_home}/maintenance"
fixture_bin="${test_tmp}/bin"
state_file="${test_tmp}/unit.state"
event_log="${test_tmp}/qmp-events"
exchange_marker="${test_tmp}/exchange.complete"
output="${test_tmp}/output"

mkdir -p "${test_root}/bin" "${test_root}/libexec" \
  "${system_directory}" "${virtdev_home}/projects" \
  "${virtdev_home}/ssh" "${fixture_bin}"
cp -a "${repository}/lib" "${test_root}/lib"
cp -a "${repository}/libexec/virtdev" "${test_root}/libexec/virtdev"
cp "${repository}/bin/virtdev-maintain" "${test_root}/bin/virtdev-maintain"
cp "${repository}/tests/fixtures/exchange-signal-after" \
  "${test_root}/libexec/virtdev/virtdev-exchange"

for image in system.qcow2 home.qcow2 nvram; do
  : > "${system_directory}/${image}"
done
printf '0\n' > "${system_directory}/generation"
printf 'ssh-host-identity=1\n' > "${system_directory}/guest-contract"
printf 'test key\n' > "${virtdev_home}/ssh/id"
chmod 600 "${virtdev_home}/ssh/id"
: > "${test_tmp}/OVMF_CODE.fd"
printf 'inactive\n' > "${state_file}"

for fixture in systemctl systemd-run-maintenance ssh-maintenance ss-empty \
    qemu-img qmp-maintenance-server; do
  destination="${fixture}"
  case "${fixture}" in
    systemd-run-maintenance) destination=systemd-run ;;
    ssh-maintenance) destination=ssh ;;
  esac
  cp "${repository}/tests/fixtures/${fixture}" "${fixture_bin}/${destination}"
done
chmod +x "${fixture_bin}"/*

status=0
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/config" \
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
MAINTENANCE_REAL_EXCHANGE="${repository}/libexec/virtdev/virtdev-exchange" \
MAINTENANCE_EXCHANGE_MARKER="${exchange_marker}" \
QEMU_OTHER_STATUS=0 \
NO_COLOR=1 \
  "${test_root}/bin/virtdev-maintain" \
    --yes --unfiltered --no-provision --no-inventory \
    >"${output}" 2>&1 || status=$?

if (( status != 27 )) || [[ ! -e "${exchange_marker}" ]]; then
  printf 'post-exchange signal was not classified indeterminate (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ "$(< "${system_directory}/generation")" != 1 \
      || "$(< "${maintenance_directory}/generation")" != 0 ]]; then
  printf 'post-exchange signal lost one side of the committed namespace swap\n' >&2
  exit 1
fi
if ! grep -Fq 'failure occurred after the base namespace exchange' \
    "${output}"; then
  printf 'post-exchange signal omitted the indeterminate recovery warning\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - post-exchange signals preserve and report the commit boundary\n'
