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

sync_bin="${test_tmp}/sync-bin"
backing_state="${test_tmp}/backing-state"
qemu_log="${test_tmp}/in-place-qemu.log"
sync_count="${test_tmp}/in-place-sync.count"
mkdir "${sync_bin}" "${backing_state}"
ln -s "${repository}/tests/fixtures/sync-counted" "${sync_bin}/sync"
: > "${backing_state}/system.qcow2"
: > "${backing_state}/home.qcow2"
status=0
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/in-place-locks" \
QEMU_BACKING_STATE_DIRECTORY="${backing_state}" \
QEMU_REBASE_MUTATE=1 \
QEMU_LOG="${qemu_log}" \
SYNC_COUNT_FILE="${sync_count}" \
SYNC_FAIL_CALL=3 \
PATH="${sync_bin}:${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-detach" --in-place --yes probe \
    >"${test_tmp}/in-place-first.output" 2>&1 || status=$?
if (( status != 17 )) \
    || [[ ! -f "${project_directory}/.detach.transaction" \
      || -e "${backing_state}/system.qcow2" \
      || -e "${backing_state}/home.qcow2" \
      || "$(< "${project_directory}/generation")" != 1 ]]; then
  printf 'in-place metadata failure lost recovery authority (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/in-place-first.output" >&2
  exit 1
fi

: > "${project_directory}/generation"
status=0
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/in-place-locks" \
QEMU_BACKING_STATE_DIRECTORY="${backing_state}" \
QEMU_REBASE_MUTATE=1 \
QEMU_LOG="${qemu_log}" \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-detach" --in-place --yes probe \
    >"${test_tmp}/in-place-recovery.output" 2>&1 || status=$?
if (( status != 0 )) \
    || [[ "$(< "${project_directory}/generation")" != detached \
      || -e "${project_directory}/.detach.transaction" ]] \
    || [[ "$(grep -c '^rebase ' "${qemu_log}")" != 2 ]]; then
  printf 'in-place detach did not converge metadata-only recovery (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/in-place-recovery.output" >&2
  exit 1
fi

printf '1\n' > "${project_directory}/generation"
: > "${backing_state}/home.qcow2"
system_identity="$(stat -c '%d:%i' "${project_directory}/system.qcow2")"
home_identity="$(stat -c '%d:%i' "${project_directory}/home.qcow2")"
printf 'version=2\nproject=probe\ngeneration=1\nsystem_identity=%s\nhome_identity=%s\nmode=in-place\nphase=rebasing\n' \
  "${system_identity}" "${home_identity}" \
  > "${project_directory}/.detach.transaction"
status=0
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/partial-locks" \
QEMU_BACKING_STATE_DIRECTORY="${backing_state}" \
QEMU_REBASE_MUTATE=1 \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-detach" --in-place --yes probe \
    >"${test_tmp}/in-place-partial.output" 2>&1 || status=$?
if (( status != 17 )) \
    || [[ "$(< "${project_directory}/generation")" != 1 \
      || ! -f "${project_directory}/.detach.transaction" ]]; then
  printf 'partial in-place rebase was incorrectly committed (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/in-place-partial.output" >&2
  exit 1
fi

grep -Fq '`.detach.transaction`' "${repository}/DESIGN.md"
grep -Fq 'A `.bak` file without the journal is untrusted' \
  "${repository}/DESIGN.md"
grep -Fq 'identity-bound `.detach.transaction` journal' \
  "${repository}/CLAUDE.md"

printf 'ok - detach recovery requires a matching disk-identity journal\n'
printf 'ok - in-place detach recovers metadata only after standalone proof\n'
printf 'ok - detach documentation denies authority to unexplained backups\n'
