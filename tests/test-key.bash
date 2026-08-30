#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT
export VIRTDEV_LOCK_DIRECTORY="${test_tmp}/locks"

virtdev_home="${test_tmp}/virtdev"
key="${virtdev_home}/ssh/id"
output="${test_tmp}/output"

VIRTDEV_HOME="${virtdev_home}" VIRTDEV_SSH_KEY="${key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1

if [[ ! -f "${key}" || ! -f "${key}.pub" ]]; then
  printf 'key command did not create a complete pair\n' >&2
  cat "${output}" >&2
  exit 1
fi
read -r derived_type derived_blob _ < <(ssh-keygen -y -P '' -f "${key}")
derived="${derived_type} ${derived_blob}"
public_core="$(awk 'NR == 1 { print $1 " " $2 }' "${key}.pub")"
if [[ "${public_core}" != "${derived}" ]]; then
  printf 'new public key does not match its private key\n' >&2
  exit 1
fi

rm "${key}.pub"
VIRTDEV_HOME="${virtdev_home}" VIRTDEV_SSH_KEY="${key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1
if [[ "$(awk 'NR == 1 { print $1 " " $2 }' "${key}.pub")" != "${derived}" ]]; then
  printf 'missing public key was not repaired\n' >&2
  exit 1
fi

other="${test_tmp}/other"
ssh-keygen -q -t ed25519 -N '' -f "${other}"
cp "${other}.pub" "${key}.pub"
chmod 644 "${key}"
VIRTDEV_HOME="${virtdev_home}" VIRTDEV_SSH_KEY="${key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1
if [[ "$(awk 'NR == 1 { print $1 " " $2 }' "${key}.pub")" != "${derived}" ]]; then
  printf 'mismatched public key was not repaired\n' >&2
  exit 1
fi
if [[ "$(stat -c '%a' "${key}")" != 600 ]]; then
  printf 'existing private-key permissions were not hardened\n' >&2
  exit 1
fi

bad_home="${test_tmp}/bad-home"
mkdir -p "${bad_home}/ssh"
printf 'not a key\n' > "${bad_home}/ssh/id"
chmod 600 "${bad_home}/ssh/id"
status=0
VIRTDEV_HOME="${bad_home}" VIRTDEV_SSH_KEY="${bad_home}/ssh/id" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1 || status=$?
if (( status != 3 )); then
  printf 'expected invalid-private-key exit 3, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

sync_bin="${test_tmp}/sync-bin"
mkdir "${sync_bin}"
ln -s "${repository}/tests/fixtures/sync-counted" "${sync_bin}/sync"

private_fault_home="${test_tmp}/private-fault-home"
private_fault_key="${test_tmp}/external-private-key/id"
private_fault_count="${test_tmp}/private-fault.count"
status=0
SYNC_COUNT_FILE="${private_fault_count}" SYNC_FAIL_CALL=2 \
PATH="${sync_bin}:${PATH}" \
VIRTDEV_HOME="${private_fault_home}" VIRTDEV_SSH_KEY="${private_fault_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1 || status=$?
if (( status != 6 )) || [[ ! -f "${private_fault_key}" \
      || -e "${private_fault_key}.pub" ]]; then
  printf 'private-key publication uncertainty was not preserved (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq 'SSH private key was published' "${output}"
grep -Fq 'The published file was preserved' "${output}"

rm -f -- "${private_fault_count}"
SYNC_COUNT_FILE="${private_fault_count}" \
PATH="${sync_bin}:${PATH}" \
VIRTDEV_HOME="${private_fault_home}" VIRTDEV_SSH_KEY="${private_fault_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1
if [[ "$(< "${private_fault_count}")" != 3 \
      || ! -f "${private_fault_key}.pub" ]]; then
  printf 'private-key durability retry did not publish a complete pair\n' >&2
  cat "${output}" >&2
  exit 1
fi

public_fault_home="${test_tmp}/public-fault-home"
public_fault_key="${test_tmp}/external-public-key/id"
public_fault_count="${test_tmp}/public-fault.count"
status=0
SYNC_COUNT_FILE="${public_fault_count}" SYNC_FAIL_CALL=4 \
PATH="${sync_bin}:${PATH}" \
VIRTDEV_HOME="${public_fault_home}" VIRTDEV_SSH_KEY="${public_fault_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1 || status=$?
if (( status != 6 )) || [[ ! -f "${public_fault_key}" \
      || ! -f "${public_fault_key}.pub" ]]; then
  printf 'public-key publication uncertainty was not preserved (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq 'SSH public key was published' "${output}"
grep -Fq 'The published file was preserved' "${output}"

rm -f -- "${public_fault_count}"
SYNC_COUNT_FILE="${public_fault_count}" \
PATH="${sync_bin}:${PATH}" \
VIRTDEV_HOME="${public_fault_home}" VIRTDEV_SSH_KEY="${public_fault_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1
if [[ "$(< "${public_fault_count}")" != 1 ]]; then
  printf 'matching-pair retry did not close publication uncertainty\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - key setup validates, repairs, and durably publishes the ed25519 pair\n'
