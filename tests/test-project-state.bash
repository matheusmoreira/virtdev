#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

export VIRTDEV_HOME="${test_tmp}/virtdev"
mkdir -p "${VIRTDEV_HOME}/projects/probe"
printf '0\n' > "${VIRTDEV_HOME}/projects/probe/generation"
printf '2222\n' > "${VIRTDEV_HOME}/projects/probe/port"

export PATH="${repository}/tests/fixtures:${PATH}"
# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import project

load_forwarded_state() {
  # shellcheck disable=SC2034  # consumed by name through project_load_state
  local -n forwarded_result=$1
  shift
  project_load_state forwarded_result "$@"
}

load_twice_forwarded_state() {
  # shellcheck disable=SC2034  # forwarded through load_forwarded_state
  local -n twice_forwarded_result=$1
  shift
  load_forwarded_state twice_forwarded_result "$@"
}

load_readonly_forwarded_state() {
  # shellcheck disable=SC2034  # consumed by name through project_load_state
  local -nr readonly_forwarded_result=$1
  shift
  project_load_state readonly_forwarded_result "$@"
}

assert_state() {
  local -r active_state="${1}" expected="${2}"
  export SYSTEMCTL_ACTIVE_STATE="${active_state}"
  local actual
  actual="$(project_state probe)"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'ActiveState %s mapped to %s, expected %s\n' \
      "${active_state}" "${actual}" "${expected}" >&2
    exit 1
  fi
}

assert_state active running
assert_state inactive stopped
assert_state failed stopped
assert_state activating starting
assert_state deactivating stopping
assert_state reloading unknown

export SYSTEMCTL_ACTIVE_STATE=active
if [[ "$(project_state myId)" != running ]]; then
  printf 'fixture confused a project name with a requested systemd property\n' >&2
  exit 1
fi

SYSTEMCTL_ACTIVE_STATE=activating
export SYSTEMCTL_ACTIVE_STATE
if project_is_running probe || project_is_stopped probe; then
  printf 'transitional state satisfied a terminal predicate\n' >&2
  exit 1
fi

export SYSTEMCTL_UNREACHABLE=1
if [[ "$(project_state probe)" != unknown ]] \
    || project_is_running probe || project_is_stopped probe \
    || ! project_is_unreachable probe; then
  printf 'unreachable manager did not map to fail-closed unknown state\n' >&2
  exit 1
fi
unset SYSTEMCTL_UNREACHABLE

mkdir -p "${VIRTDEV_HOME}/projects/alpha" "${VIRTDEV_HOME}/projects/beta"
state_map_file="${test_tmp}/state-map"
printf '%s\n' \
  'virtdev-alpha.service active' \
  'virtdev-beta.service deactivating' > "${state_map_file}"
export SYSTEMCTL_STATE_MAP_FILE="${state_map_file}"
declare -A loaded_states=()
project_load_state loaded_states alpha beta
if [[ "${loaded_states[alpha]}" != running \
      || "${loaded_states[beta]}" != stopping ]]; then
  printf 'batch state query lost a per-project ActiveState\n' >&2
  exit 1
fi

for result_name in \
    units project output id active_state line unit_projects \
    _project_state_result _project_state_units; do
  unset "${result_name}"
  declare -A "${result_name}=()"
  project_load_state "${result_name}" alpha beta
  declare -n result_ref="${result_name}"
  if [[ "${result_ref[alpha]}" != running \
        || "${result_ref[beta]}" != stopping ]]; then
    printf 'batch result collided with helper local: %s\n' \
      "${result_name}" >&2
    exit 1
  fi
  unset -n result_ref
  unset "${result_name}"

  declare -A "${result_name}=()"
  load_forwarded_state "${result_name}" alpha beta
  declare -n result_ref="${result_name}"
  if [[ "${result_ref[alpha]}" != running \
        || "${result_ref[beta]}" != stopping ]]; then
    printf 'forwarded batch result collided with helper local: %s\n' \
      "${result_name}" >&2
    exit 1
  fi
  unset -n result_ref
  unset "${result_name}"
done

declare -A nested_result=() readonly_alias_result=()
load_twice_forwarded_state nested_result alpha beta
load_readonly_forwarded_state readonly_alias_result alpha beta
if [[ "${nested_result[alpha]}" != running \
      || "${nested_result[beta]}" != stopping \
      || "${readonly_alias_result[alpha]}" != running \
      || "${readonly_alias_result[beta]}" != stopping ]]; then
  printf 'nested or readonly result nameref was not resolved\n' >&2
  exit 1
fi

# shellcheck disable=SC2034  # consumed by name through project_load_state
declare -n cycle_result_a=cycle_result_b cycle_result_b=cycle_result_a
status=0
project_load_state cycle_result_a alpha 2>/dev/null || status=$?
if (( status != 2 )); then
  printf 'cyclic result nameref was not bounded: status %d\n' "${status}" >&2
  exit 1
fi
status=0
FUNCNEST=16 project_load_state cycle_result_a alpha 2>/dev/null || status=$?
if (( status != 2 )); then
  printf 'FUNCNEST preempted cyclic result detection: status %d\n' \
    "${status}" >&2
  exit 1
fi
unset -n cycle_result_a cycle_result_b
unset SYSTEMCTL_STATE_MAP_FILE

export SYSTEMCTL_UNREACHABLE=1
declare -A unreachable_states=()
project_load_state unreachable_states alpha beta
if [[ "${unreachable_states[alpha]}" != unknown \
      || "${unreachable_states[beta]}" != unknown ]]; then
  printf 'batch state query hid an unreachable manager\n' >&2
  exit 1
fi
if [[ "$("${repository}/bin/virtdev-status" probe)" != unknown ]]; then
  printf 'virtdev-status hid an unreachable manager\n' >&2
  exit 1
fi
list_state="$("${repository}/bin/virtdev-list" 2>/dev/null \
  | awk '$1 == "probe" { print $3 }')"
if [[ "${list_state}" != unknown ]]; then
  printf 'virtdev-list hid an unreachable manager as %s\n' \
    "${list_state}" >&2
  exit 1
fi
unset SYSTEMCTL_UNREACHABLE

for state_case in \
    active:running inactive:stopped activating:starting \
    deactivating:stopping reloading:unknown; do
  active_state="${state_case%%:*}"
  expected="${state_case#*:}"
  export SYSTEMCTL_ACTIVE_STATE="${active_state}"
  if [[ "$("${repository}/bin/virtdev-status" probe)" != "${expected}" ]]; then
    printf 'virtdev-status hid %s as another state\n' "${active_state}" >&2
    exit 1
  fi
  list_state="$("${repository}/bin/virtdev-list" 2>/dev/null \
    | awk '$1 == "probe" { print $3 }')"
  if [[ "${list_state}" != "${expected}" ]]; then
    printf 'virtdev-list hid %s as %s\n' \
      "${active_state}" "${list_state}" >&2
    exit 1
  fi
done

printf 'ok - status exposes transitional and indeterminate runtime states\n'
printf 'ok - running and stopped predicates remain fail-closed\n'
