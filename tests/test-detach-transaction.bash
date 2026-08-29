#!/usr/bin/env bash
# shellcheck disable=SC2016  # documentation assertions are literal Markdown

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

virtdev_home="${test_tmp}/virtdev"
project_directory="${virtdev_home}/projects/probe"
mkdir -p "${virtdev_home}/system" "${project_directory}"
printf '1\n' > "${virtdev_home}/system/generation"
printf '1\n' > "${project_directory}/generation"
printf 'original system\n' > "${project_directory}/system.qcow2"
printf 'original home\n' > "${project_directory}/home.qcow2"

output="${test_tmp}/output"
printf 'unrelated backup\n' > "${project_directory}/system.qcow2.bak"
status=0
VIRTDEV_HOME="${virtdev_home}" QEMU_HAS_BACKING=1 \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-detach" --yes probe >"${output}" 2>&1 \
  || status=$?

if (( status != 16 )); then
  printf 'expected unexplained-backup exit 16, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ "$(< "${project_directory}/system.qcow2")" != 'original system' \
      || "$(< "${project_directory}/system.qcow2.bak")" != 'unrelated backup' ]]; then
  printf 'unexplained backup collision mutated project disks\n' >&2
  exit 1
fi
rm "${project_directory}/system.qcow2.bak"

system_identity="$(stat -c '%d:%i' "${project_directory}/system.qcow2")"
home_identity="$(stat -c '%d:%i' "${project_directory}/home.qcow2")"
printf 'version=1\nproject=probe\ngeneration=1\nsystem_identity=%s\nhome_identity=%s\nphase=swapping\n' \
  "${system_identity}" "${home_identity}" \
  > "${project_directory}/.detach.transaction"

mv "${project_directory}/system.qcow2" "${project_directory}/system.qcow2.bak"
printf 'converted system\n' > "${project_directory}/system.qcow2"

VIRTDEV_HOME="${virtdev_home}" QEMU_HAS_BACKING=1 \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-detach" --yes probe >"${output}" 2>&1

if [[ "$(< "${project_directory}/system.qcow2")" != 'original system' \
      || "$(< "${project_directory}/home.qcow2")" != 'original home' ]]; then
  printf 'journaled rollback did not restore exact original disks\n' >&2
  cat "${output}" >&2
  exit 1
fi
if [[ "$(< "${project_directory}/generation")" != 1 ]]; then
  printf 'journaled rollback did not restore the coupled generation\n' >&2
  exit 1
fi
if [[ -e "${project_directory}/.detach.transaction" \
      || -e "${project_directory}/system.qcow2.bak" ]]; then
  printf 'completed journaled rollback left recovery state behind\n' >&2
  exit 1
fi

grep -Fq '`.detach.transaction`' "${repository}/DESIGN.md"
grep -Fq 'A `.bak` file without the journal is untrusted' \
  "${repository}/DESIGN.md"
grep -Fq 'identity-bound `.detach.transaction` journal' \
  "${repository}/CLAUDE.md"

printf 'ok - detach recovery requires a matching disk-identity journal\n'
printf 'ok - detach documentation denies authority to unexplained backups\n'
