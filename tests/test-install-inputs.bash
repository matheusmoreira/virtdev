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
printf 'test private key\n' > "${ssh_key}"
printf 'test public key\n' > "${ssh_key}.pub"
chmod 600 "${ssh_key}"

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
