#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
mkdir "${fixture_bin}"
ln -s "${repository}/tests/fixtures/qemu-img" "${fixture_bin}/qemu-img"
# shellcheck disable=SC2016  # expanded by the generated fixture
printf '#!/usr/bin/env bash\n: > "${SYSTEMD_RUN_MARKER:?}"\n' \
  > "${fixture_bin}/systemd-run"
chmod 0755 "${fixture_bin}/systemd-run"

virtdev_home="${test_tmp}/virtdev"
system_directory="${virtdev_home}/system"
mkdir -p "${system_directory}"
for file in system.qcow2 home.qcow2 nvram; do
  : > "${system_directory}/${file}"
done
printf '1\n' > "${system_directory}/generation"

output="${test_tmp}/output"
status=0
PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
NO_COLOR=1 QEMU_OTHER_STATUS=0 VIRTDEV_HOME="${virtdev_home}" \
  "${repository}/bin/virtdev-create" current >"${output}" 2>&1 || status=$?
if (( status != 8 )) || [[ -e "${virtdev_home}/projects/current" ]]; then
  printf 'create accepted a base without the guest contract (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ssh-host-identity=1\n' > "${system_directory}/guest-contract"
PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
NO_COLOR=1 QEMU_OTHER_STATUS=0 VIRTDEV_HOME="${virtdev_home}" \
  "${repository}/bin/virtdev-create" current >"${output}" 2>&1
project_contract="${virtdev_home}/projects/current/guest-contract"
if [[ "$(< "${project_contract}")" != ssh-host-identity=1 \
      || "$(stat -c '%a' "${project_contract}")" != 444 ]]; then
  printf 'create did not copy the exact guest contract into the project\n' >&2
  exit 1
fi

rm -f -- "${project_contract}"
status=0
SYSTEMD_RUN_MARKER="${test_tmp}/systemd-run.called" \
PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
NO_COLOR=1 VIRTDEV_HOME="${virtdev_home}" \
  "${repository}/bin/virtdev-start" --unfiltered current \
    >"${output}" 2>&1 || status=$?
if (( status != 104 )) || [[ -e "${test_tmp}/systemd-run.called" ]]; then
  printf 'start did not reject an incompatible project before launch (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ssh-host-identity=1\n' > "${project_contract}"
rm -f -- "${system_directory}/guest-contract"
status=0
NO_COLOR=1 VIRTDEV_HOME="${virtdev_home}" \
  "${repository}/bin/virtdev-recreate" --no-backup --no-restore \
    --no-provision --yes current >"${output}" 2>&1 || status=$?
if (( status != 10 )) || [[ ! -d "${virtdev_home}/projects/current" ]]; then
  printf 'recreate crossed an incompatible base before refusing (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

status=0
NO_COLOR=1 VIRTDEV_HOME="${virtdev_home}" \
  "${repository}/bin/virtdev-upgrade" --unfiltered --yes \
    >"${output}" 2>&1 || status=$?
if (( status != 14 )); then
  printf 'upgrade did not preflight the guest contract (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

status=0
NO_COLOR=1 VIRTDEV_HOME="${virtdev_home}" \
  "${repository}/bin/virtdev-maintain" \
    --unfiltered --no-provision --no-inventory \
    >"${output}" 2>&1 || status=$?
if (( status != 33 )) || [[ -e "${virtdev_home}/maintenance" ]]; then
  printf 'maintenance did not refuse before staging (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - create requires and copies the proven guest contract\n'
printf 'ok - start requires a project-local contract before launch\n'
printf 'ok - recreate and upgrade refuse incompatible bases before mutation\n'
printf 'ok - maintenance refuses incompatible bases before staging\n'
