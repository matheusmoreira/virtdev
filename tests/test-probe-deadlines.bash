#!/usr/bin/env bash
# shellcheck disable=SC2329  # test doubles are resolved by imported functions

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
qmp_listener_pid=""
cleanup() {
  if [[ -n "${qmp_listener_pid}" ]]; then
    kill "${qmp_listener_pid}" 2>/dev/null || true
    wait "${qmp_listener_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

# shellcheck disable=SC1090,SC1091
source "${repository}/lib/virtdev/import"
import ssh
import qmp

systemctl() {
  printf 'active\n'
}

fixture_bin="${test_tmp}/bin"
ssh_args="${test_tmp}/ssh.args"
mkdir "${fixture_bin}"
# shellcheck disable=SC2016  # expanded by the generated fixture at execution
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$@" > "${SSH_PROBE_ARGS:?}"' \
  'sleep 30' > "${fixture_bin}/ssh"
chmod +x "${fixture_bin}/ssh"

export SSH_PROBE_ARGS="${ssh_args}"
started=${BASH_MONOSECONDS}
status=0
PATH="${fixture_bin}:${PATH}" \
  ssh_poll_until_ready /unused 22 virtdev-test 1 || status=$?
elapsed=$(( BASH_MONOSECONDS - started ))

if (( status != 1 || elapsed > 2 )); then
  printf 'one-second SSH poll returned %d after %d seconds\n' \
    "${status}" "${elapsed}" >&2
  exit 1
fi
if [[ ! -s "${ssh_args}" ]] \
    || ! grep -Fxq 'ConnectTimeout=1' "${ssh_args}"; then
  printf 'SSH probe did not inherit the one-second outer budget\n' >&2
  exit 1
fi

unit_state_file="${test_tmp}/unit.state"
ssh_sleep="${test_tmp}/ssh.sleep"
timeout_calls=0
printf 'active\n' > "${unit_state_file}"
systemctl() {
  local state
  IFS= read -r state < "${unit_state_file}"
  printf '%s\n' "${state}"
}
timeout() {
  (( ++timeout_calls ))
  return 124
}
sleep() {
  printf '%s\n' "${1}" > "${ssh_sleep}"
  printf 'inactive\n' > "${unit_state_file}"
}
status=0
ssh_poll_until_ready /unused 22 virtdev-test 5 || status=$?
if (( status != 2 || timeout_calls != 1 )) || [[ ! -s "${ssh_sleep}" ]]; then
  printf 'ample-budget SSH retry did not sleep once before unit exit\n' >&2
  exit 1
fi
if [[ "$(< "${ssh_sleep}")" != 2 ]]; then
  printf 'ample-budget SSH retry did not sleep once before unit exit\n' >&2
  exit 1
fi

rm -f -- "${ssh_sleep}"
printf 'active\n' > "${unit_state_file}"
timeout_calls=0
timeout() {
  (( ++timeout_calls ))
  command sleep 1
  return 124
}
status=0
ssh_poll_until_ready /unused 22 virtdev-test 2 || status=$?
if (( status != 1 && status != 2 )); then
  printf 'failed SSH probe returned undocumented status %d\n' "${status}" >&2
  exit 1
fi
if (( timeout_calls != 1 )); then
  printf 'SSH retry path made %d probes inside its outer budget\n' \
    "${timeout_calls}" >&2
  exit 1
fi
if [[ -e "${ssh_sleep}" ]]; then
  if [[ "$(< "${ssh_sleep}")" != 1 ]]; then
    printf 'SSH retry sleep exceeded the remaining outer budget\n' >&2
    exit 1
  fi
elif (( status != 1 )); then
  printf 'SSH retry sleep disappeared before deadline exhaustion\n' >&2
  exit 1
fi
unset -f timeout sleep
systemctl() {
  printf 'active\n'
}

qmp_sock="${test_tmp}/qmp.sock"
socat UNIX-LISTEN:"${qmp_sock}",fork EXEC:/bin/true >/dev/null 2>&1 &
qmp_listener_pid=$!
for (( attempt = 0; attempt < 100; ++attempt )); do
  [[ -S "${qmp_sock}" ]] && break
  sleep 0.01
done
if [[ ! -S "${qmp_sock}" ]]; then
  printf 'failed to create QMP test socket\n' >&2
  exit 1
fi

qmp_timeout="${test_tmp}/qmp.timeout"
qmp_poll_sleep="${test_tmp}/qmp.sleep"
_qmp_exchange() {
  printf '%s\n' "${2}" > "${qmp_timeout}"
  command sleep "${2}"
  return 1
}
sleep() {
  : > "${qmp_poll_sleep}"
  command sleep "$@"
}

started=${BASH_MONOSECONDS}
status=0
qmp_query_running "${qmp_sock}" 1 || status=$?
elapsed=$(( BASH_MONOSECONDS - started ))
if (( status != 1 || elapsed > 2 )) || [[ ! -s "${qmp_timeout}" ]]; then
  printf 'one-second QMP poll did not complete inside its outer budget\n' >&2
  exit 1
fi
if [[ "$(< "${qmp_timeout}")" != 1 || -e "${qmp_poll_sleep}" ]]; then
  printf 'one-second QMP poll returned %d after %d seconds (probe %s)\n' \
    "${status}" "${elapsed}" "$(< "${qmp_timeout}")" >&2
  exit 1
fi

printf 'ok - SSH probes and retries stay inside their outer deadline\n'
printf 'ok - QMP launch probes stay inside their outer deadline\n'
