#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329  # imported/eval-fed test symbols

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

export PATH="${repository}/tests/fixtures:${PATH}"
# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import lifecycle

# Exercise start's exact EXIT-trap function with structured lifecycle results.
# shellcheck disable=SC2294  # deliberate evaluation of one function from the product script
eval "$(sed -n '/^cleanup_failed_start() {/,/^}/p' \
  "${repository}/bin/virtdev-start")"
terminal_write() {
  local argument
  for argument in "$@"; do
    case "${argument}" in fg=*|reset) ;; *) printf '%s' "${argument}" ;; esac
  done
}
vm_started=0
unit_submission_attempted=1
unit=virtdev-probe
project_directory="${test_tmp}/start-runtime"
VIRTDEV_STOP_TIMEOUT=1
VIRTDEV_LIFECYCLE_STOP_STATE=inactive
lifecycle_stop_and_clean_definition="$(declare -f lifecycle_stop_and_clean)"
lifecycle_stop_and_clean() { return "${lifecycle_stop_cleanup_failed}"; }
start_cleanup_output="$(cleanup_failed_start 2>&1)"
if [[ "${start_cleanup_output}" != *'VM is terminal, but runtime cleanup was incomplete.'* \
      || "${start_cleanup_output}" == *'could not prove'* \
      || "${start_cleanup_output}" == *'controls were preserved'* ]]; then
  printf 'start misdiagnosed terminal cleanup failure:\n%s\n' \
    "${start_cleanup_output}" >&2
  exit 1
fi

VIRTDEV_LIFECYCLE_STOP_STATE=unknown
lifecycle_stop_and_clean() { return "${lifecycle_stop_indeterminate}"; }
start_cleanup_output="$(cleanup_failed_start 2>&1)"
if [[ "${start_cleanup_output}" != *'could not prove the submitted VM terminal'* \
      || "${start_cleanup_output}" != *'runtime controls were preserved.'* ]]; then
  printf 'start lost its indeterminate-terminal warning:\n%s\n' \
    "${start_cleanup_output}" >&2
  exit 1
fi
# shellcheck disable=SC2294  # restore the imported function after the two stubs
eval "${lifecycle_stop_and_clean_definition}"

runtime_directory="${test_tmp}/runtime"
mkdir "${runtime_directory}"
for name in "${runtime_control_basenames[@]}"; do
  : > "${runtime_directory}/${name}"
done

publish_runtime="${test_tmp}/publish-runtime"
mkdir "${publish_runtime}"
if ! lifecycle_publish_ready "${publish_runtime}" 2222 \
    || [[ "$(< "$(runtime_port_file "${publish_runtime}")")" != 2222 \
          || -e "$(runtime_port_tmp_file "${publish_runtime}")" ]]; then
  printf 'lifecycle did not atomically publish readiness\n' >&2
  exit 1
fi
publish_status=0
lifecycle_publish_ready "${publish_runtime}" 02222 || publish_status=$?
if (( publish_status != lifecycle_publish_invalid )); then
  printf 'lifecycle accepted a noncanonical published port\n' >&2
  exit 1
fi

SYSTEMCTL_ACTIVE_STATE=activating
export SYSTEMCTL_ACTIVE_STATE
stop_status=0
lifecycle_stop_and_clean virtdev-probe "${runtime_directory}" 0 \
  || stop_status=$?
if (( stop_status != lifecycle_stop_timeout )); then
  printf 'transitional unit was incorrectly accepted as terminal\n' >&2
  exit 1
fi
for name in "${runtime_control_basenames[@]}"; do
  if [[ ! -e "${runtime_directory}/${name}" ]]; then
    printf 'runtime control %s was removed before terminal proof\n' "${name}" >&2
    exit 1
  fi
done

SYSTEMCTL_ACTIVE_STATE=inactive
export SYSTEMCTL_ACTIVE_STATE
if ! lifecycle_stop_and_clean virtdev-probe "${runtime_directory}" 0; then
  printf 'inactive unit was not accepted as terminal\n' >&2
  exit 1
fi
for name in "${runtime_control_basenames[@]}"; do
  if [[ -e "${runtime_directory}/${name}" ]]; then
    printf 'runtime control %s survived confirmed terminal cleanup\n' "${name}" >&2
    exit 1
  fi
done

malformed_runtime="${test_tmp}/malformed-runtime"
mkdir -p "${malformed_runtime}/${runtime_monitor_sock_name}"
printf 'do not delete recursively\n' \
  > "${malformed_runtime}/${runtime_monitor_sock_name}/sentinel"
for name in "${runtime_console_sock_name}" "${runtime_network_sock_name}" \
            "${runtime_legacy_passt_sock_name}" "${runtime_qmp_sock_name}" \
            "${runtime_port_name}"; do
  : > "${malformed_runtime}/${name}"
done

cleanup_status=0
lifecycle_stop_and_clean virtdev-probe "${malformed_runtime}" 0 \
  2>"${test_tmp}/cleanup.output" \
  || cleanup_status=$?
if (( cleanup_status != lifecycle_stop_cleanup_failed )) \
    || [[ "${VIRTDEV_LIFECYCLE_STOP_STATE}" != inactive ]]; then
  printf 'terminal proof and malformed cleanup were not reported separately\n' >&2
  exit 1
fi
if [[ ! -f "${malformed_runtime}/${runtime_monitor_sock_name}/sentinel" ]]; then
  printf 'runtime cleanup recursively removed an unexpected directory\n' >&2
  exit 1
fi
for name in "${runtime_console_sock_name}" "${runtime_network_sock_name}" \
            "${runtime_legacy_passt_sock_name}" "${runtime_qmp_sock_name}" \
            "${runtime_port_name}"; do
  if [[ -e "${malformed_runtime}/${name}" ]]; then
    printf 'runtime cleanup short-circuited before removing %s\n' "${name}" >&2
    exit 1
  fi
done

printf 'ok - failed-start cleanup preserves controls until terminal proof\n'
printf 'ok - runtime cleanup attempts every artifact after a local failure\n'
printf 'ok - terminal proof remains distinct from cleanup failure\n'
printf 'ok - start maps cleanup and terminal-proof failures separately\n'
printf 'ok - lifecycle readiness publication is atomic and validated\n'
