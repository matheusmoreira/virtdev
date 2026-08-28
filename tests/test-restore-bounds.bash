#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
mkdir "${fixture_bin}"
cp "${repository}/tests/fixtures/ssh-restore" "${fixture_bin}/ssh"
cp "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
chmod +x "${fixture_bin}/ssh" "${fixture_bin}/systemctl"

virtdev_home="${test_tmp}/store"
project_directory="${virtdev_home}/projects/probe"
snapshot="${virtdev_home}/backups/probe/2026-08-28/12-00-00"
mkdir -p "${project_directory}" "${snapshot}/tree/real/sub" \
  "${virtdev_home}/system"
printf '2222\n' > "${project_directory}/port"
printf '1\n' > "${project_directory}/generation"
printf 'ssh-host-identity=1\n' > "${project_directory}/guest-contract"
printf '1\n' > "${virtdev_home}/system/generation"
printf 'probe\n' > "${snapshot}/project"
printf '1\n' > "${snapshot}/generation"
printf '%s\n' 'real/' 'link/' hard-one hard-two sparse > "${snapshot}/manifest"
printf 'payload\n' > "${snapshot}/tree/real/sub/file"
ln -s real "${snapshot}/tree/link"
printf 'linked payload\n' > "${snapshot}/tree/hard-one"
ln "${snapshot}/tree/hard-one" "${snapshot}/tree/hard-two"
truncate -s 2097152 "${snapshot}/tree/sparse"

ssh_key="${test_tmp}/id"
printf 'test private key\n' > "${ssh_key}"
chmod 600 "${ssh_key}"
(
  export VIRTDEV_HOME="${virtdev_home}"
  # shellcheck disable=SC1090
  source "${repository}/lib/virtdev/import"
  import ssh
  ssh_host_identity_ensure probe
)

run_restore() {
  local -r guest="${1}" maximum="${2}" timeout_seconds="${3}"
  shift 3
  mkdir -p "${guest}"
  PATH="${fixture_bin}:${PATH}" \
    HOME="${test_tmp}" \
    XDG_CONFIG_HOME="${test_tmp}/config" \
    NO_COLOR=1 \
    SYSTEMCTL_ACTIVE_STATE=active \
    VIRTDEV_HOME="${virtdev_home}" \
    VIRTDEV_SSH_KEY="${ssh_key}" \
    VIRTDEV_RESTORE_MAX_BYTES="${maximum}" \
    VIRTDEV_RESTORE_TIMEOUT="${timeout_seconds}" \
    VIRTDEV_RESTORE_KILL_AFTER=1 \
    RESTORE_GUEST_ROOT="${guest}" \
    "$@" \
    "${repository}/bin/virtdev-restore" probe 2026-08-28/12-00-00
}

guest="${test_tmp}/guest"
status=0
run_restore "${guest}" 8388608 10 \
  >"${test_tmp}/success.output" 2>&1 || status=$?
if (( status != 0 )) || [[ ! -f "${guest}/real/sub/file" \
      || ! -L "${guest}/link" \
      || "$(readlink "${guest}/link")" != real ]]; then
  printf 'real-rsync restore failed or dereferenced a symlink root (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/success.output" >&2
  exit 1
fi
if [[ "$(stat -c '%i' "${guest}/hard-one")" \
      != "$(stat -c '%i' "${guest}/hard-two")" ]]; then
  printf 'restore did not preserve hard-link identity\n' >&2
  exit 1
fi
sparse_size="$(stat -c '%s' "${guest}/sparse")"
sparse_blocks="$(stat -c '%b' "${guest}/sparse")"
if (( sparse_size != 2097152 || sparse_blocks * 512 >= sparse_size )); then
  printf 'restore expanded a sparse file\n' >&2
  exit 1
fi

budget_guest="${test_tmp}/budget-guest"
status=0
run_restore "${budget_guest}" 1048576 10 \
  >"${test_tmp}/budget.output" 2>&1 || status=$?
if (( status != 19 )) \
    || find "${budget_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore apparent-byte budget failed open (status %d)\n' \
    "${status}" >&2
  exit 1
fi

timeout_guest="${test_tmp}/timeout-guest"
timeout_pid_file="${test_tmp}/timeout.pid"
status=0
run_restore "${timeout_guest}" 8388608 2 \
  env RESTORE_SSH_DELAY=5 RESTORE_SSH_PID_FILE="${timeout_pid_file}" \
  >"${test_tmp}/timeout.output" 2>&1 || status=$?
if (( status != 20 )) || [[ ! -s "${timeout_pid_file}" ]] \
    || kill -0 "$(< "${timeout_pid_file}")" 2>/dev/null \
    || find "${timeout_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore deadline failed to contain transport (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/timeout.output" >&2
  exit 1
fi

printf 'ok - restore uses a compatible manifest file and preserves inode fidelity\n'
printf 'ok - restore bounds apparent bytes and total transfer time\n'
