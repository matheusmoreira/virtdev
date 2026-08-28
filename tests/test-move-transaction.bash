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

printf 'ok - move recovery requires an exact transaction journal\n'
printf 'ok - move recovery rebinds only the project host alias\n'
