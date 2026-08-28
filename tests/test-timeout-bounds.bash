#!/usr/bin/env bash
# shellcheck disable=SC2154  # lifecycle discriminants provided by import

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import integer ssh lifecycle qmp

for value in 1 86400; do
  integer_is_bounded_positive "${value}" 86400 || {
    printf 'bounded integer rejected %s\n' "${value}" >&2
    exit 1
  }
done
for value in 0 01 86401 -1 +1 999999999999999999999999999999999999; do
  if integer_is_bounded_positive "${value}" 86400; then
    printf 'bounded integer accepted %s\n' "${value}" >&2
    exit 1
  fi
done

huge=999999999999999999999999999999999999
for command in start stop wait maintain; do
  variable=VIRTDEV_WAIT_TIMEOUT
  [[ "${command}" == start || "${command}" == stop ]] \
    && variable=VIRTDEV_STOP_TIMEOUT
  status=0
  env NO_COLOR=1 VIRTDEV_HOME="${test_tmp}/home" "${variable}=${huge}" \
    "${repository}/bin/virtdev-${command}" \
    >"${test_tmp}/output" 2>&1 || status=$?
  if (( status != 64 )) || ! grep -Fq '1 through 86400' "${test_tmp}/output"; then
    printf '%s did not reject an overflowing timeout (status %d)\n' \
      "${command}" "${status}" >&2
    cat "${test_tmp}/output" >&2
    exit 1
  fi
done

status=0
NO_COLOR=1 VIRTDEV_HOME="${test_tmp}/home" \
VIRTDEV_INSTALL_SOCKET_TIMEOUT="${huge}" \
  "${repository}/bin/virtdev-install" \
  >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 14 )); then
  printf 'install did not reject an overflowing timeout (status %d)\n' \
    "${status}" >&2
  exit 1
fi

if ssh_poll_until_ready key 2222 unit "${huge}" \
    || lifecycle_stop_and_clean unit "${test_tmp}" "${huge}" \
    || qmp_query_running "${test_tmp}/missing.sock" "${huge}" \
    || qmp_wait_shutdown "${test_tmp}/missing.sock" "${huge}" unit \
    || qmp_quit "${test_tmp}/missing.sock" "${huge}"; then
  printf 'a deadline library accepted an overflowing timeout\n' >&2
  exit 1
fi
classification=0
lifecycle_wait_active unit "${test_tmp}" "${huge}" \
  || classification=$?
if (( classification != lifecycle_invalid )); then
  printf 'lifecycle classifier did not reject an overflowing timeout\n' >&2
  exit 1
fi

printf 'ok - timeout arithmetic accepts only canonical values through 86400\n'
