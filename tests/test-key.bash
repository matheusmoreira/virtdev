#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

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

printf 'ok - key setup validates and repairs the complete ed25519 pair\n'
