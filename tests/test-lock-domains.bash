#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
holder_pid=""

cleanup() {
  if [[ -n "${holder_pid}" ]]; then
    kill "${holder_pid}" 2>/dev/null || true
    wait "${holder_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

lock_directory="${test_tmp}/control/locks"
fixture="${repository}/tests/fixtures/lock-holder"

try_store() {
  VIRTDEV_HOME="${1}" VIRTDEV_CACHE="${2}" \
  VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
    bash "${fixture}" "${repository}" store /dev/null -
}

try_cache() {
  VIRTDEV_HOME="${1}" VIRTDEV_CACHE="${2}" \
  VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
    bash "${fixture}" "${repository}" cache /dev/null -
}

start_holder() {
  local -r domain="${1}" home="${2}" cache="${3}" ready="${4}" release="${5}"
  rm -f -- "${ready}" "${release}"
  VIRTDEV_HOME="${home}" VIRTDEV_CACHE="${cache}" \
  VIRTDEV_LOCK_DIRECTORY="${lock_directory}" \
  LOCK_FIXTURE_RECORD_BYTES="${LOCK_FIXTURE_RECORD_BYTES:-}" \
    bash "${fixture}" "${repository}" "${domain}" "${ready}" "${release}" &
  holder_pid=$!

  local _
  for _ in {1..200}; do
    [[ -e "${ready}" ]] && return 0
    if ! kill -0 "${holder_pid}" 2>/dev/null; then
      wait "${holder_pid}" || true
      printf 'lock holder exited before publishing readiness\n' >&2
      exit 1
    fi
    sleep 0.025
  done
  printf 'lock holder did not become ready\n' >&2
  exit 1
}

release_holder() {
  local -r release="${1}"
  : > "${release}"
  wait "${holder_pid}"
  holder_pid=""
}

home_a="${test_tmp}/stores/a"
home_b="${test_tmp}/stores/b"
cache_a="${test_tmp}/caches/a"
mkdir -p "${home_a}" "${home_b}" "${cache_a}"

ready="${test_tmp}/ready"
release="${test_tmp}/release"
start_holder store "${home_a}" "${cache_a}" "${ready}" "${release}"
rm -rf -- "${home_a}"

status=0
try_store "${home_a}" "${cache_a}" >"${test_tmp}/contended" 2>&1 || status=$?
if (( status != 75 )); then
  printf 'store deletion split the lock rendezvous (status %d)\n' "${status}" >&2
  cat "${test_tmp}/contended" >&2
  exit 1
fi
release_holder "${release}"
try_store "${home_a}" "${cache_a}"

start_holder store "${home_a}" "${cache_a}" "${ready}" "${release}"
try_store "${home_b}" "${cache_a}"
release_holder "${release}"

real_home="${test_tmp}/canonical/store"
alias_home="${test_tmp}/store-alias"
mkdir -p "${real_home}"
ln -s "${real_home}" "${alias_home}"
start_holder store "${real_home}" "${cache_a}" "${ready}" "${release}"
status=0
try_store "${alias_home}" "${cache_a}" >"${test_tmp}/alias" 2>&1 || status=$?
(( status == 75 ))
release_holder "${release}"

# A composed child reuses both inherited store descriptors.
(
  export VIRTDEV_HOME="${alias_home}" VIRTDEV_CACHE="${cache_a}"
  export VIRTDEV_LOCK_DIRECTORY="${lock_directory}"
  # shellcheck disable=SC1091
  source "${repository}/lib/virtdev/import"
  import lock
  lock_acquire
  bash "${fixture}" "${repository}" store "${test_tmp}/child-ready" -
)
[[ -e "${test_tmp}/child-ready" ]]

start_holder cache "${home_a}" "${cache_a}" "${ready}" "${release}"
status=0
try_cache "${home_a}" "${cache_a}" >"${test_tmp}/cache" 2>&1 || status=$?
(( status == 75 ))
try_store "${home_a}" "${cache_a}"
release_holder "${release}"

# Malformed holder state is rejected from metadata before any shell allocation.
LOCK_FIXTURE_RECORD_BYTES=1073741824
export LOCK_FIXTURE_RECORD_BYTES
start_holder store "${home_a}" "${cache_a}" "${ready}" "${release}"
status=0
try_store "${home_a}" "${cache_a}" >"${test_tmp}/oversize" 2>&1 || status=$?
(( status == 75 ))
grep -Fq 'Holder PID: unknown' "${test_tmp}/oversize"
(( $(wc -c < "${test_tmp}/oversize") < 2048 ))
release_holder "${release}"
unset LOCK_FIXTURE_RECORD_BYTES

unsafe_directory="${test_tmp}/unsafe-locks"
mkdir -p "${unsafe_directory}"
ln -s "${unsafe_directory}" "${test_tmp}/unsafe-link"
status=0
VIRTDEV_HOME="${home_b}" VIRTDEV_CACHE="${cache_a}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/unsafe-link" \
  bash "${fixture}" "${repository}" store "${test_tmp}/unsafe-ready" - \
  >"${test_tmp}/unsafe" 2>&1 || status=$?
(( status == 76 ))

for script in virtdev-recreate virtdev-upgrade; do
  grep -Eq '^import .* lock($| )' "${repository}/bin/${script}"
  grep -Fq 'lock_acquire' "${repository}/bin/${script}"
done
grep -Fq 'lock_acquire_cache' "${repository}/bin/virtdev-iso"
grep -Fq 'lock_acquire_cache' "${repository}/bin/virtdev-nuke"

printf 'ok - stable store/cache locks serialize deletion and composed commands\n'
