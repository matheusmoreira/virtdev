#!/usr/bin/env bash
# shellcheck disable=SC2154  # qemu/runtime constants provided by imports

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
runtime_directory="${test_tmp}/runtime"
mkdir -p "${fixture_bin}" "${runtime_directory}"
chmod 0700 "${runtime_directory}"
cp "${repository}/tests/fixtures/passt-success" "${fixture_bin}/passt"
cp "${repository}/tests/fixtures/qemu-exit" "${fixture_bin}/qemu-test"
chmod +x "${fixture_bin}/passt" "${fixture_bin}/qemu-test"

phase_file="${runtime_directory}/launch.phase"
output="${test_tmp}/output"

status=0
PATH="${fixture_bin}:${PATH}" \
  "${repository}/libexec/virtdev/virtdev-netexec" \
    --runtime-dir "${runtime_directory}" \
    -- does-not-exist-virtdev-qemu >"${output}" 2>&1 || status=$?
if (( status != 86 )); then
  printf 'expected pre-exec missing-QEMU exit 86, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ "$(< "${phase_file}")" != shim ]]; then
  printf 'missing-QEMU failure did not retain shim provenance\n' >&2
  exit 1
fi

# A later port observation cannot authenticate why passt failed.
export PATH="${repository}/tests/fixtures:${fixture_bin}:${PATH}"
# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import qemu port
occupied_port=30000
while port_in_use "${occupied_port}"; do
  (( occupied_port++ ))
  (( occupied_port <= 40000 )) || exit 1
done
socat TCP-LISTEN:"${occupied_port}",bind=127.0.0.1,reuseaddr,fork \
  SYSTEM:'sleep 30' >"${test_tmp}/listener-output" 2>&1 &
listener_pid=$!
for _ in {1..50}; do
  port_in_use "${occupied_port}" && break
  sleep 0.02
done
if ! port_in_use "${occupied_port}"; then
  printf 'test listener did not bind port %s\n' "${occupied_port}" >&2
  kill "${listener_pid}" 2>/dev/null || true
  wait "${listener_pid}" 2>/dev/null || true
  exit 1
fi

status=0
PASST_EXIT_STATUS=42 PATH="${fixture_bin}:${PATH}" \
  "${repository}/libexec/virtdev/virtdev-netexec" \
    --runtime-dir "${runtime_directory}" \
    --forward "${occupied_port}" \
    -- qemu-test >"${output}" 2>&1 || status=$?
kill "${listener_pid}" 2>/dev/null || true
wait "${listener_pid}" 2>/dev/null || true
listener_pid=''
if (( status != passt_init_failure_exit_code )); then
  printf 'unrelated port occupancy changed passt failure to %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

for qemu_status in 83 84 85 86; do
  status=0
  PATH="${fixture_bin}:${PATH}" QEMU_EXIT_STATUS="${qemu_status}" \
    "${repository}/libexec/virtdev/virtdev-netexec" \
      --runtime-dir "${runtime_directory}" \
      -- qemu-test >"${output}" 2>&1 || status=$?
  if (( status != qemu_status )); then
    printf 'expected fake QEMU exit %d, got %d\n' \
      "${qemu_status}" "${status}" >&2
    cat "${output}" >&2
    exit 1
  fi
  if [[ "$(< "${phase_file}")" != qemu ]]; then
    printf 'executed QEMU did not publish qemu provenance\n' >&2
    exit 1
  fi
done

export SYSTEMCTL_ACTIVE_STATE=failed
export SYSTEMCTL_EXEC_MAIN_STATUS=83

runtime_launch_phase_publish "${phase_file}" "${runtime_launch_phase_shim}"
classification=0
qemu_activation_classify virtdev-probe 0 "${phase_file}" \
  || classification=$?
if (( classification != passt_missing_exit_code )); then
  printf 'authenticated shim exit 83 classified as %d\n' "${classification}" >&2
  exit 1
fi

active_sequence="${test_tmp}/active-sequence"
printf 'active\nfailed\n' > "${active_sequence}"
export SYSTEMCTL_ACTIVE_SEQUENCE_FILE="${active_sequence}"
runtime_launch_phase_publish "${phase_file}" "${runtime_launch_phase_shim}"
classification=0
qemu_activation_classify virtdev-probe 5 "${phase_file}" \
  || classification=$?
if (( classification != passt_missing_exit_code )); then
  printf 'active-to-failed shim exit 83 classified as %d\n' \
    "${classification}" >&2
  exit 1
fi
unset SYSTEMCTL_ACTIVE_SEQUENCE_FILE

for qemu_status in 83 84 85 86; do
  SYSTEMCTL_EXEC_MAIN_STATUS="${qemu_status}"
  export SYSTEMCTL_EXEC_MAIN_STATUS
  runtime_launch_phase_publish "${phase_file}" "${runtime_launch_phase_qemu}"
  classification=0
  qemu_activation_classify virtdev-probe 0 "${phase_file}" \
    || classification=$?
  if (( classification != qemu_crashed )); then
    printf 'QEMU exit %d was misclassified as shim failure %d\n' \
      "${qemu_status}" "${classification}" >&2
    exit 1
  fi
done

SYSTEMCTL_EXEC_MAIN_STATUS=83
export SYSTEMCTL_EXEC_MAIN_STATUS

printf 'bad\n' > "${phase_file}"
classification=0
qemu_activation_classify virtdev-probe 0 "${phase_file}" \
  || classification=$?
if (( classification != qemu_crashed )); then
  printf 'malformed provenance authorized shim diagnosis %d\n' \
    "${classification}" >&2
  exit 1
fi

rm "${phase_file}"
classification=0
qemu_activation_classify virtdev-probe 0 "${phase_file}" \
  || classification=$?
if (( classification != qemu_crashed )); then
  printf 'missing provenance authorized shim diagnosis %d\n' \
    "${classification}" >&2
  exit 1
fi

runtime_launch_phase_publish "${phase_file}" "${runtime_launch_phase_qemu}"
runtime_clean "${runtime_directory}"
if [[ -e "${phase_file}" || -e "${phase_file}.tmp" ]]; then
  printf 'runtime teardown retained launch provenance controls\n' >&2
  exit 1
fi

printf 'ok - netexec exit diagnosis requires authenticated launch provenance\n'
