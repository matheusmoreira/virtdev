#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
virtdev_home="${test_tmp}/store"
project_directory="${virtdev_home}/projects/probe"
system_directory="${virtdev_home}/system"
lock_directory="${test_tmp}/locks"
firmware="${test_tmp}/OVMF.fd"
output="${test_tmp}/output"
marker="${test_tmp}/systemd-run.called"
mkdir -p "${fixture_bin}" "${project_directory}" "${system_directory}"
ln -s "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
# shellcheck disable=SC2016  # expanded by the generated fixture
printf '%s\n' \
  '#!/usr/bin/env bash' \
  ': > "${SYSTEMD_RUN_MARKER:?}"' \
  'if [[ -n "${SYSTEMD_RUN_ARGV_FILE:-}" ]]; then' \
  '  printf "%s\0" "$@" > "${SYSTEMD_RUN_ARGV_FILE}"' \
  'fi' \
  'exit "${SYSTEMD_RUN_STATUS:-0}"' \
  > "${fixture_bin}/systemd-run"
chmod 0755 "${fixture_bin}/systemd-run"
# shellcheck disable=SC2016  # expanded by the generated fixture
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ -n "${START_RUNTIME_DIRECTORY:-}" ]]; then' \
  '  for control in monitor.sock console.sock network.sock passt.sock qmp.sock port port.tmp launch.phase launch.phase.tmp; do' \
  '    : > "${START_RUNTIME_DIRECTORY}/${control}"' \
  '  done' \
  'fi' \
  'printf "yes\n"' \
  > "${fixture_bin}/loginctl"
chmod 0755 "${fixture_bin}/loginctl"

for file in system.qcow2 home.qcow2 nvram; do
  : > "${project_directory}/${file}"
done
: > "${firmware}"
printf '1\n' > "${system_directory}/generation"
printf '1\n' > "${project_directory}/generation"
printf 'ssh-host-identity=1\n' > "${project_directory}/guest-contract"

project_target="${virtdev_home}/project-target"
mv -T -- "${project_directory}" "${project_target}"
chmod 0755 "${project_target}"
: > "${project_target}/monitor.sock"
ln -s ../project-target "${project_directory}"
status=0
SYSTEMD_RUN_MARKER="${marker}" \
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
OVMF_CODE="${firmware}" \
NO_COLOR=1 \
  "${repository}/bin/virtdev-start" --unfiltered probe \
    >"${output}" 2>&1 || status=$?
if (( status != 3 )) || [[ ! -L "${project_directory}" \
      || ! -e "${project_target}/monitor.sock" \
      || "$(stat -c '%a' "${project_target}")" != 755 ]]; then
  printf 'start followed a symlinked project root (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
rm -f -- "${project_directory}"
mv -T -- "${project_target}" "${project_directory}"

image_target="${test_tmp}/external-system.qcow2"
printf 'external image\n' > "${image_target}"
rm -f -- "${project_directory}/system.qcow2"
ln -s "${image_target}" "${project_directory}/system.qcow2"
status=0
SYSTEMD_RUN_MARKER="${marker}" \
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
OVMF_CODE="${firmware}" \
NO_COLOR=1 \
  "${repository}/bin/virtdev-start" --unfiltered probe \
    >"${output}" 2>&1 || status=$?
if (( status != 4 )) || [[ "$(< "${image_target}")" != 'external image' ]]; then
  printf 'start accepted a symlinked writable image (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
rm -f -- "${project_directory}/system.qcow2"
: > "${project_directory}/system.qcow2"

rm -f -- "${project_directory}/generation"
status=0
SYSTEMCTL_ACTIVE_STATE=inactive \
SYSTEMD_RUN_MARKER="${marker}" \
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
OVMF_CODE="${firmware}" \
NO_COLOR=1 \
  "${repository}/bin/virtdev-start" --unfiltered probe \
    >"${output}" 2>&1 || status=$?
if (( status != 10 )) || grep -Fq 'virtdev-destroy' "${output}" \
    || ! grep -Fq 'Do not destroy' "${output}"; then
  printf 'missing-generation recovery risked project data (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

printf '0\n' > "${project_directory}/generation"
status=0
SYSTEMCTL_ACTIVE_STATE=inactive \
SYSTEMD_RUN_MARKER="${marker}" \
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
OVMF_CODE="${firmware}" \
NO_COLOR=1 \
  "${repository}/bin/virtdev-start" --unfiltered probe \
    >"${output}" 2>&1 || status=$?
if (( status != 11 )) || grep -Fq 'virtdev-destroy' "${output}" \
    || ! grep -Fq 'virtdev-recreate --no-backup --snapshot' "${output}"; then
  printf 'generation-mismatch recovery risked project data (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
printf '1\n' > "${project_directory}/generation"

declare -a controls=(
  monitor.sock console.sock network.sock passt.sock qmp.sock
  port port.tmp launch.phase launch.phase.tmp
)
for active_state in active activating deactivating reloading; do
  for control in "${controls[@]}"; do
    : > "${project_directory}/${control}"
  done
  status=0
  SYSTEMCTL_ACTIVE_STATE="${active_state}" \
  SYSTEMD_RUN_MARKER="${marker}" \
  PATH="${fixture_bin}:${PATH}" \
  HOME="${test_tmp}" \
  VIRTDEV_HOME="${virtdev_home}" \
  VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
  OVMF_CODE="${firmware}" \
  NO_COLOR=1 \
    "${repository}/bin/virtdev-start" --unfiltered probe \
      >"${output}" 2>&1 || status=$?
  if (( status != 6 )); then
    printf 'start accepted unit state %s (status %d)\n' \
      "${active_state}" "${status}" >&2
    cat "${output}" >&2
    exit 1
  fi
  [[ ! -e "${marker}" ]]
  for control in "${controls[@]}"; do
    if [[ ! -e "${project_directory}/${control}" ]]; then
      printf 'start removed %s while unit state was %s\n' \
        "${control}" "${active_state}" >&2
      exit 1
    fi
  done
done

status=0
SYSTEMCTL_UNREACHABLE=1 \
SYSTEMD_RUN_MARKER="${marker}" \
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
OVMF_CODE="${firmware}" \
NO_COLOR=1 \
  "${repository}/bin/virtdev-start" --unfiltered probe \
    >"${output}" 2>&1 || status=$?
if (( status != 6 )); then
  printf 'start accepted an unreachable manager (status %d)\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
for control in "${controls[@]}"; do
  [[ -e "${project_directory}/${control}" ]]
done

active_sequence="${test_tmp}/active-sequence"
printf 'inactive\ndeactivating\n' > "${active_sequence}"
status=0
SYSTEMCTL_ACTIVE_SEQUENCE_FILE="${active_sequence}" \
SYSTEMD_RUN_MARKER="${marker}" \
START_RUNTIME_DIRECTORY="${project_directory}" \
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
OVMF_CODE="${firmware}" \
NO_COLOR=1 \
  "${repository}/bin/virtdev-start" --unfiltered probe \
    >"${output}" 2>&1 || status=$?
if (( status != 6 )) || [[ -e "${marker}" ]]; then
  printf 'start crossed a submission-boundary state change (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq 'deactivating' "${output}"
for control in "${controls[@]}"; do
  if [[ ! -e "${project_directory}/${control}" ]]; then
    printf 'failed-start trap removed externally reclaimed control %s\n' \
      "${control}" >&2
    exit 1
  fi
done

argv_file="${test_tmp}/systemd-run.argv"
stop_marker="${test_tmp}/stop.called"
rm -f -- "${marker}"
status=0
SYSTEMCTL_ACTIVE_STATE=inactive \
SYSTEMCTL_STOP_FILE="${stop_marker}" \
SYSTEMD_RUN_MARKER="${marker}" \
SYSTEMD_RUN_ARGV_FILE="${argv_file}" \
SYSTEMD_RUN_STATUS=42 \
START_RUNTIME_DIRECTORY="${project_directory}" \
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
OVMF_CODE="${firmware}" \
NO_COLOR=1 \
  "${repository}/bin/virtdev-start" --unfiltered probe \
    >"${output}" 2>&1 || status=$?
if (( status != 42 )) || [[ ! -e "${marker}" || ! -s "${argv_file}" ]]; then
  printf 'start did not reach the controlled submission fixture (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ -e "${stop_marker}" ]]; then
  printf 'failed systemd-run stopped a unit whose ownership was unproven\n' >&2
  exit 1
fi
if ! grep -Fq 'unit submission is indeterminate' "${output}" \
    || ! grep -Fq 'systemctl --user status virtdev-probe' "${output}" \
    || ! grep -Fq 'inactive/failed state before another start' "${output}"; then
  printf 'failed systemd-run omitted its ownership recovery diagnostic\n' >&2
  cat "${output}" >&2
  exit 1
fi
for control in "${controls[@]}"; do
  if [[ ! -e "${project_directory}/${control}" ]]; then
    printf 'failed systemd-run removed unproven control %s\n' \
      "${control}" >&2
    exit 1
  fi
done
mapfile -d '' -t systemd_run_argv < "${argv_file}"
expected_monitor="--setenv=VIRTDEV_STOP_MONITOR_SOCK=${project_directory}/monitor.sock"
expected_stop="--property=ExecStop=${repository}/libexec/virtdev/virtdev-stop-acpi probe \${MAINPID}"
if [[ ! " ${systemd_run_argv[*]} " == *" ${expected_monitor} "* \
    || ! " ${systemd_run_argv[*]} " == *" ${expected_stop} "* ]]; then
  printf 'start did not bind the stop hook to its monitor and main process\n' >&2
  printf 'argv: %q\n' "${systemd_run_argv[@]}" >&2
  exit 1
fi

printf 'ok - start preserves controls unless unit state is terminal\n'
printf 'ok - start rejects symlinked project roots and writable images\n'
printf 'ok - start rechecks unit state at the submission boundary\n'
printf 'ok - failed submission never claims or stops the fixed unit name\n'
printf 'ok - ambiguous submission reports the required ownership inspection\n'
printf 'ok - start binds ExecStop to the exact monitor and systemd main PID\n'
