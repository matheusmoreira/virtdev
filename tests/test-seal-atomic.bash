#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
mkdir -p "${fixture_bin}"
cp "${repository}/tests/fixtures/qemu-img" "${fixture_bin}/qemu-img"
chmod +x "${fixture_bin}/qemu-img"

virtdev_home="${test_tmp}/virtdev"
installation="${virtdev_home}/installation"
mkdir -p "${installation}"
printf 'system\n' > "${installation}/system.qcow2"
printf 'home\n' > "${installation}/home.qcow2"
printf 'nvram\n' > "${installation}/nvram"
printf 'ssh-host-identity=1\n' > "${installation}/guest-contract"
printf 'preserve me\n' > "${installation}/unexpected"

output="${test_tmp}/output"
status=0
PATH="${fixture_bin}:${PATH}" QEMU_OTHER_STATUS=0 \
  VIRTDEV_HOME="${virtdev_home}" \
  "${repository}/bin/virtdev-seal" >"${output}" 2>&1 || status=$?

if (( status != 8 )); then
  printf 'expected unexpected-entry exit 8, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ -e "${virtdev_home}/system" || ! -f "${installation}/unexpected" ]]; then
  printf 'seal published or lost state before validating the complete tree\n' >&2
  exit 1
fi

rm "${installation}/unexpected"
PATH="${fixture_bin}:${PATH}" QEMU_OTHER_STATUS=0 \
  VIRTDEV_HOME="${virtdev_home}" \
  "${repository}/bin/virtdev-seal" >"${output}" 2>&1

if [[ -e "${installation}" || ! -d "${virtdev_home}/system" ]]; then
  printf 'seal did not atomically rename installation to system\n' >&2
  cat "${output}" >&2
  exit 1
fi
if [[ "$(cat "${virtdev_home}/system/generation")" != 1 ]]; then
  printf 'seal did not publish generation 1\n' >&2
  exit 1
fi
for file in system.qcow2 home.qcow2 nvram generation guest-contract; do
  if [[ "$(stat -c '%a' "${virtdev_home}/system/${file}")" != 444 ]]; then
    printf 'sealed file is not read-only: %s\n' "${file}" >&2
    exit 1
  fi
done
if [[ "$(< "${virtdev_home}/system/guest-contract")" \
      != ssh-host-identity=1 ]]; then
  printf 'seal changed the guest transport contract\n' >&2
  exit 1
fi

printf 'ok - seal validates staging then publishes it with one rename\n'
