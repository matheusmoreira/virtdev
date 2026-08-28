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
runtime_dir="${test_tmp}/runtime"
output="${test_tmp}/output"
mkdir -p "${fixture_bin}" "${runtime_dir}"
chmod 0700 "${runtime_dir}"
cp "${repository}/tests/fixtures/passt-success" "${fixture_bin}/passt"
cp "${repository}/tests/fixtures/qemu-exit" "${fixture_bin}/qemu-test"
chmod 755 "${fixture_bin}/passt" "${fixture_bin}/qemu-test"

run_netexec() {
  PATH="${fixture_bin}:${PATH}" \
    "${repository}/libexec/virtdev/virtdev-netexec" "$@"
}

outside="${test_tmp}/outside"
printf 'keep\n' > "${outside}"
status=0
run_netexec --socket "${outside}" --phase-file "${outside}" -- qemu-test \
  >"${output}" 2>&1 || status=$?
(( status == 64 ))
[[ "$(< "${outside}")" == keep ]]

printf 'keep\n' > "${runtime_dir}/network.sock"
status=0
run_netexec --runtime-dir "${runtime_dir}" -- qemu-test \
  >"${output}" 2>&1 || status=$?
(( status == 1 ))
[[ "$(< "${runtime_dir}/network.sock")" == keep ]]
rm "${runtime_dir}/network.sock"

phase_target="${test_tmp}/phase-target"
printf 'keep\n' > "${phase_target}"
ln -s "${phase_target}" "${runtime_dir}/launch.phase"
status=0
run_netexec --runtime-dir "${runtime_dir}" -- qemu-test \
  >"${output}" 2>&1 || status=$?
(( status == 1 ))
[[ "$(< "${phase_target}")" == keep ]]
rm "${runtime_dir}/launch.phase"

chmod 0755 "${runtime_dir}"
status=0
run_netexec --runtime-dir "${runtime_dir}" -- qemu-test \
  >"${output}" 2>&1 || status=$?
(( status == 64 ))
chmod 0700 "${runtime_dir}"

ln -s "${runtime_dir}" "${test_tmp}/runtime-link"
status=0
run_netexec --runtime-dir "${test_tmp}/runtime-link" -- qemu-test \
  >"${output}" 2>&1 || status=$?
(( status == 64 ))

printf 'stale\n' > "${runtime_dir}/launch.phase"
socat UNIX-LISTEN:"${runtime_dir}/network.sock" SYSTEM:'sleep 30' \
  >"${test_tmp}/listener.output" 2>&1 &
listener_pid=$!
for _ in {1..50}; do
  [[ -S "${runtime_dir}/network.sock" ]] && break
  sleep 0.02
done
[[ -S "${runtime_dir}/network.sock" ]]
run_netexec --runtime-dir "${runtime_dir}" -- qemu-test
[[ "$(< "${runtime_dir}/launch.phase")" == qemu ]]
[[ ! -e "${runtime_dir}/network.sock" ]]
kill "${listener_pid}" 2>/dev/null || true
wait "${listener_pid}" 2>/dev/null || true
listener_pid=''

printf 'legacy\n' > "${runtime_dir}/passt.sock"
# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import runtime
runtime_clean_sockets "${runtime_dir}"
[[ ! -e "${runtime_dir}/passt.sock" ]]

printf 'ok - netexec derives and validates its fixed runtime artifacts\n'
