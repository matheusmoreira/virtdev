#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

output="${test_tmp}/output"
status=0
VIRTDEV_PACKAGES="${test_tmp}/missing-packages" \
  "${repository}/bin/virtdev-install" >"${output}" 2>&1 || status=$?

if (( status != 11 )); then
  printf 'expected missing-packages exit 11, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if ! grep -Fq 'Packages file not found or not readable' "${output}"; then
  printf 'missing explicit-input diagnostic\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - installer rejects a missing explicit customization file\n'

fixture_bin="${test_tmp}/bin"
mkdir -p "${fixture_bin}"
printf '#!/usr/bin/env bash\nexit 0\n' > "${fixture_bin}/socat"
chmod +x "${fixture_bin}/socat"

ssh_key="${test_tmp}/id"
ssh-keygen -q -t ed25519 -N '' -C '' -f "${ssh_key}"

custom_cache="${test_tmp}/relocated-cache"
status=0
PATH="${fixture_bin}:${PATH}" \
  VIRTDEV_HOME="${test_tmp}/home" \
  VIRTDEV_CACHE="${custom_cache}" \
  VIRTDEV_SSH_KEY="${ssh_key}" \
  "${repository}/bin/virtdev-install" >"${output}" 2>&1 || status=$?

if (( status != 3 )); then
  printf 'expected missing default ISO exit 3, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if ! grep -Fq "ISO not found: '${custom_cache}/virtdev.iso'" "${output}"; then
  printf 'installer did not derive its ISO from VIRTDEV_CACHE\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - installer derives its default ISO from VIRTDEV_CACHE\n'

other_key="${test_tmp}/other-id"
ssh-keygen -q -t ed25519 -N '' -C '' -f "${other_key}"
cp "${other_key}.pub" "${ssh_key}.pub"
mismatch_home="${test_tmp}/mismatch-home"
status=0
PATH="${fixture_bin}:${PATH}" \
  VIRTDEV_HOME="${mismatch_home}" \
  VIRTDEV_SSH_KEY="${ssh_key}" \
  "${repository}/bin/virtdev-install" >"${output}" 2>&1 || status=$?
if (( status != 16 )) || [[ -e "${mismatch_home}/installation" ]]; then
  printf 'installer accepted a mismatched SSH key pair (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ssh-ed25519 malformed\n' > "${ssh_key}.pub"
malformed_home="${test_tmp}/malformed-home"
status=0
PATH="${fixture_bin}:${PATH}" \
  VIRTDEV_HOME="${malformed_home}" \
  VIRTDEV_SSH_KEY="${ssh_key}" \
  "${repository}/bin/virtdev-install" >"${output}" 2>&1 || status=$?
if (( status != 16 )) || [[ -e "${malformed_home}/installation" ]]; then
  printf 'installer accepted a malformed SSH public key (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

invalid_key="${test_tmp}/invalid-id"
printf 'not an SSH private key\n' > "${invalid_key}"
cp "${other_key}.pub" "${invalid_key}.pub"
chmod 600 "${invalid_key}"
invalid_home="${test_tmp}/invalid-home"
status=0
PATH="${fixture_bin}:${PATH}" \
  VIRTDEV_HOME="${invalid_home}" \
  VIRTDEV_SSH_KEY="${invalid_key}" \
  "${repository}/bin/virtdev-install" >"${output}" 2>&1 || status=$?
if (( status != 16 )) || [[ -e "${invalid_home}/installation" ]]; then
  printf 'installer accepted an invalid SSH private key (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - installer rejects invalid or mismatched SSH key pairs before disk creation\n'
