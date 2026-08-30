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

key_pair_matches() {
  local -r private_key="${1}"
  local derived_type derived_blob _ public_key

  read -r derived_type derived_blob _ \
    < <(ssh-keygen -y -P '' -f "${private_key}") || return
  public_key="$(awk 'NR == 1 { print $1 " " $2 }' "${private_key}.pub")" \
    || return
  [[ "${public_key}" == "${derived_type} ${derived_blob}" ]]
}

sync_bin="${test_tmp}/sync-bin"
mv_bin="${test_tmp}/mv-bin"
mkdir "${sync_bin}" "${mv_bin}"
ln -s "${repository}/tests/fixtures/sync-target-state-fail" \
  "${sync_bin}/sync"
ln -s "${repository}/tests/fixtures/mv-rename-then-fail" "${mv_bin}/mv"

private_fault_home="${test_tmp}/private-fault-home"
private_fault_key="${test_tmp}/external-private-key/id"
private_fault_once="${test_tmp}/private-fault.once"
status=0
SYNC_FAIL_TARGET="$(dirname "${private_fault_key}")" \
SYNC_FAIL_IF_ABSENT="${private_fault_key}.pub" \
SYNC_FAIL_ONCE_FILE="${private_fault_once}" \
PATH="${sync_bin}:${PATH}" \
VIRTDEV_HOME="${private_fault_home}" VIRTDEV_SSH_KEY="${private_fault_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1 || status=$?
if (( status != 6 )) || [[ ! -f "${private_fault_key}" \
      || -e "${private_fault_key}.pub" \
      || ! -e "${private_fault_once}" ]]; then
  printf 'private-key publication uncertainty was not preserved (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq 'SSH private key was published' "${output}"
grep -Fq 'The published file was preserved' "${output}"

SYNC_FAIL_TARGET="$(dirname "${private_fault_key}")" \
SYNC_FAIL_IF_ABSENT="${private_fault_key}.pub" \
SYNC_FAIL_ONCE_FILE="${private_fault_once}" \
PATH="${sync_bin}:${PATH}" \
VIRTDEV_HOME="${private_fault_home}" VIRTDEV_SSH_KEY="${private_fault_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1
if ! key_pair_matches "${private_fault_key}"; then
  printf 'private-key durability retry did not publish a complete pair\n' >&2
  cat "${output}" >&2
  exit 1
fi

public_fault_home="${test_tmp}/public-fault-home"
public_fault_key="${test_tmp}/external-public-key/id"
public_fault_once="${test_tmp}/public-fault.once"
status=0
SYNC_FAIL_TARGET="$(dirname "${public_fault_key}")" \
SYNC_FAIL_IF_PRESENT="${public_fault_key}.pub" \
SYNC_FAIL_ONCE_FILE="${public_fault_once}" \
PATH="${sync_bin}:${PATH}" \
VIRTDEV_HOME="${public_fault_home}" VIRTDEV_SSH_KEY="${public_fault_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1 || status=$?
if (( status != 6 )) || [[ ! -f "${public_fault_key}" \
      || ! -f "${public_fault_key}.pub" \
      || ! -e "${public_fault_once}" ]]; then
  printf 'public-key publication uncertainty was not preserved (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq 'SSH public key was published' "${output}"
grep -Fq 'The published file was preserved' "${output}"

SYNC_FAIL_TARGET="$(dirname "${public_fault_key}")" \
SYNC_FAIL_IF_PRESENT="${public_fault_key}.pub" \
SYNC_FAIL_ONCE_FILE="${public_fault_once}" \
PATH="${sync_bin}:${PATH}" \
VIRTDEV_HOME="${public_fault_home}" VIRTDEV_SSH_KEY="${public_fault_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1
if ! key_pair_matches "${public_fault_key}"; then
  printf 'matching-pair retry did not close publication uncertainty\n' >&2
  cat "${output}" >&2
  exit 1
fi

private_rename_home="${test_tmp}/private-rename-home"
private_rename_key="${test_tmp}/external-private-rename/id"
private_rename_once="${test_tmp}/private-rename.once"
status=0
MV_RENAME_THEN_FAIL_TARGET="${private_rename_key}" \
MV_RENAME_THEN_FAIL_ONCE_FILE="${private_rename_once}" \
PATH="${mv_bin}:${PATH}" \
VIRTDEV_HOME="${private_rename_home}" VIRTDEV_SSH_KEY="${private_rename_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1 || status=$?
if (( status != 6 )) || [[ ! -f "${private_rename_key}" \
      || -e "${private_rename_key}.pub" \
      || ! -e "${private_rename_once}" ]]; then
  printf 'private-key after-rename uncertainty lost its destination (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
private_rename_digest="$(sha256sum "${private_rename_key}")"

MV_RENAME_THEN_FAIL_TARGET="${private_rename_key}" \
MV_RENAME_THEN_FAIL_ONCE_FILE="${private_rename_once}" \
PATH="${mv_bin}:${PATH}" \
VIRTDEV_HOME="${private_rename_home}" VIRTDEV_SSH_KEY="${private_rename_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1
if [[ "$(sha256sum "${private_rename_key}")" != "${private_rename_digest}" ]] \
    || ! key_pair_matches "${private_rename_key}"; then
  printf 'private-key after-rename retry did not preserve and complete the pair\n' \
    >&2
  cat "${output}" >&2
  exit 1
fi

public_rename_home="${test_tmp}/public-rename-home"
public_rename_key="${test_tmp}/external-public-rename/id"
public_rename_once="${test_tmp}/public-rename.once"
status=0
MV_RENAME_THEN_FAIL_TARGET="${public_rename_key}.pub" \
MV_RENAME_THEN_FAIL_ONCE_FILE="${public_rename_once}" \
PATH="${mv_bin}:${PATH}" \
VIRTDEV_HOME="${public_rename_home}" VIRTDEV_SSH_KEY="${public_rename_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1 || status=$?
if (( status != 6 )) || [[ ! -f "${public_rename_key}" \
      || ! -f "${public_rename_key}.pub" \
      || ! -e "${public_rename_once}" ]]; then
  printf 'public-key after-rename uncertainty lost its destination (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
public_rename_private_digest="$(sha256sum "${public_rename_key}")"
public_rename_digest="$(sha256sum "${public_rename_key}.pub")"

MV_RENAME_THEN_FAIL_TARGET="${public_rename_key}.pub" \
MV_RENAME_THEN_FAIL_ONCE_FILE="${public_rename_once}" \
PATH="${mv_bin}:${PATH}" \
VIRTDEV_HOME="${public_rename_home}" VIRTDEV_SSH_KEY="${public_rename_key}" \
  "${repository}/bin/virtdev-key" >"${output}" 2>&1
if [[ "$(sha256sum "${public_rename_key}")" \
      != "${public_rename_private_digest}" \
      || "$(sha256sum "${public_rename_key}.pub")" \
      != "${public_rename_digest}" ]] \
    || ! key_pair_matches "${public_rename_key}"; then
  printf 'public-key after-rename retry did not preserve the valid pair\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - key setup validates, repairs, and durably publishes the ed25519 pair\n'
printf 'ok - key publication preserves and retries after rename uncertainty\n'
