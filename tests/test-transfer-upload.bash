#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d --tmpdir virtdev-test-transfer-upload.XXXXXXXXXX)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
virtdev_home="${test_tmp}/virtdev"
ssh_key="${test_tmp}/id"
mkdir -p "${fixture_bin}" "${virtdev_home}/projects/probe"
cp "${repository}/tests/fixtures/rsync-transfer" "${fixture_bin}/rsync"
cp "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
chmod 755 "${fixture_bin}/rsync" "${fixture_bin}/systemctl"
printf '2222\n' > "${virtdev_home}/projects/probe/port"
printf 'ssh-host-identity=1\n' \
  > "${virtdev_home}/projects/probe/guest-contract"
printf 'test private key\n' > "${ssh_key}"
chmod 600 "${ssh_key}"
(
  export VIRTDEV_HOME="${virtdev_home}"
  # shellcheck disable=SC1090
  source "${repository}/lib/virtdev/import"
  import ssh
  ssh_host_identity_ensure probe
)

run_upload() {
  env \
    PATH="${fixture_bin}:${PATH}" \
    HOME="${test_tmp}" \
    XDG_CONFIG_HOME="${test_tmp}/config" \
    NO_COLOR=1 \
    SYSTEMCTL_ACTIVE_STATE=active \
    VIRTDEV_HOME="${virtdev_home}" \
    VIRTDEV_SSH_KEY="${ssh_key}" \
    VIRTDEV_TRANSFER_TIMEOUT=10 \
    VIRTDEV_TRANSFER_KILL_AFTER=1 \
    VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES=64 \
    "$@" \
    "${repository}/bin/virtdev-transfer" probe \
      "${test_tmp}/source with spaces" ':remote path'
}

printf 'payload\n' > "${test_tmp}/source with spaces"
argv_file="${test_tmp}/rsync.argv"
run_upload RSYNC_ARGV_FILE="${argv_file}" \
  > "${test_tmp}/success.output" 2>&1
mapfile -d '' -t rsync_argv < "${argv_file}"
if (( ${#rsync_argv[@]} != 7 )) \
    || [[ "${rsync_argv[0]}" != -a \
      || "${rsync_argv[1]}" != --quiet \
      || "${rsync_argv[2]}" != -e \
      || "${rsync_argv[4]}" != -- \
      || "${rsync_argv[5]}" != "${test_tmp}/source with spaces" \
      || "${rsync_argv[6]}" != 'dev@127.0.0.1:remote path' \
      || -e "${rsync_argv[3]}" ]]; then
  printf 'supervised upload changed rsync argv or leaked its SSH wrapper\n' >&2
  exit 1
fi

status=0
run_upload RSYNC_STDERR_BYTES=65 \
  > "${test_tmp}/overflow.output" 2>&1 || status=$?
if (( status != 11 )) \
    || ! grep -Fq 'diagnostics exceeded their output budget' \
      "${test_tmp}/overflow.output" \
    || (( $(stat -c '%s' "${test_tmp}/overflow.output") > 4096 )); then
  printf 'upload diagnostics were not bounded (status %d)\n' "${status}" >&2
  cat "${test_tmp}/overflow.output" >&2
  exit 1
fi

for rsync_status in 23 255; do
  status=0
  run_upload RSYNC_STATUS="${rsync_status}" \
    > "${test_tmp}/failure-${rsync_status}.output" 2>&1 || status=$?
  if (( status != 13 )) \
      || ! grep -Fq "exit ${rsync_status}" \
        "${test_tmp}/failure-${rsync_status}.output" \
      || ! grep -Fq 'may contain a partial update' \
        "${test_tmp}/failure-${rsync_status}.output"; then
    printf 'upload failure %d was misclassified (status %d)\n' \
      "${rsync_status}" "${status}" >&2
    cat "${test_tmp}/failure-${rsync_status}.output" >&2
    exit 1
  fi
done

pid_file="${test_tmp}/rsync.pid"
status=0
run_upload VIRTDEV_TRANSFER_TIMEOUT=1 RSYNC_DELAY=5 RSYNC_IGNORE_TERM=1 \
  RSYNC_PID_FILE="${pid_file}" > "${test_tmp}/timeout.output" 2>&1 \
  || status=$?
if (( status != 12 )) \
    || { [[ -s "${pid_file}" ]] \
      && kill -0 "$(< "${pid_file}")" 2>/dev/null; }; then
  printf 'upload deadline did not terminate rsync (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/timeout.output" >&2
  exit 1
fi

printf 'ok - uploads preserve argv and bound time and diagnostics\n'
