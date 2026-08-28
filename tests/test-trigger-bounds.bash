#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154  # generated fixtures and nameref outputs

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
declare -A guard_cgroups=()
declare -A guard_deadlines=()
declare -A guard_dirs=()
declare -A guard_invocations=()
declare -A guard_units=()
declare -A guard_wrapper_pids=()
declare -A guard_wrapper_starts=()
guard_serial=0
guard_systemctl="$(command -v systemctl || true)"
guard_systemd_run="$(command -v systemd-run || true)"
guard_timeout="$(command -v timeout || true)"

if [[ ! -x "${guard_systemctl}" || ! -x "${guard_systemd_run}" \
    || ! -x "${guard_timeout}" ]]; then
  printf 'trigger bounds require systemd-run, systemctl, and timeout\n' >&2
  exit 1
fi

process_identity() {
  local -r __identity_pid="${1}"
  local -n __identity_state_ref="${2}"
  local -n __identity_start_ref="${3}"
  local __identity_stat __identity_fields
  local -a __identity_parts

  if ! { IFS= read -r __identity_stat \
      < "/proc/${__identity_pid}/stat"; } 2>/dev/null; then
    return 1
  fi
  __identity_fields="${__identity_stat##*) }"
  read -ra __identity_parts <<<"${__identity_fields}"
  (( ${#__identity_parts[@]} >= 20 )) || return 1
  [[ "${__identity_parts[0]}" =~ ^[A-Za-z]$ \
      && "${__identity_parts[19]}" =~ ^[0-9]+$ ]] || return 1
  __identity_state_ref="${__identity_parts[0]}"
  __identity_start_ref="${__identity_parts[19]}"
}

pid_running() {
  local -r pid="${1}"
  local state="" start_time=""
  process_identity "${pid}" state start_time || return 1
  [[ "${state}" != Z && "${state}" != X ]]
}

process_cgroup() {
  local -r pid="${1}"
  local -n _process_cgroup_ref="${2}"
  local hierarchy controllers path

  while IFS=: read -r hierarchy controllers path; do
    if [[ "${hierarchy}" == 0 && -z "${controllers}" ]]; then
      _process_cgroup_ref="${path}"
      return 0
    fi
  done < "/proc/${pid}/cgroup" 2>/dev/null
  return 1
}

guard_scope_snapshot() {
  local -r unit="${1}"
  local -n _scope_load_ref="${2}"
  local -n _scope_active_ref="${3}"
  local -n _scope_invocation_ref="${4}"
  local -n _scope_cgroup_ref="${5}"
  local properties key value

  _scope_load_ref=""
  _scope_active_ref=""
  _scope_invocation_ref=""
  _scope_cgroup_ref=""
  properties="$(
    "${guard_timeout}" --signal=KILL 2 \
      "${guard_systemctl}" --user show "${unit}" --no-pager \
        -p LoadState -p ActiveState -p InvocationID -p ControlGroup
  )" || return 1
  while IFS='=' read -r key value; do
    case "${key}" in
      LoadState) _scope_load_ref="${value}" ;;
      ActiveState) _scope_active_ref="${value}" ;;
      InvocationID) _scope_invocation_ref="${value}" ;;
      ControlGroup) _scope_cgroup_ref="${value}" ;;
    esac
  done <<< "${properties}"
}

guard_scope_record() {
  local -r guard_pid="${1}"
  local load="" active="" invocation="" cgroup=""

  guard_scope_snapshot "${guard_units[${guard_pid}]}" \
    load active invocation cgroup || return 1
  [[ "${load}" == loaded && "${active}" == active \
      && "${invocation}" =~ ^[[:xdigit:]]{32}$ \
      && "${cgroup}" == /* \
      && "${cgroup##*/}" == "${guard_units[${guard_pid}]}" \
      && -r "/sys/fs/cgroup${cgroup}/cgroup.events" ]] || return 1
  guard_invocations["${guard_pid}"]="${invocation}"
  guard_cgroups["${guard_pid}"]="${cgroup}"
}

guard_scope_population() {
  local -r guard_pid="${1}"
  local -n _scope_population_ref="${2}"
  local -r expected_invocation="${guard_invocations[${guard_pid}]:-}"
  local -r expected_cgroup="${guard_cgroups[${guard_pid}]:-}"
  local load="" active="" invocation="" cgroup="" key value
  local -r cgroup_dir="/sys/fs/cgroup${expected_cgroup}"

  _scope_population_ref=""
  [[ -n "${expected_invocation}" && -n "${expected_cgroup}" ]] || return 1
  if [[ ! -e "${cgroup_dir}" ]]; then
    _scope_population_ref=0
    return 0
  fi
  while IFS=' ' read -r key value; do
    if [[ "${key}" == populated && "${value}" =~ ^[01]$ ]]; then
      _scope_population_ref="${value}"
      break
    fi
  done < "${cgroup_dir}/cgroup.events" 2>/dev/null
  [[ "${_scope_population_ref:-}" =~ ^[01]$ ]] || return 1
  (( _scope_population_ref == 0 )) && return 0
  guard_scope_snapshot "${guard_units[${guard_pid}]}" \
    load active invocation cgroup || return 1
  [[ "${load}" == loaded && "${invocation}" == "${expected_invocation}" \
      && "${cgroup}" == "${expected_cgroup}" ]]
}

guard_wrapper_valid() {
  local -r guard_pid="${1}" required_state="${2:-}"
  local -r wrapper_pid="${guard_wrapper_pids[${guard_pid}]:-}"
  local state="" start_time="" cgroup=""

  [[ "${wrapper_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  process_identity "${wrapper_pid}" state start_time || return 1
  process_cgroup "${wrapper_pid}" cgroup || return 1
  [[ "${start_time}" == "${guard_wrapper_starts[${guard_pid}]:-}" \
      && "${cgroup}" == "${guard_cgroups[${guard_pid}]:-}" \
      && "${state}" != Z && "${state}" != X \
      && ( -z "${required_state}" \
        || "${state}" == "${required_state}" \
        || "${state}" == "${required_state,,}" ) ]]
}

stop_guard_scope() {
  local -r guard_pid="${1}"
  local attempt population=1

  for (( attempt = 0; attempt < 200; ++attempt )); do
    guard_scope_population "${guard_pid}" population || return 1
    (( population == 0 )) && return 0
    "${guard_timeout}" --signal=KILL 2 \
      "${guard_systemctl}" --user kill --kill-whom=all \
        --signal=KILL "${guard_units[${guard_pid}]}" \
      >/dev/null 2>&1 || true
    sleep 0.01
  done
  return 1
}

forget_guard() {
  local -r guard_pid="${1}"

  rm -rf -- "${guard_dirs[${guard_pid}]}"
  unset "guard_cgroups[${guard_pid}]" \
    "guard_deadlines[${guard_pid}]" \
    "guard_dirs[${guard_pid}]" \
    "guard_invocations[${guard_pid}]" \
    "guard_units[${guard_pid}]" \
    "guard_wrapper_pids[${guard_pid}]" \
    "guard_wrapper_starts[${guard_pid}]"
}

cleanup() {
  local rc=$? guard_pid failed=0 payload_seen=0
  trap - EXIT
  for guard_pid in "${!guard_units[@]}"; do
    payload_seen=0
    release_guard "${guard_pid}" payload_seen || failed=1
  done
  if (( failed )); then
    printf 'trigger test teardown could not verify every guard scope\n' >&2
    printf 'temporary state retained at %s\n' "${test_tmp}" >&2
    (( rc != 0 )) && return "${rc}"
    exit 1
  fi
  rm -rf -- "${test_tmp}"
  return "${rc}"
}
trap cleanup EXIT

guarded() {
  local -r deadline="${1}"
  local guard_pid start_status=0
  shift
  start_guarded guard_pid "${deadline}" "$@" || start_status=$?
  (( start_status == 0 )) || return "${start_status}"
  wait_guarded "${guard_pid}"
}

start_guarded() {
  local -n _guard_pid_ref="${1}"
  local -r deadline="${2}"
  local guard_dir state="" unit wrapper_cgroup=""
  local wrapper_pid wrapper_start="" attempt load="" active=""
  local invocation="" cgroup="" payload_seen=0
  local -r unit_suffix="${test_tmp##*.}"
  shift 2

  (( ++guard_serial ))
  guard_dir="$(mktemp -d "${test_tmp}/guard.XXXXXX")" || return 125
  unit="virtdev-test-${BASHPID}-${unit_suffix}-${guard_serial}.scope"
  "${guard_systemd_run}" --user --scope --collect --quiet \
    --expand-environment=no \
    --property=KillMode=control-group \
    --property="RuntimeMaxSec=$(( deadline + 3 ))s" \
    --property=TimeoutStopSec=1s \
    --unit="${unit}" \
    /usr/bin/bash -c '
    set -uo pipefail
    trap "" INT TERM HUP
    umask 077
    wrapper_path="${1}"
    status_path="${2}"
    shift 2
    printf "%s\n" "${BASHPID}" > "${wrapper_path}" || exit 125
    kill -STOP "${BASHPID}"
    status=0
    /usr/bin/env --default-signal=INT --default-signal=TERM \
      --default-signal=HUP "$@" &
    target_pid=$!
    wait "${target_pid}" || status=$?
    exec </dev/null >/dev/null 2>&1
    printf "%s\n" "${status}" > "${status_path}.pending" || exit 125
    /usr/bin/mv -f -- "${status_path}.pending" "${status_path}" || exit 125
    kill -STOP "${BASHPID}"
    exit 125
  ' _ "${guard_dir}/wrapper" "${guard_dir}/status" "$@" &
  _guard_pid_ref=$!
  guard_dirs["${_guard_pid_ref}"]="${guard_dir}"
  guard_deadlines["${_guard_pid_ref}"]="${deadline}"
  guard_units["${_guard_pid_ref}"]="${unit}"

  for (( attempt = 0; attempt < 300; ++attempt )); do
    if [[ -s "${guard_dir}/wrapper" ]] \
        && guard_scope_record "${_guard_pid_ref}"; then
      wrapper_pid="$(< "${guard_dir}/wrapper")"
      if [[ "${wrapper_pid}" =~ ^[1-9][0-9]*$ ]] \
          && process_identity "${wrapper_pid}" state wrapper_start \
          && process_cgroup "${wrapper_pid}" wrapper_cgroup \
          && [[ ( "${state}" == T || "${state}" == t ) \
            && "${wrapper_cgroup}" == "${guard_cgroups[${_guard_pid_ref}]}" ]]; then
        guard_wrapper_pids["${_guard_pid_ref}"]="${wrapper_pid}"
        guard_wrapper_starts["${_guard_pid_ref}"]="${wrapper_start}"
        kill -CONT "${wrapper_pid}" 2>/dev/null || break
        return 0
      fi
    fi
    pid_running "${_guard_pid_ref}" || break
    sleep 0.01
  done

  if [[ -n "${guard_invocations[${_guard_pid_ref}]:-}" ]]; then
    release_guard "${_guard_pid_ref}" payload_seen || true
  else
    kill -KILL "${_guard_pid_ref}" 2>/dev/null || true
    wait "${_guard_pid_ref}" 2>/dev/null || true
    for (( attempt = 0; attempt < 100; ++attempt )); do
      if guard_scope_snapshot "${guard_units[${_guard_pid_ref}]}" \
          load active invocation cgroup; then
        if [[ "${load}" == not-found ]]; then
          forget_guard "${_guard_pid_ref}"
          break
        fi
        if guard_scope_record "${_guard_pid_ref}"; then
          release_guard "${_guard_pid_ref}" payload_seen || true
          break
        fi
      fi
      sleep 0.01
    done
  fi
  return 125
}

release_guard() {
  local -r guard_pid="${1}"
  local -n _release_payload_seen_ref="${2}"
  local -r wrapper_pid="${guard_wrapper_pids[${guard_pid}]:-}"
  local -r wrapper_start="${guard_wrapper_starts[${guard_pid}]:-}"
  local attempt contained=0 graceful=0 population=0 state="" start_time=""

  _release_payload_seen_ref=0
  [[ -n "${guard_invocations[${guard_pid}]:-}" \
      && -n "${guard_cgroups[${guard_pid}]:-}" ]] || return 1

  if [[ -n "${wrapper_pid}" \
      && -f "${guard_dirs[${guard_pid}]}/status" ]] \
      && guard_wrapper_valid "${guard_pid}" T; then
    kill -CONT "${wrapper_pid}" 2>/dev/null || return 1
    graceful=1
    for (( attempt = 0; attempt < 100; ++attempt )); do
      if ! process_identity "${wrapper_pid}" state start_time \
          || [[ "${start_time}" != "${wrapper_start}" \
            || "${state}" == Z || "${state}" == X ]]; then
        break
      fi
      sleep 0.01
    done
  fi

  if (( graceful )); then
    guard_scope_population "${guard_pid}" population || return 1
    (( population )) && _release_payload_seen_ref=1
  fi
  stop_guard_scope "${guard_pid}" || return 1
  wait "${guard_pid}" 2>/dev/null || true
  guard_scope_population "${guard_pid}" population || return 1
  (( population == 0 )) && contained=1
  (( contained )) || return 1

  forget_guard "${guard_pid}"
}

wait_guarded() {
  local -r guard_pid="${1}"
  local -r guard_dir="${guard_dirs[${guard_pid}]:-}"
  local -r deadline="${guard_deadlines[${guard_pid}]:-0}"
  local attempt status_record="" command_status=125 ready=0
  local stop_payload_seen=0

  [[ -n "${guard_dir}" && "${deadline}" =~ ^[1-9][0-9]*$ ]] || return 125
  for (( attempt = 0; attempt < (deadline + 5) * 100; ++attempt )); do
    if [[ -f "${guard_dir}/status" ]] \
        && IFS= read -r status_record < "${guard_dir}/status" \
        && [[ "${status_record}" =~ ^[0-9]{1,3}$ ]] \
        && (( status_record <= 255 )) \
        && guard_wrapper_valid "${guard_pid}" T; then
      command_status="${status_record}"
      ready=1
      break
    fi
    pid_running "${guard_pid}" || break
    sleep 0.01
  done

  if ! release_guard "${guard_pid}" stop_payload_seen; then
    return 125
  fi
  (( ready && ! stop_payload_seen )) || return 125
  return "${command_status}"
}

wait_for_file() {
  local -r path="${1}"
  local attempt
  for (( attempt = 0; attempt < 500; ++attempt )); do
    [[ -s "${path}" ]] && return 0
    sleep 0.01
  done
  return 1
}

run_trigger_guarded() {
  local -r event="${1}"
  guarded 8 bash -c '
    set -euo pipefail
    source "${TRIGGER_TEST_REPOSITORY}/lib/virtdev/import"
    import trigger
    output=""
    trigger_fire "${1}" output
  ' _ "${event}"
}

assert_pid_gone() {
  local -r pid_file="${1}" description="${2}"
  local pid attempt
  pid="$(< "${pid_file}")"
  for (( attempt = 0; attempt < 100; ++attempt )); do
    if ! pid_running "${pid}"; then
      printf '0\n' > "${pid_file}"
      return 0
    fi
    sleep 0.01
  done
  printf '%s left process %s alive\n' "${description}" "${pid}" >&2
  return 1
}

export XDG_CONFIG_HOME="${test_tmp}/config"
export VIRTDEV_PROJECT=probe
export VIRTDEV_TRIGGER_TIMEOUT=1
export VIRTDEV_TRIGGER_KILL_AFTER=1
export VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES=64
export TRIGGER_TEST_REPOSITORY="${repository}"
export TMPDIR="${test_tmp}/tmp"
mkdir "${TMPDIR}"

system_triggers="${XDG_CONFIG_HOME}/virtdev/triggers"
project_triggers="${XDG_CONFIG_HOME}/virtdev/projects/probe/triggers"
mkdir -p "${system_triggers}" "${project_triggers}"

# shellcheck disable=SC1090,SC1091
source "${repository}/lib/virtdev/import"
import trigger

pgid_handoff="${test_tmp}/pgid-handoff"
pgid_pid_file="${test_tmp}/pgid-handoff.pid"
pgid_probe_file="${test_tmp}/pgid-handoff.probe"
pgid_survived_file="${test_tmp}/pgid-handoff.survived"
pgid_done_file="${test_tmp}/pgid-handoff.done"
cc -std=c99 -Wall -Wextra -Wpedantic -O2 \
  -o "${pgid_handoff}" "${repository}/tests/support/pgid-handoff.c"

status=0
guarded 2 /usr/bin/true || status=$?
if (( status != 0 )); then
  printf 'trigger bounds require unified cgroup v2 and a reachable systemd --user manager\n' >&2
  exit 1
fi

status=0
guarded 4 bash -c '
  "${1}" "${2}" "${3}" "${4}" "${5}" 10000 &
  for (( attempt = 0; attempt < 1000; ++attempt )); do
    [[ -s "${2}" ]] && break
    sleep 0.001
  done
  [[ -s "${2}" ]] || exit 126
  exit 0
' _ "${pgid_handoff}" "${pgid_pid_file}" "${pgid_probe_file}" \
  "${pgid_survived_file}" "${pgid_done_file}" || status=$?
: > "${pgid_probe_file}"
for (( attempt = 0; attempt < 50; ++attempt )); do
  [[ ! -e "${pgid_survived_file}" ]] || break
  sleep 0.01
done
if (( status != 125 )) || [[ -e "${pgid_survived_file}" \
    || -e "${pgid_done_file}" ]]; then
  for (( attempt = 0; attempt < 1000; ++attempt )); do
    [[ -e "${pgid_done_file}" ]] && break
    sleep 0.01
  done
  printf 'guard released a same-session process-group handoff\n' >&2
  exit 1
fi
assert_pid_gone "${pgid_pid_file}" 'guarded process-group handoff'

printf '%s\n' \
  '#!/usr/bin/env bash' \
  "printf 'Host *\\n  Compression yes\\n'" \
  > "${system_triggers}/pre-ssh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "printf 'Host *\\n  ServerAliveInterval 5\\n'" \
  > "${project_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh" "${project_triggers}/pre-ssh"

system_output=""
project_output=""
trigger_fire pre-ssh system_output project_output
if [[ "${system_output}" != $'Host *\n  Compression yes' \
      || "${project_output}" != $'Host *\n  ServerAliveInterval 5' ]]; then
  printf 'bounded trigger capture changed successful text output\n' >&2
  exit 1
fi

event=""
trigger_fire pre-ssh event
if [[ "${event}" != "${system_output}" ]]; then
  printf 'trigger output collided with an ordinary helper-local name\n' >&2
  exit 1
fi

rm -f -- "${project_triggers}/pre-ssh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'head -c "${VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES:?}" /dev/zero | tr "\0" x' \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
trigger_fire pre-ssh system_output
if (( ${#system_output} != VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES )); then
  printf 'trigger rejected output exactly at its byte ceiling\n' >&2
  exit 1
fi

VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES=1048576
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'head -c "${VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES:?}" /dev/zero | tr "\0" "\n"' \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
started_at=${BASH_MONOSECONDS}
trigger_fire pre-ssh system_output
elapsed=$(( BASH_MONOSECONDS - started_at ))
if [[ -n "${system_output}" ]] || (( elapsed > 2 )); then
  printf 'trailing-newline normalization exceeded the bounded processing budget\n' >&2
  exit 1
fi
VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES=64

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'head -c "$(( VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES + 1 ))" /dev/zero | tr "\0" x' \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
status=0
( trigger_fire pre-ssh system_output ) \
  >"${test_tmp}/over-limit.stdout" 2>"${test_tmp}/over-limit.stderr" \
  || status=$?
if (( status != trigger_aborted_exit_code )) \
    || ! grep -Fq 'stdout exceeded 64 bytes' "${test_tmp}/over-limit.stderr"; then
  printf 'oversized pre-trigger output was not rejected with exit 80\n' >&2
  exit 1
fi

printf '%s\n' \
  '#!/usr/bin/env bash' \
  "printf 'Host\\0 *\\n'" \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
status=0
( trigger_fire pre-ssh system_output ) 2>"${test_tmp}/nul.stderr" \
  || status=$?
if (( status != trigger_aborted_exit_code )) \
    || ! grep -Fq 'stdout contained NUL' "${test_tmp}/nul.stderr"; then
  printf 'NUL-bearing trigger output was normalized instead of rejected\n' >&2
  exit 1
fi

parent_pid_file="${test_tmp}/trigger-parent.pid"
child_pid_file="${test_tmp}/trigger-child.pid"
export TRIGGER_PARENT_PID_FILE="${parent_pid_file}"
export TRIGGER_CHILD_PID_FILE="${child_pid_file}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$$" > "${TRIGGER_PARENT_PID_FILE:?}"' \
  '(trap "" TERM; while :; do sleep 30; done) &' \
  'printf "%s\n" "$!" > "${TRIGGER_CHILD_PID_FILE:?}"' \
  'trap "" TERM' \
  'wait' \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
started_at=${BASH_MONOSECONDS}
status=0
run_trigger_guarded pre-ssh 2>"${test_tmp}/timeout.stderr" || status=$?
elapsed=$(( BASH_MONOSECONDS - started_at ))
if (( status != trigger_aborted_exit_code || elapsed > 4 )) \
    || ! grep -Fq 'timed out after 1s' "${test_tmp}/timeout.stderr"; then
  printf 'stalled pre-trigger was not terminated inside its budget\n' >&2
  exit 1
fi

for pid_file in "${parent_pid_file}" "${child_pid_file}"; do
  assert_pid_gone "${pid_file}" 'timed-out trigger'
done

retained_pid_file="${test_tmp}/retained-child.pid"
export TRIGGER_RETAINED_PID_FILE="${retained_pid_file}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '(trap "" TERM; while :; do sleep 30; done) &' \
  'printf "%s\n" "$!" > "${TRIGGER_RETAINED_PID_FILE:?}"' \
  'exit 0' \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
started_at=${BASH_MONOSECONDS}
status=0
run_trigger_guarded pre-ssh 2>"${test_tmp}/retained.stderr" || status=$?
elapsed=$(( BASH_MONOSECONDS - started_at ))
if (( status != trigger_aborted_exit_code || elapsed > 4 )) \
    || ! grep -Fq 'timed out after 1s' "${test_tmp}/retained.stderr"; then
  printf 'a child retaining stdout escaped the trigger deadline\n' >&2
  exit 1
fi
assert_pid_gone "${retained_pid_file}" 'stdout-retaining trigger child'

redirected_pid_file="${test_tmp}/redirected-child.pid"
fd_report_file="${test_tmp}/redirected-child-fds"
export TRIGGER_REDIRECTED_PID_FILE="${redirected_pid_file}"
export TRIGGER_FD_REPORT_FILE="${fd_report_file}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '(' \
  '  exec >/dev/null 2>&1' \
  '  leaked=0' \
  '  for fd in /proc/self/fd/*; do' \
  '    target="$(readlink "${fd}")" || continue' \
  '    [[ "${target}" == *" (deleted)" ]] && leaked=1' \
  '  done' \
  '  printf "%s\n" "${leaked}" > "${TRIGGER_FD_REPORT_FILE:?}"' \
  '  trap "" TERM' \
  '  while :; do sleep 30; done' \
  ') &' \
  'printf "%s\n" "$!" > "${TRIGGER_REDIRECTED_PID_FILE:?}"' \
  'for (( attempt = 0; attempt < 1000; ++attempt )); do' \
  '  [[ -s "${TRIGGER_FD_REPORT_FILE:?}" ]] && break' \
  '  sleep 0.001' \
  'done' \
  'exit 0' \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
started_at=${BASH_MONOSECONDS}
status=0
run_trigger_guarded pre-ssh 2>"${test_tmp}/redirected.stderr" || status=$?
elapsed=$(( BASH_MONOSECONDS - started_at ))
if (( status != trigger_aborted_exit_code || elapsed > 4 )) \
    || ! grep -Fq 'left descendant processes' \
      "${test_tmp}/redirected.stderr"; then
  printf 'a child redirecting stdout escaped trigger cleanup\n' >&2
  exit 1
fi
if [[ ! -s "${fd_report_file}" || "$(< "${fd_report_file}")" != 0 ]]; then
  printf 'a trigger child inherited an anonymous capture descriptor\n' >&2
  exit 1
fi
assert_pid_gone "${redirected_pid_file}" 'redirected trigger child'

handoff_pid_file="${test_tmp}/handoff-child.pid"
handoff_group_file="${test_tmp}/handoff-child.pgid"
handoff_probe_file="${test_tmp}/handoff.probe"
handoff_survived_file="${test_tmp}/handoff.survived"
export TRIGGER_HANDOFF_PID_FILE="${handoff_pid_file}"
export TRIGGER_HANDOFF_GROUP_FILE="${handoff_group_file}"
export TRIGGER_HANDOFF_PROBE_FILE="${handoff_probe_file}"
export TRIGGER_HANDOFF_SURVIVED_FILE="${handoff_survived_file}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exec </dev/null >/dev/null 2>&1' \
  'trap "" TERM HUP' \
  'process_group="$(ps -o pgid= -p "${BASHPID}")"' \
  'printf "%s\n" "${process_group//[[:space:]]/}" > "${TRIGGER_HANDOFF_GROUP_FILE:?}"' \
  'handoff() {' \
  '  if [[ -e "${TRIGGER_HANDOFF_PROBE_FILE:?}" ]]; then' \
  '    : > "${TRIGGER_HANDOFF_SURVIVED_FILE:?}"' \
  '  fi' \
  '  printf "%s\n" "${BASHPID}" > "${TRIGGER_HANDOFF_PID_FILE:?}"' \
  '  sleep 0.001' \
  '  (handoff) &' \
  '  exit 0' \
  '}' \
  'handoff' \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
started_at=${BASH_MONOSECONDS}
status=0
guarded 8 bash -c '
  set -euo pipefail
  source "${TRIGGER_TEST_REPOSITORY}/lib/virtdev/import"
  import trigger
  stop_handoff() {
    process_group="$(< "${TRIGGER_HANDOFF_GROUP_FILE:?}")"
    [[ "${process_group}" =~ ^[1-9][0-9]*$ ]] \
      && kill -KILL -- "-${process_group}" 2>/dev/null || true
  }
  output=""
  status=0
  ( trigger_fire pre-ssh output ) || status=$?
  marker_before="$(< "${TRIGGER_HANDOFF_PID_FILE:?}")"
  : > "${TRIGGER_HANDOFF_PROBE_FILE:?}"
  for (( attempt = 0; attempt < 50; ++attempt )); do
    if [[ -e "${TRIGGER_HANDOFF_SURVIVED_FILE:?}" ]]; then
      printf "fork-handoff trigger kept running after trigger_fire\n" >&2
      stop_handoff
      exit 125
    fi
    sleep 0.01
  done
  marker_after="$(< "${TRIGGER_HANDOFF_PID_FILE:?}")"
  if [[ "${marker_before}" != "${marker_after}" ]]; then
    printf "fork-handoff trigger marker kept advancing\n" >&2
    stop_handoff
    exit 125
  fi
  exit "${status}"
' 2>"${test_tmp}/handoff.stderr" || status=$?
elapsed=$(( BASH_MONOSECONDS - started_at ))
if (( status != trigger_aborted_exit_code || elapsed > 4 )) \
    || ! grep -Fq 'left descendant processes' \
      "${test_tmp}/handoff.stderr"; then
  printf 'a same-group fork handoff escaped trigger cleanup\n' >&2
  exit 1
fi
assert_pid_gone "${handoff_pid_file}" 'fork-handoff trigger child'

for native_status in 124 137; do
  if (( native_status == 124 )); then
    printf '%s\n' '#!/usr/bin/env bash' 'exit 124' \
      > "${system_triggers}/pre-ssh"
  else
    printf '%s\n' '#!/usr/bin/env bash' 'kill -KILL "$$"' \
      > "${system_triggers}/pre-ssh"
  fi
  chmod +x "${system_triggers}/pre-ssh"
  status=0
  run_trigger_guarded pre-ssh \
    2>"${test_tmp}/native-${native_status}.stderr" || status=$?
  if (( status != trigger_aborted_exit_code )) \
      || ! grep -Fq "exit ${native_status}" \
        "${test_tmp}/native-${native_status}.stderr" \
      || grep -Fq 'timed out' "${test_tmp}/native-${native_status}.stderr"; then
    printf 'native trigger exit %s was misreported as a timeout\n' \
      "${native_status}" >&2
    exit 1
  fi
done

prespawn_pid_file="${test_tmp}/prespawn-trigger.pid"
prespawn_injected_file="${test_tmp}/prespawn-trigger.injected"
export TRIGGER_PRESPAWN_PID_FILE="${prespawn_pid_file}"
export TRIGGER_PRESPAWN_INJECTED_FILE="${prespawn_injected_file}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$$" > "${TRIGGER_PRESPAWN_PID_FILE:?}"' \
  'sleep 30' \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
started_at=${BASH_MONOSECONDS}
status=0
guarded 8 bash -c '
  set -euo pipefail
  set -T
  source "${TRIGGER_TEST_REPOSITORY}/lib/virtdev/import"
  import trigger
  export VIRTDEV_TRIGGER_TIMEOUT=4
  injected=0
  inject_before_spawn() {
    if (( ! injected )) \
        && [[ "${BASH_COMMAND}" == timeout\ --signal=TERM* ]]; then
      injected=1
      trap - DEBUG
      : > "${TRIGGER_PRESPAWN_INJECTED_FILE:?}"
      kill -INT "${BASHPID}"
    fi
  }
  trap inject_before_spawn DEBUG
  output=""
  trigger_fire pre-ssh output
' 2>"${test_tmp}/prespawn.stderr" || status=$?
elapsed=$(( BASH_MONOSECONDS - started_at ))
if (( status != 130 || elapsed >= 4 )) \
    || [[ ! -e "${prespawn_injected_file}" ]]; then
  printf 'a pre-spawn signal waited for the trigger deadline\n' >&2
  cat "${test_tmp}/prespawn.stderr" >&2
  exit 1
fi
if [[ -s "${prespawn_pid_file}" ]]; then
  assert_pid_gone "${prespawn_pid_file}" 'pre-spawn-interrupted trigger'
fi

printf '%s\n' '#!/usr/bin/env bash' 'printf ok' \
  > "${system_triggers}/pre-ssh"
chmod +x "${system_triggers}/pre-ssh"
fd_count_before="$(find "/proc/${BASHPID}/fd" -mindepth 1 -maxdepth 1 | wc -l)"
for (( attempt = 0; attempt < 20; ++attempt )); do
  trigger_fire pre-ssh system_output
  [[ "${system_output}" == ok ]]
done
fd_count_after="$(find "/proc/${BASHPID}/fd" -mindepth 1 -maxdepth 1 | wc -l)"
if (( fd_count_after != fd_count_before )); then
  printf 'repeated triggers leaked file descriptors\n' >&2
  exit 1
fi

status=0
( VIRTDEV_TRIGGER_TIMEOUT=0; trigger_fire pre-ssh system_output ) \
  2>"${test_tmp}/invalid.stderr" || status=$?
if (( status != 64 )) \
    || ! grep -Fq 'Invalid VIRTDEV_TRIGGER_TIMEOUT' "${test_tmp}/invalid.stderr"; then
  printf 'invalid trigger budgets were not rejected before execution\n' >&2
  exit 1
fi

status=0
( trigger_fire pre-backup system_output ) 2>"${test_tmp}/event.stderr" \
  || status=$?
if (( status != 64 )) \
    || ! grep -Fq 'Unsupported trigger event' "${test_tmp}/event.stderr"; then
  printf 'unknown trigger event escaped the explicit event policy\n' >&2
  exit 1
fi

rm -f -- "${system_triggers}/pre-ssh"
post_pid_file="${test_tmp}/post-trigger.pid"
ssh_exit_file="${test_tmp}/post-ssh-exit"
export TRIGGER_POST_PID_FILE="${post_pid_file}"
export TRIGGER_SSH_EXIT_FILE="${ssh_exit_file}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$$" > "${TRIGGER_POST_PID_FILE:?}"' \
  'sleep 30' \
  > "${system_triggers}/post-ssh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "${VIRTDEV_SSH_EXIT:?}" > "${TRIGGER_SSH_EXIT_FILE:?}"' \
  'head -c "$(( VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES + 1 ))" /dev/zero | tr "\0" x' \
  > "${project_triggers}/post-ssh"
chmod +x "${system_triggers}/post-ssh" "${project_triggers}/post-ssh"

fixture_bin="${test_tmp}/bin"
mkdir "${fixture_bin}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ -n "${SSH_TEST_PARENT_FILE:-}" ]] && printf "%s\n" "${PPID}" > "${SSH_TEST_PARENT_FILE}"' \
  'if [[ -n "${SSH_TEST_CONFIG_FILE:-}" ]]; then' \
  '  while (( $# )); do' \
  '    if [[ "${1}" == -F ]]; then printf "%s\n" "${2}" > "${SSH_TEST_CONFIG_FILE}"; break; fi' \
  '    shift' \
  '  done' \
  'fi' \
  'exit "${SSH_TEST_STATUS:?}"' \
  > "${fixture_bin}/ssh"
chmod +x "${fixture_bin}/ssh"

export VIRTDEV_HOME="${test_tmp}/virtdev"
export VIRTDEV_SSH_KEY="${test_tmp}/id"
export SYSTEMCTL_ACTIVE_STATE=active
export SSH_TEST_STATUS=42
mkdir -p "${VIRTDEV_HOME}/projects/probe"
printf '2222\n' > "${VIRTDEV_HOME}/projects/probe/port"
printf 'test key\n' > "${VIRTDEV_SSH_KEY}"
chmod 600 "${VIRTDEV_SSH_KEY}"
(
  # shellcheck disable=SC1090
  source "${repository}/lib/virtdev/import"
  import ssh
  ssh_host_identity_ensure probe
)

started_at=${BASH_MONOSECONDS}
status=0
PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
  guarded 10 "${repository}/bin/virtdev-ssh" probe \
  >"${test_tmp}/ssh.stdout" 2>"${test_tmp}/ssh.stderr" || status=$?
elapsed=$(( BASH_MONOSECONDS - started_at ))
if (( status != SSH_TEST_STATUS || elapsed > 4 )); then
  printf 'post-trigger bounds changed SSH status or exceeded their budget\n' >&2
  exit 1
fi
if [[ "$(< "${ssh_exit_file}")" != "${SSH_TEST_STATUS}" ]] \
    || ! grep -Fq 'timed out after 1s' "${test_tmp}/ssh.stderr" \
    || ! grep -Fq 'stdout exceeded 64 bytes' "${test_tmp}/ssh.stderr"; then
  printf 'post triggers lost the primary SSH result or bounded warnings\n' >&2
  exit 1
fi

assert_pid_gone "${post_pid_file}" 'timed-out post trigger'

rm -f -- "${project_triggers}/post-ssh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$$" > "${TRIGGER_POST_PID_FILE:?}"' \
  'printf "%s\n" "${VIRTDEV_SSH_EXIT:?}" > "${TRIGGER_SSH_EXIT_FILE:?}"' \
  'trap "" INT TERM HUP' \
  'while :; do sleep 30; done' \
  > "${system_triggers}/post-ssh"
chmod +x "${system_triggers}/post-ssh"

for signal_case in INT:130 TERM:143 HUP:129; do
  signal_name="${signal_case%%:*}"
  expected_status="${signal_case##*:}"
  signal_parent_file="${test_tmp}/signal-${signal_name}.parent"
  signal_config_file="${test_tmp}/signal-${signal_name}.config"
  signal_post_file="${test_tmp}/signal-${signal_name}.post"
  signal_exit_file="${test_tmp}/signal-${signal_name}.ssh-exit"
  export SSH_TEST_PARENT_FILE="${signal_parent_file}"
  export SSH_TEST_CONFIG_FILE="${signal_config_file}"
  export TRIGGER_POST_PID_FILE="${signal_post_file}"
  export TRIGGER_SSH_EXIT_FILE="${signal_exit_file}"

  started_at=${BASH_MONOSECONDS}
  PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
    start_guarded signal_guard_pid 8 \
      "${repository}/bin/virtdev-ssh" probe \
      >"${test_tmp}/signal-${signal_name}.stdout" \
      2>"${test_tmp}/signal-${signal_name}.stderr"
  if ! wait_for_file "${signal_parent_file}" \
      || ! wait_for_file "${signal_config_file}" \
      || ! wait_for_file "${signal_post_file}"; then
    release_payload_seen=0
    release_guard "${signal_guard_pid}" release_payload_seen || true
    printf '%s signal fixture did not reach its post trigger\n' \
      "${signal_name}" >&2
    exit 1
  fi

  signal_parent_pid="$(< "${signal_parent_file}")"
  kill -s "${signal_name}" "${signal_parent_pid}"
  status=0
  wait_guarded "${signal_guard_pid}" || status=$?
  elapsed=$(( BASH_MONOSECONDS - started_at ))
  config_path="$(< "${signal_config_file}")"

  if (( status != expected_status || elapsed > 4 )) \
      || [[ -e "${config_path}" ]] \
      || [[ "$(< "${signal_exit_file}")" != "${SSH_TEST_STATUS}" ]]; then
    printf '%s during a post trigger lost status or SSH config cleanup\n' \
      "${signal_name}" >&2
    exit 1
  fi
  assert_pid_gone "${signal_post_file}" \
    "${signal_name}-interrupted post trigger"
done

if find "${TMPDIR}" -mindepth 1 -print -quit | grep -q .; then
  printf 'trigger or SSH cleanup left a temporary path behind\n' >&2
  exit 1
fi

printf 'ok - trigger stdout is valid text bounded before shell allocation\n'
printf 'ok - trigger timeouts terminate descendants and abort pre-events\n'
printf 'ok - post-trigger failures preserve the primary SSH result\n'
printf 'ok - trapped signals cannot bypass SSH cleanup\n'
