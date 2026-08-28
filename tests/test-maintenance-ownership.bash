#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
interrupt_pid=""
cleanup() {
  if [[ -n "${interrupt_pid}" ]]; then
    if kill -0 "${interrupt_pid}" 2>/dev/null; then
      kill -TERM "${interrupt_pid}" 2>/dev/null || true
    fi
    for (( attempt = 0; attempt < 20; attempt++ )); do
      kill -0 "${interrupt_pid}" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "${interrupt_pid}" 2>/dev/null; then
      kill -KILL "${interrupt_pid}" 2>/dev/null || true
    fi
    wait "${interrupt_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

virtdev_home="${test_tmp}/virtdev"
system_directory="${virtdev_home}/system"
maintenance_directory="${virtdev_home}/maintenance"
output="${test_tmp}/output"

mkdir -p "${system_directory}" "${maintenance_directory}"
for image in system.qcow2 home.qcow2 nvram; do
  : > "${system_directory}/${image}"
done
printf '0\n' > "${system_directory}/generation"
printf 'preserve interrupted staging\n' > "${maintenance_directory}/sentinel"

run_maintain() {
  local -r active_state="${1}" unreachable="${2}"
  PATH="${repository}/tests/fixtures:${PATH}" \
    HOME="${test_tmp}" \
    XDG_CONFIG_HOME="${test_tmp}/config" \
    VIRTDEV_HOME="${virtdev_home}" \
    VIRTDEV_CACHE="${test_tmp}/cache" \
    SYSTEMCTL_ACTIVE_STATE="${active_state}" \
    SYSTEMCTL_UNREACHABLE="${unreachable}" \
    NO_COLOR=1 \
    "${repository}/bin/virtdev-maintain" >"${output}" 2>&1
}

status=0
run_maintain active 0 || status=$?
if (( status != 8 )); then
  printf 'expected live maintenance unit exit 8, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ ! -f "${maintenance_directory}/sentinel" ]]; then
  printf 'live maintenance staging was removed\n' >&2
  exit 1
fi
if ! grep -Fq 'Do not remove its staging directory while QEMU may be writing it.' \
    "${output}"; then
  printf 'live-unit diagnostic did not prohibit staging deletion\n' >&2
  cat "${output}" >&2
  exit 1
fi

status=0
run_maintain inactive 1 || status=$?
if (( status != 29 )); then
  printf 'expected indeterminate maintenance unit exit 29, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ ! -f "${maintenance_directory}/sentinel" ]]; then
  printf 'indeterminate maintenance staging was removed\n' >&2
  exit 1
fi
if ! grep -Fq "Do not remove '${maintenance_directory}'." "${output}"; then
  printf 'indeterminate-unit diagnostic did not prohibit staging deletion\n' >&2
  cat "${output}" >&2
  exit 1
fi

launch_bin="${test_tmp}/launch-bin"
mkdir "${launch_bin}"
cp "${repository}/tests/fixtures/systemctl" "${launch_bin}/systemctl"
cp "${repository}/tests/fixtures/systemd-run-maintenance" "${launch_bin}/systemd-run"
cp "${repository}/tests/fixtures/ssh-maintenance" "${launch_bin}/ssh"
cp "${repository}/tests/fixtures/ss-empty" "${launch_bin}/ss"
chmod +x "${launch_bin}"/*

prepare_launch_home() {
  local -r launch_home="${1}"
  mkdir -p "${launch_home}/system" "${launch_home}/projects" \
    "${launch_home}/ssh"
  for image in system.qcow2 home.qcow2 nvram; do
    : > "${launch_home}/system/${image}"
  done
  printf '0\n' > "${launch_home}/system/generation"
  printf 'test key\n' > "${launch_home}/ssh/id"
  chmod 600 "${launch_home}/ssh/id"
  : > "${launch_home}/OVMF_CODE.fd"
  printf 'inactive\n' > "${launch_home}/unit.state"
}

run_launch() {
  local -r launch_home="${1}" ssh_mode="${2}" cache="${3}" \
    malformed_control="${4:-0}" wait_timeout="${5:-1}" argv_file="${6:-}"
  PATH="${launch_bin}:${PATH}" \
    HOME="${test_tmp}" \
    XDG_CONFIG_HOME="${test_tmp}/config" \
    VIRTDEV_HOME="${launch_home}" \
    VIRTDEV_CACHE="${cache}" \
    VIRTDEV_SSH_KEY="${launch_home}/ssh/id" \
    VIRTDEV_WAIT_TIMEOUT="${wait_timeout}" \
    VIRTDEV_STOP_TIMEOUT=1 \
    OVMF_CODE="${launch_home}/OVMF_CODE.fd" \
    SYSTEMCTL_STATE_FILE="${launch_home}/unit.state" \
    SYSTEMCTL_STOP_FILE="${launch_home}/stop.called" \
    SYSTEMCTL_UNREACHABLE_FILE="${launch_home}/manager.lost" \
    SYSTEMD_RUN_MARKER="${launch_home}/systemd-run.called" \
    SYSTEMD_RUN_ARGV_FILE="${argv_file}" \
    MAINTENANCE_NO_SHUTDOWN_MARKER="${launch_home}/no-shutdown.called" \
    MAINTENANCE_PANIC_PAUSE_MARKER="${launch_home}/panic-pause.called" \
    MAINTENANCE_RUNTIME_DIRECTORY="${launch_home}/projects/maintenance" \
    MAINTENANCE_SSH_MODE="${ssh_mode}" \
    MAINTENANCE_MALFORMED_CONTROL="${malformed_control}" \
    NO_COLOR=1 \
    "${repository}/bin/virtdev-maintain" \
      --unfiltered --no-provision --no-inventory >"${output}" 2>&1
}

prerequisite_home="${test_tmp}/prerequisite-home"
prepare_launch_home "${prerequisite_home}"
: > "${prerequisite_home}/blocked-cache"
status=0
run_launch "${prerequisite_home}" failure \
  "${prerequisite_home}/blocked-cache" || status=$?
if (( status != 20 )); then
  printf 'expected launch-prerequisite exit 20, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ -e "${prerequisite_home}/systemd-run.called" ]]; then
  printf 'maintenance submitted a unit after a failed prerequisite\n' >&2
  exit 1
fi
if ! grep -Fq 'no VM was submitted' "${output}"; then
  printf 'prerequisite failure was mislabeled as a systemd-run failure\n' >&2
  cat "${output}" >&2
  exit 1
fi

terminal_home="${test_tmp}/terminal-home"
prepare_launch_home "${terminal_home}"
terminal_cache="${terminal_home}/cache,a,,b=c d\\e"
terminal_argv_file="${terminal_home}/systemd-run.argv"
status=0
run_launch "${terminal_home}" failure \
  "${terminal_cache}" 0 1 "${terminal_argv_file}" || status=$?
if (( status != 10 )); then
  printf 'expected SSH-timeout exit 10 after terminal recovery, got %d\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ ! -e "${terminal_home}/systemd-run.called" \
      || ! -e "${terminal_home}/stop.called" ]]; then
  printf 'submitted maintenance unit was not driven through bounded stop\n' >&2
  exit 1
fi
if [[ ! -e "${terminal_home}/no-shutdown.called" ]]; then
  printf 'maintenance QEMU was not launched with -no-shutdown\n' >&2
  exit 1
fi
if [[ ! -e "${terminal_home}/panic-pause.called" ]]; then
  printf 'maintenance QEMU did not prevent guest panic from proving shutdown\n' >&2
  exit 1
fi
mapfile -d '' -t terminal_argv < "${terminal_argv_file}"
expected_virtfs="local,path=${terminal_home}/cache,,a,,,,b=c d\\e/pacman,mount_tag=pacman_cache,security_model=mapped-xattr"
virtfs_found=0
for argument in "${terminal_argv[@]}"; do
  if [[ "${argument}" == "${expected_virtfs}" ]]; then
    virtfs_found=1
    break
  fi
done
if (( ! virtfs_found )); then
  printf 'maintenance cache path was not comma-encoded in the exact QEMU argv\n' >&2
  printf 'expected: %q\n' "${expected_virtfs}" >&2
  printf 'argv: ' >&2
  printf '%q ' "${terminal_argv[@]}" >&2
  printf '\n' >&2
  exit 1
fi
for control in monitor.sock console.sock network.sock passt.sock qmp.sock port; do
  if [[ -e "${terminal_home}/projects/maintenance/${control}" ]]; then
    printf 'terminal maintenance control survived cleanup: %s\n' \
      "${control}" >&2
    exit 1
  fi
done
if [[ ! -d "${terminal_home}/maintenance" ]]; then
  printf 'failed maintenance session did not preserve staging\n' >&2
  exit 1
fi

malformed_home="${test_tmp}/malformed-home"
prepare_launch_home "${malformed_home}"
status=0
run_launch "${malformed_home}" failure \
  "${malformed_home}/cache" 1 || status=$?
if (( status != 30 )); then
  printf 'expected malformed-runtime exit 30, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ ! -f "${malformed_home}/projects/maintenance/monitor.sock/sentinel" ]]; then
  printf 'malformed runtime control was recursively removed\n' >&2
  exit 1
fi
if ! grep -Fq 'unit is terminal, but one or more runtime controls' "${output}"; then
  printf 'malformed runtime cleanup failure was suppressed\n' >&2
  cat "${output}" >&2
  exit 1
fi

unknown_home="${test_tmp}/unknown-home"
prepare_launch_home "${unknown_home}"
status=0
run_launch "${unknown_home}" manager-loss \
  "${unknown_home}/cache" 0 5 || status=$?
if (( status != 29 )); then
  printf 'expected post-submission manager-loss exit 29, got %d\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ ! -e "${unknown_home}/systemd-run.called" \
      || ! -e "${unknown_home}/stop.called" ]]; then
  printf 'manager-loss path did not attempt ownership recovery\n' >&2
  exit 1
fi
for control in monitor.sock console.sock network.sock passt.sock qmp.sock; do
  if [[ ! -e "${unknown_home}/projects/maintenance/${control}" ]]; then
    printf 'indeterminate unit control was removed without terminal proof: %s\n' \
      "${control}" >&2
    exit 1
  fi
done
if [[ ! -d "${unknown_home}/maintenance" ]]; then
  printf 'indeterminate maintenance session did not preserve staging\n' >&2
  exit 1
fi

direct_exit_home="${test_tmp}/direct-exit-home"
prepare_launch_home "${direct_exit_home}"
status=0
run_launch "${direct_exit_home}" ready-exit \
  "${direct_exit_home}/cache" 0 5 || status=$?
if (( status != 31 )); then
  printf 'expected unattested zero-exit refusal 31, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if ! grep -Fq 'QEMU exited with status 0, but guest shutdown was not proven' \
    "${output}"; then
  printf 'zero QEMU exit was not diagnosed as missing guest-shutdown proof\n' >&2
  cat "${output}" >&2
  exit 1
fi
if [[ ! -d "${direct_exit_home}/maintenance" ]]; then
  printf 'unattested zero exit did not preserve maintenance staging\n' >&2
  exit 1
fi

interrupt_home="${test_tmp}/interrupt-home"
interrupt_output="${test_tmp}/interrupt-output"
prepare_launch_home "${interrupt_home}"
: > "${interrupt_output}"
env --default-signal=INT \
  PATH="${launch_bin}:${PATH}" \
  HOME="${test_tmp}" \
  XDG_CONFIG_HOME="${test_tmp}/config" \
  VIRTDEV_HOME="${interrupt_home}" \
  VIRTDEV_CACHE="${interrupt_home}/cache" \
  VIRTDEV_SSH_KEY="${interrupt_home}/ssh/id" \
  VIRTDEV_WAIT_TIMEOUT=5 \
  VIRTDEV_STOP_TIMEOUT=1 \
  OVMF_CODE="${interrupt_home}/OVMF_CODE.fd" \
  SYSTEMCTL_STATE_FILE="${interrupt_home}/unit.state" \
  SYSTEMCTL_STOP_FILE="${interrupt_home}/stop.called" \
  SYSTEMD_RUN_MARKER="${interrupt_home}/systemd-run.called" \
  MAINTENANCE_RUNTIME_DIRECTORY="${interrupt_home}/projects/maintenance" \
  MAINTENANCE_SSH_MODE=ready \
  NO_COLOR=1 \
  "${repository}/bin/virtdev-maintain" \
    --unfiltered --no-provision --no-inventory >"${interrupt_output}" 2>&1 &
interrupt_pid=$!

interrupt_waiting=0
for (( attempt = 0; attempt < 100; attempt++ )); do
  if grep -Fq 'To abort and preserve staging, press Ctrl-C' \
      "${interrupt_output}" 2>/dev/null; then
    interrupt_waiting=1
    break
  fi
  kill -0 "${interrupt_pid}" 2>/dev/null || break
  sleep 0.05
done
if (( ! interrupt_waiting )); then
  printf 'maintenance did not reach its interruptible QMP wait\n' >&2
  cat "${interrupt_output}" >&2
  exit 1
fi

interrupt_acknowledged=0
for (( delivery = 0; delivery < 3; delivery++ )); do
  if ! kill -INT "${interrupt_pid}" 2>/dev/null; then
    if ! kill -0 "${interrupt_pid}" 2>/dev/null; then
      interrupt_acknowledged=1
      break
    fi
    printf 'could not deliver Ctrl-C to maintenance fixture\n' >&2
    exit 1
  fi
  for (( poll = 0; poll < 40; poll++ )); do
    if [[ -e "${interrupt_home}/stop.called" ]] \
        || ! kill -0 "${interrupt_pid}" 2>/dev/null; then
      interrupt_acknowledged=1
      break 2
    fi
    sleep 0.05
  done
done
if (( ! interrupt_acknowledged )); then
  printf 'maintenance did not acknowledge Ctrl-C within the test bound\n' >&2
  cat "${interrupt_output}" >&2
  exit 1
fi

status=0
wait "${interrupt_pid}" || status=$?
interrupt_pid=""
if (( status != 130 )); then
  printf 'expected foreground Ctrl-C exit 130, got %d\n' "${status}" >&2
  cat "${interrupt_output}" >&2
  exit 1
fi
if [[ ! -e "${interrupt_home}/stop.called" ]]; then
  printf 'Ctrl-C did not drive the owned unit through bounded stop\n' >&2
  exit 1
fi
if [[ "$(< "${interrupt_home}/system/generation")" != 0 ]]; then
  printf 'Ctrl-C changed the sealed base generation\n' >&2
  exit 1
fi
if [[ ! -d "${interrupt_home}/maintenance" ]]; then
  printf 'Ctrl-C did not preserve maintenance staging\n' >&2
  exit 1
fi

printf 'ok - maintenance preflight preserves staging owned by live or unknown units\n'
printf 'ok - maintenance prerequisites cannot fall through to submission\n'
printf 'ok - submitted maintenance units clean only after terminal proof\n'
printf 'ok - maintenance comma-encodes its configurable QEMU cache path\n'
printf 'ok - terminal cleanup reports malformed runtime controls\n'
printf 'ok - maintenance refuses QEMU exit zero without guest-shutdown proof\n'
printf 'ok - foreground Ctrl-C stops the unit and preserves staging\n'
