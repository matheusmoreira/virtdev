#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # each import uses a scoped VIRTDEV_HOME

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

virtdev_home="${test_tmp}/virtdev"
config_home="${test_tmp}/config"
mkdir -p "${virtdev_home}/projects/target" "${config_home}"
printf 'unrelated\n' > "${virtdev_home}/projects/target/sentinel"

output="${test_tmp}/without-journal.output"
status=0
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-move" source target >"${output}" 2>&1 \
  || status=$?

if (( status != 3 )); then
  printf 'expected source-not-found exit 3 without journal, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ "$(< "${virtdev_home}/projects/target/sentinel")" != unrelated ]]; then
  printf 'unrelated target was mutated without transaction authority\n' >&2
  exit 1
fi

expect_invalid_journal() {
  local status=0
  VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
  PATH="${repository}/tests/fixtures:${PATH}" \
    "${repository}/bin/virtdev-move" source target \
      >"${test_tmp}/invalid-journal.output" 2>&1 || status=$?
  if (( status != 9 )) \
      || [[ "$(< "${virtdev_home}/projects/target/sentinel")" != unrelated ]]; then
    printf 'malformed move journal was accepted (status %d)\n' "${status}" >&2
    cat "${test_tmp}/invalid-journal.output" >&2
    exit 1
  fi
}

printf 'version=1\nsource=source\ntarget=target\nextra\n' \
  > "${virtdev_home}/move.transaction"
expect_invalid_journal
printf 'version=1\nsource=source\0\ntarget=target\n' \
  > "${virtdev_home}/move.transaction"
expect_invalid_journal
truncate -s 1048576 "${virtdev_home}/move.transaction"
expect_invalid_journal

printf 'version=1\nsource=source\ntarget=target\n' > "${virtdev_home}/move.transaction"
output="${test_tmp}/with-journal.output"
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-move" source target >"${output}" 2>&1

if [[ -e "${virtdev_home}/move.transaction" ]]; then
  printf 'completed recovery left its transaction journal behind\n' >&2
  cat "${output}" >&2
  exit 1
fi
if ! grep -Fq 'Recovering from interrupted move' "${output}"; then
  printf 'matching journal did not enter recovery\n' >&2
  cat "${output}" >&2
  exit 1
fi

mkdir -p "${virtdev_home}/projects/source-keyed"
(
  export VIRTDEV_HOME="${virtdev_home}"
  # shellcheck disable=SC1090
  source "${repository}/lib/virtdev/import"
  import ssh
  ssh_host_identity_ensure source-keyed
)
private_before="$(sha256sum \
  "${virtdev_home}/projects/source-keyed/ssh-host/host_key" | cut -d' ' -f1)"
mv "${virtdev_home}/projects/source-keyed" \
  "${virtdev_home}/projects/target-keyed"
printf 'version=1\nsource=source-keyed\ntarget=target-keyed\n' \
  > "${virtdev_home}/move.transaction"

rebind_bin="${test_tmp}/rebind-bin"
mkdir "${rebind_bin}"
ln -s "${repository}/tests/fixtures/sync-counted" "${rebind_bin}/sync"
status=0
SYNC_COUNT_FILE="${test_tmp}/rollback-sync-count" SYNC_FAIL_CALL=2 \
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${rebind_bin}:${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-move" source-keyed target-keyed \
    >"${test_tmp}/keyed-rollback.output" 2>&1 || status=$?
if (( status != 103 )) \
    || [[ ! -f "${virtdev_home}/move.transaction" ]] \
    || ! grep -q '^virtdev-source-keyed ssh-ed25519 ' \
      "${virtdev_home}/projects/target-keyed/ssh-host/known_hosts"; then
  printf 'failed alias rebind did not roll back and retain its journal\n' >&2
  cat "${test_tmp}/keyed-rollback.output" >&2
  exit 1
fi

(
  export VIRTDEV_HOME="${virtdev_home}"
  # shellcheck disable=SC1090
  source "${repository}/lib/virtdev/import"
  import ssh
  ssh_host_identity_rebind target-keyed source-keyed
)
status=0
SYNC_COUNT_FILE="${test_tmp}/ambiguous-sync-count" SYNC_FAIL_CALL=1 \
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${rebind_bin}:${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-move" source-keyed target-keyed \
    >"${test_tmp}/keyed-ambiguous.output" 2>&1 || status=$?
if (( status != 103 )) \
    || [[ ! -f "${virtdev_home}/move.transaction" ]] \
    || ! grep -q '^virtdev-target-keyed ssh-ed25519 ' \
      "${virtdev_home}/projects/target-keyed/ssh-host/known_hosts"; then
  printf 'ambiguous committed alias did not retain recovery authority\n' >&2
  cat "${test_tmp}/keyed-ambiguous.output" >&2
  exit 1
fi

VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-move" source-keyed target-keyed \
    >"${test_tmp}/keyed-recovery.output" 2>&1
(
  export VIRTDEV_HOME="${virtdev_home}"
  # shellcheck disable=SC1090
  source "${repository}/lib/virtdev/import"
  import ssh
  ssh_host_identity_require target-keyed
)
if [[ "$(sha256sum \
    "${virtdev_home}/projects/target-keyed/ssh-host/host_key" | cut -d' ' -f1)" \
      != "${private_before}" ]] \
    || ! grep -q '^virtdev-target-keyed ssh-ed25519 ' \
      "${virtdev_home}/projects/target-keyed/ssh-host/known_hosts"; then
  printf 'move recovery did not preserve the key and rebind its alias\n' >&2
  exit 1
fi

provenance_home="${test_tmp}/provenance-home"
provenance_config="${test_tmp}/provenance-config"
snapshot_directory="${provenance_home}/backups/source/2026-08-30/02-00-00"
mkdir -p "${provenance_home}/projects/source" "${snapshot_directory}" \
  "${provenance_config}"
printf 'other\n' > "${snapshot_directory}/project"

run_provenance_move() {
  VIRTDEV_HOME="${provenance_home}" \
  XDG_CONFIG_HOME="${provenance_config}" \
  VIRTDEV_LOCK_DIRECTORY="${test_tmp}/provenance-locks" \
  SYSTEMCTL_ACTIVE_STATE=inactive \
  PATH="${repository}/tests/fixtures:${PATH}" \
    "${repository}/bin/virtdev-move" source target \
      >"${test_tmp}/provenance.output" 2>&1
}

status=0
run_provenance_move || status=$?
if (( status != 9 )) \
    || [[ ! -d "${provenance_home}/projects/source" \
      || -e "${provenance_home}/projects/target" \
      || -e "${provenance_home}/move.transaction" \
      || "$(< "${snapshot_directory}/project")" != other ]]; then
  printf 'move laundered mismatched snapshot provenance (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/provenance.output" >&2
  exit 1
fi

rm "${snapshot_directory}/project"
status=0
run_provenance_move || status=$?
if (( status != 9 )); then
  printf 'move accepted a missing snapshot marker (status %d)\n' "${status}" >&2
  exit 1
fi
mkdir "${snapshot_directory}/project"
status=0
run_provenance_move || status=$?
if (( status != 9 )); then
  printf 'move accepted a directory snapshot marker (status %d)\n' "${status}" >&2
  exit 1
fi
rmdir "${snapshot_directory}/project"
printf 'source\n' > "${test_tmp}/outside-marker"
ln -s "${test_tmp}/outside-marker" "${snapshot_directory}/project"
status=0
run_provenance_move || status=$?
if (( status != 9 )); then
  printf 'move accepted a symlinked snapshot marker (status %d)\n' "${status}" >&2
  exit 1
fi
rm "${snapshot_directory}/project"

: > "${provenance_home}/projects/target"
status=0
run_provenance_move || status=$?
if (( status != 4 )) || [[ ! -d "${provenance_home}/projects/source" ]]; then
  printf 'move accepted a regular-file target collision (status %d)\n' \
    "${status}" >&2
  exit 1
fi
rm "${provenance_home}/projects/target"
ln -s missing-target "${provenance_home}/projects/target"
status=0
run_provenance_move || status=$?
if (( status != 4 )) || [[ ! -d "${provenance_home}/projects/source" ]]; then
  printf 'move accepted a dangling target collision (status %d)\n' \
    "${status}" >&2
  exit 1
fi
rm "${provenance_home}/projects/target"

printf 'source\n' > "${snapshot_directory}/project"
run_provenance_move
moved_marker="${provenance_home}/backups/target/2026-08-30/02-00-00/project"
if [[ "$(< "${moved_marker}")" != target \
      || -e "${provenance_home}/move.transaction" ]]; then
  printf 'valid move did not durably relabel snapshot provenance\n' >&2
  exit 1
fi

mixed_home="${test_tmp}/mixed-recovery-home"
mkdir -p "${mixed_home}/projects/target" \
  "${mixed_home}/backups/target/2026-08-30/03-00-00" \
  "${mixed_home}/backups/target/2026-08-30/04-00-00"
printf 'source\n' > \
  "${mixed_home}/backups/target/2026-08-30/03-00-00/project"
printf 'target\n' > \
  "${mixed_home}/backups/target/2026-08-30/04-00-00/project"
printf 'version=1\nsource=source\ntarget=target\n' \
  > "${mixed_home}/move.transaction"
VIRTDEV_HOME="${mixed_home}" XDG_CONFIG_HOME="${provenance_config}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/mixed-locks" \
SYSTEMCTL_ACTIVE_STATE=inactive \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-move" source target \
    >"${test_tmp}/mixed-recovery.output" 2>&1
for marker in "${mixed_home}"/backups/target/2026-08-30/*/project; do
  if [[ "$(< "${marker}")" != target ]]; then
    printf 'move recovery did not converge mixed marker states\n' >&2
    exit 1
  fi
done

printf 'ok - move recovery requires an exact transaction journal\n'
printf 'ok - move recovery rebinds only the project host alias\n'
printf 'ok - move preflights and durably converges snapshot provenance\n'
