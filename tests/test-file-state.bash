#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
gate_pid=''
gate_release=''
cleanup() {
  [[ -z "${gate_release}" ]] || : > "${gate_release}"
  [[ -z "${gate_pid}" ]] || wait "${gate_pid}" 2>/dev/null || true
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

helper="${repository}/libexec/virtdev/virtdev-file-state"
[[ -x "${helper}" ]] || {
  printf 'virtdev-file-state is not built\n' >&2
  exit 1
}

source_file="${test_tmp}/source"
printf 'payload\n' > "${source_file}"
touch -d '@1700000000.123456789' -- "${source_file}"
mtime_text="$(stat -c '%y' -- "${source_file}")"
ctime_text="$(stat -c '%z' -- "${source_file}")"
mtime_nsec="${mtime_text#*.}"
mtime_nsec="${mtime_nsec%% *}"
ctime_nsec="${ctime_text#*.}"
ctime_nsec="${ctime_nsec%% *}"
mtime_nsec="$((10#${mtime_nsec}))"
ctime_nsec="$((10#${ctime_nsec}))"
digest="$(sha256sum -- "${source_file}")"
digest="${digest%% *}"
expected="$(stat -c '%d %i %f %u %g %h %s %Y' -- "${source_file}")"
expected+=" ${mtime_nsec} $(stat -c '%Z' -- "${source_file}")"
expected+=" ${ctime_nsec} ${digest}"
actual="$("${helper}" "${source_file}" 8)"
if [[ "${actual}" != "${expected}" ]]; then
  printf 'file-state output did not match exact descriptor metadata\n' >&2
  printf 'expected: %s\nactual:   %s\n' "${expected}" "${actual}" >&2
  exit 1
fi

empty_file="${test_tmp}/empty"
: > "${empty_file}"
empty_output="$("${helper}" "${empty_file}" 0)"
empty_digest="$(sha256sum -- "${empty_file}")"
[[ "${empty_output##* }" == "${empty_digest%% *}" ]]

status=0
"${helper}" "${source_file}" 7 >"${test_tmp}/limit.stdout" \
  2>"${test_tmp}/limit.stderr" || status=$?
if (( status != 44 )) || [[ -s "${test_tmp}/limit.stdout" ]]; then
  printf 'file-state did not enforce its byte limit (status %d)\n' \
    "${status}" >&2
  exit 1
fi

mkdir "${test_tmp}/directory"
ln -s source "${test_tmp}/symlink"
mkfifo "${test_tmp}/fifo"
for unsupported in directory symlink fifo; do
  status=0
  timeout 2 "${helper}" "${test_tmp}/${unsupported}" 8 \
    >"${test_tmp}/${unsupported}.stdout" \
    2>"${test_tmp}/${unsupported}.stderr" || status=$?
  if (( status != 1 )) || [[ -s "${test_tmp}/${unsupported}.stdout" ]]; then
    printf 'file-state accepted or blocked on %s (status %d)\n' \
      "${unsupported}" "${status}" >&2
    exit 1
  fi
done

for invalid_case in missing invalid extra; do
  status=0
  case "${invalid_case}" in
    missing) "${helper}" >"${test_tmp}/usage.stdout" 2>/dev/null || status=$? ;;
    invalid) "${helper}" "${source_file}" nope >"${test_tmp}/usage.stdout" 2>/dev/null || status=$? ;;
    extra) "${helper}" "${source_file}" 8 extra >"${test_tmp}/usage.stdout" 2>/dev/null || status=$? ;;
  esac
  if (( status != 64 )) || [[ -s "${test_tmp}/usage.stdout" ]]; then
    printf 'file-state usage failure returned %d for %s\n' \
      "${status}" "${invalid_case}" >&2
    exit 1
  fi
done

gate_library="${test_tmp}/file-state-gate.so"
cc -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -fPIC -shared \
  -o "${gate_library}" "${repository}/tests/support/file-state-gate.c"
mutation_file="${test_tmp}/mutation"
head -c 262144 /dev/zero | tr '\0' a > "${mutation_file}"
gate_ready="${test_tmp}/gate.ready"
gate_release="${test_tmp}/gate.release"
gate_status="${test_tmp}/gate.status"
(
  status=0
  LD_PRELOAD="${gate_library}" FILE_STATE_GATE_SKIP=1 \
    FILE_STATE_GATE_READY="${gate_ready}" \
    FILE_STATE_GATE_RELEASE="${gate_release}" \
    "${helper}" "${mutation_file}" 262144 \
      >"${test_tmp}/mutation.stdout" 2>"${test_tmp}/mutation.stderr" \
      || status=$?
  printf '%d\n' "${status}" > "${gate_status}"
) &
gate_pid=$!
for _ in {1..1000}; do
  [[ -e "${gate_ready}" ]] && break
  kill -0 "${gate_pid}" 2>/dev/null || break
  sleep 0.01
done
if [[ ! -e "${gate_ready}" ]]; then
  printf 'file-state mutation gate did not become ready\n' >&2
  exit 1
fi
head -c 262144 /dev/zero | tr '\0' b > "${mutation_file}"
: > "${gate_release}"
wait "${gate_pid}"
gate_pid=''
if [[ "$(< "${gate_status}")" != 47 \
      || -s "${test_tmp}/mutation.stdout" ]]; then
  printf 'file-state did not reject a mutation during hashing\n' >&2
  exit 1
fi

printf 'ok - regular-file state is exact, bounded, and mutation-detecting\n'
