#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"

# shellcheck disable=SC1090,SC1091
source "${repository}/lib/virtdev/import"
import qmp

shutdown_reply='{"return":{"status":"shutdown","singlestep":false,"running":false},"id":"virtdev-query-shutdown"}'
running_reply='{"return":{"status":"running","singlestep":false,"running":true},"id":"virtdev-query-shutdown"}'

if ! _qmp_reply_is_shutdown "${shutdown_reply}"; then
  printf 'valid QMP shutdown state was rejected\n' >&2
  exit 1
fi
if _qmp_reply_is_shutdown "${running_reply}" \
    || _qmp_reply_is_shutdown '{"status":"shutdown","running":true}' \
    || _qmp_reply_is_shutdown '{"status":"shutdown"}'; then
  printf 'non-shutdown or partial QMP state was accepted\n' >&2
  exit 1
fi

fake_unit_state=active
fake_shutdown=1
query_calls=0
query_timeout=0

systemctl() {
  printf '%s\n' "${fake_unit_state}"
}

_qmp_query_shutdown_once() {
  (( ++query_calls ))
  query_timeout="${2}"
  (( fake_shutdown ))
}

qmp_wait_shutdown /unused 1 virtdev-maintenance
if [[ "${VIRTDEV_QMP_WAIT_STATE}" != shutdown || query_calls -ne 1 \
      || query_timeout -ne 1 ]]; then
  printf 'positive QMP state did not produce shutdown proof\n' >&2
  exit 1
fi

fake_unit_state=inactive
query_calls=0
status=0
qmp_wait_shutdown /unused 1 virtdev-maintenance || status=$?
if (( status == 0 )) || [[ "${VIRTDEV_QMP_WAIT_STATE}" != terminal ]] \
    || (( query_calls != 0 )); then
  printf 'direct unit exit was mistaken for guest shutdown proof\n' >&2
  exit 1
fi

for uncertain_case in 'manager-unreachable:' 'nonterminal:deactivating'; do
  expected_state="${uncertain_case%%:*}"
  fake_unit_state="${uncertain_case#*:}"
  query_calls=0
  status=0
  qmp_wait_shutdown /unused 1 virtdev-maintenance || status=$?
  if (( status == 0 )) || [[ "${VIRTDEV_QMP_WAIT_STATE}" != "${expected_state}" ]] \
      || (( query_calls != 0 )); then
    printf 'unit state %q did not fail closed as %s\n' \
      "${fake_unit_state}" "${expected_state}" >&2
    exit 1
  fi
done

fake_unit_state=active
fake_shutdown=0
status=0
qmp_wait_shutdown /unused 1 virtdev-maintenance || status=$?
if (( status == 0 )) || [[ "${VIRTDEV_QMP_WAIT_STATE}" != timeout ]]; then
  printf 'missing shutdown state did not end as a bounded timeout\n' >&2
  exit 1
fi

# shellcheck disable=SC2329  # qmp_quit resolves this override dynamically
_qmp_exchange() {
  printf '%s\n' '{"return":{},"id":"virtdev-quit"}'
}
if ! qmp_quit /unused 1; then
  printf 'command-specific QMP quit acknowledgement was rejected\n' >&2
  exit 1
fi

# shellcheck disable=SC2329  # qmp_quit resolves this override dynamically
_qmp_exchange() {
  printf '%s\n' '{"error":{"class":"GenericError"},"id":"virtdev-quit"}'
}
if qmp_quit /unused 1; then
  printf 'QMP quit error was accepted as an acknowledgement\n' >&2
  exit 1
fi

printf 'ok - maintenance shutdown requires positive QMP state before QEMU quit\n'
printf 'ok - QMP wait fails closed on indeterminate manager states\n'
