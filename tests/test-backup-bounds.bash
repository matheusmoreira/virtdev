#!/usr/bin/env bash
# shellcheck disable=SC2016  # generated fixture

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
restore_bin="${test_tmp}/restore-bin"
sync_bin="${test_tmp}/sync-bin"
timeout_bin="${test_tmp}/timeout-bin"
mkdir -p "${fixture_bin}" "${restore_bin}" "${test_tmp}/guest/data/sub"
mkdir "${sync_bin}" "${timeout_bin}"
cp "${repository}/tests/fixtures/ssh-backup" "${fixture_bin}/ssh"
cp "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'for argument in "$@"; do' \
  '  if [[ "${argument}" == --extract && -n "${BACKUP_EXTRACT_STARTED_FILE:-}" ]]; then' \
  '    : > "${BACKUP_EXTRACT_STARTED_FILE}"' \
  '  fi' \
  'done' \
  'exec /usr/bin/tar "$@"' \
  > "${fixture_bin}/tar"
chmod +x "${fixture_bin}/ssh" "${fixture_bin}/systemctl" \
  "${fixture_bin}/tar"
cp "${repository}/tests/fixtures/ssh-restore" "${restore_bin}/ssh"
cp "${repository}/tests/fixtures/systemctl" "${restore_bin}/systemctl"
chmod +x "${restore_bin}/ssh" "${restore_bin}/systemctl"
ln -s "${repository}/tests/fixtures/sync-counted" "${sync_bin}/sync"
cp "${repository}/tests/fixtures/timeout-copy-tree-status" \
  "${timeout_bin}/timeout"

printf 'payload\n' > "${test_tmp}/guest/data/sub/file"
printf 'second\n' > "${test_tmp}/guest/data/other"
tar -C "${test_tmp}/guest" -cf "${test_tmp}/capture.tar" data
archive_bytes="$(stat -c '%s' "${test_tmp}/capture.tar")"
truncate -s 2097152 "${test_tmp}/guest/sparse"
tar --sparse -C "${test_tmp}/guest" -cf "${test_tmp}/sparse.tar" sparse
tar -C "${test_tmp}/guest/data" -cf "${test_tmp}/escape.tar" \
  --transform='s|^other$|../escaped|' other
tar -C "${test_tmp}/guest/data" -cf "${test_tmp}/deep.tar" \
  --transform='s|^other$|a/b/c/other|' other
deep_prefix=''
for _ in {1..129}; do
  deep_prefix+='a/'
done
tar -C "${test_tmp}/guest/data" -cf "${test_tmp}/too-deep.tar" \
  --transform="s|^other$|${deep_prefix}other|" other
long_name=''
for _ in {1..5000}; do
  long_name+='x'
done
tar --format=pax -C "${test_tmp}/guest/data" \
  -cf "${test_tmp}/long-name.tar" \
  --transform="s|^other$|${long_name}|" other

ssh_key="${test_tmp}/id"
printf 'test private key\n' > "${ssh_key}"
chmod 600 "${ssh_key}"

prepare_home() {
  local -r home="${1}"
  mkdir -p "${home}/projects/probe" "${home}/system"
  printf 'data\n' > "${home}/projects/probe/manifest"
  printf '2222\n' > "${home}/projects/probe/port"
  printf '1\n' > "${home}/projects/probe/generation"
  printf 'ssh-host-identity=1\n' > "${home}/projects/probe/guest-contract"
  printf '1\n' > "${home}/system/generation"
  (
    export VIRTDEV_HOME="${home}"
    # shellcheck disable=SC1090
    source "${repository}/lib/virtdev/import"
    import ssh
    ssh_host_identity_ensure probe
  )
}

run_backup() {
  local -r home="${1}" max_bytes="${2}" max_entries="${3}" timeout_seconds="${4}"
  shift 4
  PATH="${fixture_bin}:${PATH}" \
    NO_COLOR=1 \
    SYSTEMCTL_ACTIVE_STATE=active \
    VIRTDEV_HOME="${home}" \
    VIRTDEV_SSH_KEY="${ssh_key}" \
    VIRTDEV_BACKUP_MAX_BYTES="${max_bytes}" \
    VIRTDEV_BACKUP_MAX_ENTRIES="${max_entries}" \
    VIRTDEV_BACKUP_TIMEOUT="${timeout_seconds}" \
    VIRTDEV_BACKUP_KILL_AFTER=1 \
    BACKUP_TAR_STREAM="${test_tmp}/capture.tar" \
    "$@" \
    "${repository}/bin/virtdev-backup" probe
}

success_home="${test_tmp}/success-home"
prepare_home "${success_home}"
status=0
snapshot="$(run_backup "${success_home}" "${archive_bytes}" 4 10 \
  2>"${test_tmp}/success-stderr")" || status=$?
if (( status != 0 )); then
  printf 'bounded archive success case failed (status %d)\n' "${status}" >&2
  cat "${test_tmp}/success-stderr" >&2
  exit 1
fi
if [[ ! -f "${snapshot}/tree/data/sub/file" \
      || "$(< "${snapshot}/tree/data/sub/file")" != payload \
      || -e "${snapshot}/capture.tar" ]]; then
  printf 'bounded archive was not promoted as an ordinary snapshot tree\n' >&2
  exit 1
fi

boundary_home="${test_tmp}/boundary-home"
prepare_home "${boundary_home}"
printf 'sparse\n' > "${boundary_home}/projects/probe/manifest"
status=0
boundary_snapshot="$(run_backup "${boundary_home}" 2097152 1 10 \
  env BACKUP_TAR_STREAM="${test_tmp}/sparse.tar" \
  2>"${test_tmp}/boundary-backup.stderr")" || status=$?
if (( status != 0 )); then
  printf 'exact logical-byte backup failed (status %d)\n' "${status}" >&2
  cat "${test_tmp}/boundary-backup.stderr" >&2
  exit 1
fi
boundary_id="${boundary_snapshot#"${boundary_home}/backups/probe/"}"
boundary_guest="${test_tmp}/boundary-guest"
mkdir "${boundary_guest}"
status=0
PATH="${restore_bin}:${PATH}" \
  HOME="${test_tmp}" \
  XDG_CONFIG_HOME="${test_tmp}/config" \
  NO_COLOR=1 \
  SYSTEMCTL_ACTIVE_STATE=active \
  VIRTDEV_HOME="${boundary_home}" \
  VIRTDEV_SSH_KEY="${ssh_key}" \
  VIRTDEV_RESTORE_MAX_BYTES=2097152 \
  VIRTDEV_RESTORE_MAX_ENTRIES=1 \
  VIRTDEV_RESTORE_TIMEOUT=10 \
  VIRTDEV_RESTORE_KILL_AFTER=1 \
  RESTORE_GUEST_ROOT="${boundary_guest}" \
  "${repository}/bin/virtdev-restore" probe "${boundary_id}" \
  >"${test_tmp}/boundary-restore.output" 2>&1 || status=$?
if (( status != 0 )) \
    || [[ "$(stat -c '%s' "${boundary_guest}/sparse" 2>/dev/null)" != 2097152 ]]; then
  printf 'backup/restore logical-byte boundary disagreed (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/boundary-restore.output" >&2
  exit 1
fi

bytes_home="${test_tmp}/bytes-home"
prepare_home "${bytes_home}"
status=0
run_backup "${bytes_home}" "$(( archive_bytes - 1 ))" 100 10 \
  >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 19 )) \
    || find "${bytes_home}/backups" -name '*.partial' -print -quit \
      | grep -q .; then
  printf 'archive byte overflow was not rejected and cleaned (status %d)\n' \
    "${status}" >&2
  exit 1
fi

sparse_home="${test_tmp}/sparse-home"
prepare_home "${sparse_home}"
status=0
run_backup "${sparse_home}" 1048576 100 10 \
  env BACKUP_TAR_STREAM="${test_tmp}/sparse.tar" \
  >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 19 )) \
    || find "${sparse_home}/backups" -name '*.partial' -print -quit \
      | grep -q .; then
  printf 'sparse logical-byte overflow was not rejected (status %d)\n' \
    "${status}" >&2
  exit 1
fi

entries_home="${test_tmp}/entries-home"
prepare_home "${entries_home}"
status=0
run_backup "${entries_home}" 1048576 3 10 \
  >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 19 )) \
    || find "${entries_home}/backups" -name '*.partial' -print -quit \
      | grep -q .; then
  printf 'archive entry overflow was not rejected and cleaned (status %d)\n' \
    "${status}" >&2
  exit 1
fi

parents_home="${test_tmp}/parents-home"
parents_extract_started="${test_tmp}/parents-extract-started"
prepare_home "${parents_home}"
status=0
run_backup "${parents_home}" 1048576 3 10 \
  env BACKUP_TAR_STREAM="${test_tmp}/deep.tar" \
    BACKUP_EXTRACT_STARTED_FILE="${parents_extract_started}" \
  >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${parents_extract_started}" ]] \
    || find "${parents_home}/backups" -name '*.partial' -print -quit \
      | grep -q .; then
  printf 'implicit archive parents escaped the entry budget (status %d)\n' \
    "${status}" >&2
  exit 1
fi

depth_home="${test_tmp}/depth-home"
depth_extract_started="${test_tmp}/depth-extract-started"
prepare_home "${depth_home}"
status=0
run_backup "${depth_home}" 1048576 1000 10 \
  env BACKUP_TAR_STREAM="${test_tmp}/too-deep.tar" \
    BACKUP_EXTRACT_STARTED_FILE="${depth_extract_started}" \
  >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${depth_extract_started}" ]] \
    || find "${depth_home}/backups" -name '*.partial' -print -quit \
      | grep -q .; then
  printf 'archive path depth escaped its validation budget (status %d)\n' \
    "${status}" >&2
  exit 1
fi

escape_home="${test_tmp}/escape-home"
prepare_home "${escape_home}"
status=0
run_backup "${escape_home}" 1048576 100 10 \
  env BACKUP_TAR_STREAM="${test_tmp}/escape.tar" \
  >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 18 )) || find "${escape_home}" -name escaped -print -quit \
    | grep -q .; then
  printf 'unsafe archive path escaped extraction containment (status %d)\n' \
    "${status}" >&2
  exit 1
fi

long_name_home="${test_tmp}/long-name-home"
long_name_extract_started="${test_tmp}/long-name-extract-started"
prepare_home "${long_name_home}"
status=0
run_backup "${long_name_home}" 1048576 100 10 \
  env BACKUP_TAR_STREAM="${test_tmp}/long-name.tar" \
    BACKUP_EXTRACT_STARTED_FILE="${long_name_extract_started}" \
  >"${test_tmp}/long-name.output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${long_name_extract_started}" ]]; then
  printf 'oversized tar extension reached host listing/extraction (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/long-name.output" >&2
  exit 1
fi

manifest_home="${test_tmp}/manifest-home"
prepare_home "${manifest_home}"
truncate -s 1048577 "${manifest_home}/projects/probe/manifest"
status=0
run_backup "${manifest_home}" 1048576 100 10 \
  >"${test_tmp}/manifest-overflow.output" 2>&1 || status=$?
if (( status != 19 )); then
  printf 'backup accepted an oversized manifest (status %d)\n' "${status}" >&2
  cat "${test_tmp}/manifest-overflow.output" >&2
  exit 1
fi

manifest_timeout_home="${test_tmp}/manifest-timeout-home"
prepare_home "${manifest_timeout_home}"
status=0
run_backup "${manifest_timeout_home}" 1048576 100 10 \
  env PATH="${timeout_bin}:${fixture_bin}:${PATH}" \
    RESTORE_TIMEOUT_COMMAND=head \
  >"${test_tmp}/manifest-timeout.output" 2>&1 || status=$?
if (( status != 20 )); then
  printf 'backup lost its manifest deadline (status %d)\n' "${status}" >&2
  cat "${test_tmp}/manifest-timeout.output" >&2
  exit 1
fi

df_timeout_home="${test_tmp}/df-timeout-home"
prepare_home "${df_timeout_home}"
status=0
run_backup "${df_timeout_home}" 1048576 100 10 \
  env PATH="${timeout_bin}:${fixture_bin}:${PATH}" \
    RESTORE_TIMEOUT_COMMAND=df \
  >"${test_tmp}/df-timeout.output" 2>&1 || status=$?
if (( status != 20 )); then
  printf 'backup lost its capacity-probe deadline (status %d)\n' "${status}" >&2
  cat "${test_tmp}/df-timeout.output" >&2
  exit 1
fi

timeout_home="${test_tmp}/timeout-home"
prepare_home "${timeout_home}"
status=0
run_backup "${timeout_home}" 1048576 100 1 \
  env BACKUP_STREAM_DELAY=5 BACKUP_PID_FILE="${test_tmp}/backup.pid" \
  >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 20 )) \
    || find "${timeout_home}/backups" -name '*.partial' -print -quit \
      | grep -q .; then
  printf 'archive timeout was not rejected and cleaned (status %d)\n' \
    "${status}" >&2
  exit 1
fi

if [[ -s "${test_tmp}/backup.pid" ]] \
    && kill -0 "$(< "${test_tmp}/backup.pid")" 2>/dev/null; then
  printf 'backup timeout left its SSH capture process alive\n' >&2
  exit 1
fi

diagnostic_home="${test_tmp}/diagnostic-home"
prepare_home "${diagnostic_home}"
status=0
run_backup "${diagnostic_home}" 1048576 100 10 \
  env VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES=64 BACKUP_STDERR_BYTES=65 \
  >"${test_tmp}/diagnostic.output" 2>&1 || status=$?
if (( status != 19 )) \
    || ! grep -Fq 'diagnostics exceeded the bounded output budget' \
      "${test_tmp}/diagnostic.output" \
    || (( $(stat -c '%s' "${test_tmp}/diagnostic.output") > 4096 )) \
    || find "${diagnostic_home}/backups" -name '*.partial' -print -quit \
      | grep -q .; then
  printf 'backup did not bound guest-controlled stderr (status %d)\n' \
    "${status}" >&2
  exit 1
fi

pre_sync_home="${test_tmp}/pre-sync-home"
pre_sync_count="${test_tmp}/pre-sync-count"
prepare_home "${pre_sync_home}"
status=0
run_backup "${pre_sync_home}" 1048576 100 10 \
  env PATH="${sync_bin}:${fixture_bin}:${PATH}" \
    SYNC_COUNT_FILE="${pre_sync_count}" SYNC_FAIL_CALL=1 \
  >"${test_tmp}/output" 2>&1 || status=$?
pre_sync_partial="$(find "${pre_sync_home}/backups/probe" \
  -mindepth 2 -maxdepth 2 -type d -name '*.partial' -print -quit)"
if (( status != 18 )) || [[ "$(< "${pre_sync_count}")" != 1 \
      || ! -f "${pre_sync_partial}/tree/data/sub/file" ]]; then
  printf 'pre-publication sync failure was not preserved (status %d)\n' \
    "${status}" >&2
  exit 1
fi

post_sync_home="${test_tmp}/post-sync-home"
post_sync_count="${test_tmp}/post-sync-count"
prepare_home "${post_sync_home}"
status=0
run_backup "${post_sync_home}" 1048576 100 10 \
  env PATH="${sync_bin}:${fixture_bin}:${PATH}" \
    SYNC_COUNT_FILE="${post_sync_count}" SYNC_FAIL_CALL=2 \
  >"${test_tmp}/output" 2>&1 || status=$?
post_sync_final="$(find "${post_sync_home}/backups/probe" \
  -mindepth 2 -maxdepth 2 -type d ! -name '*.partial' -print -quit)"
if (( status != 18 )) || [[ "$(< "${post_sync_count}")" != 2 \
      || ! -f "${post_sync_final}/tree/data/sub/file" ]] \
    || find "${post_sync_home}/backups" -name '*.partial' -print -quit \
      | grep -q .; then
  printf 'post-publication sync failure was not preserved (status %d)\n' \
    "${status}" >&2
  exit 1
fi

printf 'ok - backup capture enforces physical, logical, entry, and time budgets\n'
printf 'ok - backup and restore agree at the logical-byte boundary\n'
printf 'ok - backup publication is durable or preserves inspectable recovery state\n'
printf 'ok - backup bounds and sanitizes guest diagnostics\n'
