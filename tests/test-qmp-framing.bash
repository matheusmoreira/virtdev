#!/usr/bin/env bash
# shellcheck disable=SC2154  # reply ceiling is provided by the qmp library

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
listener_pids=()
cleanup() {
  local pid
  for pid in "${listener_pids[@]}"; do
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

# shellcheck disable=SC1090,SC1091
source "${repository}/lib/virtdev/import"
import qmp

start_qmp_server() {
  local -r mode="${1}" sock="${2}"
  QMP_TEST_MODE="${mode}" \
    socat UNIX-LISTEN:"${sock}",fork \
      EXEC:"${repository}/tests/fixtures/qmp-framing-server" \
      >/dev/null 2>&1 &
  listener_pids+=("$!")
  local attempt
  for (( attempt = 0; attempt < 100; ++attempt )); do
    [[ -S "${sock}" ]] && return 0
    sleep 0.01
  done
  return 1
}

exchange_status=0
exchange_reply=""
run_running_exchange() {
  local -r mode="${1}"
  local -r sock="${test_tmp}/${mode}.sock"
  start_qmp_server "${mode}" "${sock}"
  exchange_status=0
  exchange_reply="$(_qmp_exchange "${sock}" 2 virtdev-query-running \
    '{"execute":"query-status","id":"virtdev-query-running"}')" \
    || exchange_status=$?
}

running_sock="${test_tmp}/running.sock"
if ! start_qmp_server running "${running_sock}" \
    || ! qmp_query_running "${running_sock}" 2; then
  printf 'correlated running response was rejected\n' >&2
  exit 1
fi

mismatch_sock="${test_tmp}/mismatch.sock"
start_qmp_server mismatched "${mismatch_sock}"
if qmp_query_running "${mismatch_sock}" 1; then
  printf 'running state from an unrelated QMP response was accepted\n' >&2
  exit 1
fi

nested_running_sock="${test_tmp}/nested-running.sock"
start_qmp_server nested-running "${nested_running_sock}"
if qmp_query_running "${nested_running_sock}" 1; then
  printf 'running state from a nested QMP event was accepted\n' >&2
  exit 1
fi

event_before_running_sock="${test_tmp}/event-before-running.sock"
start_qmp_server event-before-running "${event_before_running_sock}"
if ! qmp_query_running "${event_before_running_sock}" 2; then
  printf 'correlated response after a nested QMP event was rejected\n' >&2
  exit 1
fi

nested_shutdown_sock="${test_tmp}/nested-shutdown.sock"
start_qmp_server nested-shutdown "${nested_shutdown_sock}"
if _qmp_query_shutdown_once "${nested_shutdown_sock}" 1; then
  printf 'shutdown state from a nested QMP event was accepted\n' >&2
  exit 1
fi

nested_quit_sock="${test_tmp}/nested-quit.sock"
start_qmp_server nested-quit "${nested_quit_sock}"
if qmp_quit "${nested_quit_sock}" 1; then
  printf 'quit acknowledgement from a nested QMP event was accepted\n' >&2
  exit 1
fi

for nul_mode in nul-token nul-id nul-prefix; do
  run_running_exchange "${nul_mode}"
  if (( exchange_status == 0 )); then
    printf 'QMP exchange accepted raw NUL input in mode %s\n' \
      "${nul_mode}" >&2
    exit 1
  fi
done

run_running_exchange exact-cap
if (( exchange_status != 0 || ${#exchange_reply} != _qmp_reply_max_bytes - 1 )); then
  printf 'exact-cap QMP reply returned status %d with %d captured bytes\n' \
    "${exchange_status}" "${#exchange_reply}" >&2
  exit 1
fi

for rejected_mode in cap-plus-one oversized; do
  run_running_exchange "${rejected_mode}"
  if (( exchange_status == 0 || ${#exchange_reply} != _qmp_reply_max_bytes )); then
    printf '%s QMP reply returned status %d with %d captured bytes\n' \
      "${rejected_mode}" "${exchange_status}" "${#exchange_reply}" >&2
    exit 1
  fi
done

for rejected_frame_mode in eof-partial fragmented-eof multi-value; do
  run_running_exchange "${rejected_frame_mode}"
  if (( exchange_status == 0 )); then
    printf 'QMP exchange accepted invalid or incomplete frame in mode %s\n' \
      "${rejected_frame_mode}" >&2
    exit 1
  fi
done

for complete_mode in crlf fragmented; do
  run_running_exchange "${complete_mode}"
  if (( exchange_status != 0 )); then
    printf 'QMP exchange rejected complete frame in mode %s\n' \
      "${complete_mode}" >&2
    exit 1
  fi
done

stderr_capture="${test_tmp}/exchange.stderr"
{
  _qmp_exchange "${running_sock}" 1 virtdev-query-running \
    '{"execute":"query-status","id":"virtdev-query-running"}' \
    >/dev/null
  printf 'stderr-still-open\n' >&2
} 2> "${stderr_capture}"
if ! grep -Fxq stderr-still-open "${stderr_capture}"; then
  printf 'QMP exchange persistently redirected caller stderr\n' >&2
  exit 1
fi

printf 'ok - QMP state comes only from a correlated top-level response\n'
printf 'ok - raw NUL input is rejected before Bash can normalize it\n'
printf 'ok - QMP framing handles byte ceilings, CRLF, fragmentation, and EOF\n'
printf 'ok - QMP cleanup preserves the caller stderr descriptor\n'
