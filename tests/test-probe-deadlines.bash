#!/usr/bin/env bash
# shellcheck disable=SC2329  # test doubles are resolved by imported functions

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
export VIRTDEV_HOME="${test_tmp}/home"
qmp_listener_pid=""
stubborn_pid=""
cleanup() {
  if [[ "${stubborn_pid}" =~ ^[0-9]+$ ]]; then
    kill -KILL "${stubborn_pid}" 2>/dev/null || true
  fi
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

client_key="${test_tmp}/client-key"
printf 'test key\n' > "${client_key}"
chmod 600 "${client_key}"
mkdir -p "${VIRTDEV_HOME}/projects/probe"
printf 'ssh-host-identity=1\n' > "${VIRTDEV_HOME}/projects/probe/guest-contract"
ssh_host_identity_ensure probe

fixture_bin="${test_tmp}/bin"
ssh_args="${test_tmp}/ssh.args"
mkdir "${fixture_bin}"
ln -s "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
export PATH="${fixture_bin}:${PATH}"
# shellcheck disable=SC2016  # expanded by the generated fixture at execution
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$@" > "${SSH_PROBE_ARGS:?}"' \
  'sleep 30' > "${fixture_bin}/ssh"
chmod +x "${fixture_bin}/ssh"

export SSH_PROBE_ARGS="${ssh_args}"
started=${BASH_MONOSECONDS}
status=0
SYSTEMCTL_ACTIVE_STATE=active \
  ssh_poll_until_ready probe "${client_key}" 2222 virtdev-test 1 || status=$?
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
timeout() {
  while [[ "${1:-}" == --* ]]; do shift; done
  shift
  if [[ "${1:-}" == systemctl ]]; then
    command "$@"
    return $?
  fi
  (( ++timeout_calls ))
  return 124
}
sleep() {
  printf '%s\n' "${1}" > "${ssh_sleep}"
  printf 'inactive\n' > "${unit_state_file}"
}
status=0
SYSTEMCTL_STATE_FILE="${unit_state_file}" \
  ssh_poll_until_ready probe "${client_key}" 2222 virtdev-test 5 || status=$?
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
  while [[ "${1:-}" == --* ]]; do shift; done
  shift
  if [[ "${1:-}" == systemctl ]]; then
    command "$@"
    return $?
  fi
  (( ++timeout_calls ))
  command sleep 1
  return 124
}
status=0
SYSTEMCTL_STATE_FILE="${unit_state_file}" \
  ssh_poll_until_ready probe "${client_key}" 2222 virtdev-test 2 || status=$?
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

status=0
started=${BASH_MONOSECONDS}
SYSTEMCTL_ACTIVE_STATE=active \
SYSTEMCTL_IS_ACTIVE_DELAY=5 \
  ssh_poll_until_ready probe "${client_key}" 2222 virtdev-test 1 || status=$?
elapsed=$(( BASH_MONOSECONDS - started ))
if (( status != 1 || elapsed > 3 )) \
    || [[ "${VIRTDEV_SSH_POLL_STATE}" != timeout ]]; then
  printf 'stalled SSH unit query returned %d/%s after %ds\n' \
    "${status}" "${VIRTDEV_SSH_POLL_STATE}" "${elapsed}" >&2
  exit 1
fi

qmp_sock="${test_tmp}/qmp.sock"
/usr/bin/socat UNIX-LISTEN:"${qmp_sock}",fork EXEC:/bin/true >/dev/null 2>&1 &
qmp_listener_pid=$!
for (( attempt = 0; attempt < 100; ++attempt )); do
  [[ -S "${qmp_sock}" ]] && break
  sleep 0.01
done
if [[ ! -S "${qmp_sock}" ]]; then
  printf 'failed to create QMP test socket\n' >&2
  exit 1
fi

stubborn_bin="${test_tmp}/stubborn-bin"
stubborn_pid_file="${test_tmp}/stubborn.pid"
mkdir "${stubborn_bin}"
# shellcheck disable=SC2016  # expanded by the generated fixture
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "${BASHPID}" > "${QMP_STUBBORN_PID_FILE:?}"' \
  'trap "" TERM' \
  'exec sleep 30' \
  > "${stubborn_bin}/socat"
chmod 0755 "${stubborn_bin}/socat"
status=0
started=${BASH_MONOSECONDS}
PATH="${stubborn_bin}:${fixture_bin}:${PATH}" \
QMP_STUBBORN_PID_FILE="${stubborn_pid_file}" \
  _qmp_exchange "${qmp_sock}" 1 virtdev-stubborn \
    '{"execute":"query-status","id":"virtdev-stubborn"}' \
    >/dev/null || status=$?
elapsed=$(( BASH_MONOSECONDS - started ))
stubborn_pid="$(< "${stubborn_pid_file}")"
if (( status != 1 || elapsed > 3 )) \
    || kill -0 "${stubborn_pid}" 2>/dev/null; then
  printf 'stubborn QMP client was not killed/reaped (status %d, %ds)\n' \
    "${status}" "${elapsed}" >&2
  exit 1
fi
stubborn_pid=''

status=0
started=${BASH_MONOSECONDS}
SYSTEMCTL_ACTIVE_STATE=active \
SYSTEMCTL_SHOW_DELAY=5 \
  qmp_wait_shutdown "${qmp_sock}" 1 virtdev-test || status=$?
elapsed=$(( BASH_MONOSECONDS - started ))
if (( status != 1 || elapsed > 3 )) \
    || [[ "${VIRTDEV_QMP_WAIT_STATE}" != timeout ]]; then
  printf 'stalled QMP unit query returned %d/%s after %ds\n' \
    "${status}" "${VIRTDEV_QMP_WAIT_STATE}" "${elapsed}" >&2
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
SYSTEMCTL_ACTIVE_STATE=active qmp_query_running "${qmp_sock}" 1 || status=$?
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
printf 'ok - stalled manager queries and QMP client reaping stay bounded\n'
