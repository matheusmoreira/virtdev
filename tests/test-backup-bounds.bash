#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
mkdir -p "${fixture_bin}" "${test_tmp}/guest/data/sub"
cp "${repository}/tests/fixtures/ssh-backup" "${fixture_bin}/ssh"
cp "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
chmod +x "${fixture_bin}/ssh" "${fixture_bin}/systemctl"

printf 'payload\n' > "${test_tmp}/guest/data/sub/file"
printf 'second\n' > "${test_tmp}/guest/data/other"
tar -C "${test_tmp}/guest" -cf "${test_tmp}/capture.tar" data
archive_bytes="$(stat -c '%s' "${test_tmp}/capture.tar")"
tar -C "${test_tmp}/guest/data" -cf "${test_tmp}/escape.tar" \
  --transform='s|^other$|../escaped|' other

ssh_key="${test_tmp}/id"
printf 'test private key\n' > "${ssh_key}"
chmod 600 "${ssh_key}"

prepare_home() {
  local -r home="${1}"
  mkdir -p "${home}/projects/probe" "${home}/system"
  printf 'data\n' > "${home}/projects/probe/manifest"
  printf '2222\n' > "${home}/projects/probe/port"
  printf '1\n' > "${home}/system/generation"
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
if [[ ! -s "${test_tmp}/backup.pid" ]] \
    || kill -0 "$(< "${test_tmp}/backup.pid")" 2>/dev/null; then
  printf 'backup timeout left its SSH capture process alive\n' >&2
  exit 1
fi

printf 'ok - backup capture enforces byte, entry, and wall-clock budgets\n'
