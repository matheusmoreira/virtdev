#!/usr/bin/env bash
# shellcheck disable=SC2016  # child namespace script

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
  local -r guest="${1}" maximum_bytes="${2}" maximum_entries="${3}"
  local -r timeout_seconds="${4}"
  shift 4
  mkdir -p "${guest}"
  PATH="${fixture_bin}:${PATH}" \
    HOME="${test_tmp}" \
    XDG_CONFIG_HOME="${test_tmp}/config" \
    NO_COLOR=1 \
    SYSTEMCTL_ACTIVE_STATE=active \
    VIRTDEV_HOME="${virtdev_home}" \
    VIRTDEV_SSH_KEY="${ssh_key}" \
    VIRTDEV_RESTORE_MAX_BYTES="${maximum_bytes}" \
    VIRTDEV_RESTORE_MAX_ENTRIES="${maximum_entries}" \
    VIRTDEV_RESTORE_TIMEOUT="${timeout_seconds}" \
    VIRTDEV_RESTORE_KILL_AFTER=1 \
    RESTORE_GUEST_ROOT="${guest}" \
    "$@" \
    "${repository}/bin/virtdev-restore" probe 2026-08-28/12-00-00
}

guest="${test_tmp}/guest"
logical_bytes=$((
  $(stat -c '%s' "${snapshot}/tree/real/sub/file")
  + $(stat -c '%s' "${snapshot}/tree/hard-one")
  + $(stat -c '%s' "${snapshot}/tree/sparse")
))
status=0
run_restore "${guest}" "${logical_bytes}" 100 10 \
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
run_restore "${budget_guest}" 1048576 100 10 \
  >"${test_tmp}/budget.output" 2>&1 || status=$?
if (( status != 19 )) \
    || find "${budget_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore apparent-byte budget failed open (status %d)\n' \
    "${status}" >&2
  exit 1
fi

boundary_guest="${test_tmp}/boundary-guest"
status=0
run_restore "${boundary_guest}" "$(( logical_bytes - 1 ))" 100 10 \
  >"${test_tmp}/boundary.output" 2>&1 || status=$?
if (( status != 19 )) \
    || find "${boundary_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore accepted a snapshot one byte over budget (status %d)\n' \
    "${status}" >&2
  exit 1
fi

mkdir "${snapshot}/tree/many"
: > "${snapshot}/tree/many/empty"
for entry in 1 2 3 4 5; do
  ln "${snapshot}/tree/many/empty" "${snapshot}/tree/many/hard-${entry}"
done
printf 'many/\n' >> "${snapshot}/manifest"

entry_guest="${test_tmp}/entry-guest"
entry_ssh_started="${test_tmp}/entry-ssh-started"
status=0
run_restore "${entry_guest}" "${logical_bytes}" 10 10 \
  env RESTORE_SSH_STARTED_FILE="${entry_ssh_started}" \
  >"${test_tmp}/entry.output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${entry_ssh_started}" ]] \
    || find "${entry_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore entry budget failed before guest transfer (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/entry.output" >&2
  exit 1
fi

outside="${test_tmp}/outside"
mkdir "${outside}"
printf 'host secret\n' > "${outside}/secret"
ln -s "${outside}" "${snapshot}/tree/escape"
printf 'escape/secret\n' >> "${snapshot}/manifest"
symlink_guest="${test_tmp}/symlink-guest"
symlink_ssh_started="${test_tmp}/symlink-ssh-started"
status=0
run_restore "${symlink_guest}" "${logical_bytes}" 100 10 \
  env RESTORE_SSH_STARTED_FILE="${symlink_ssh_started}" \
  >"${test_tmp}/symlink.output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${symlink_ssh_started}" ]] \
    || ! grep -Fq 'symlinked source path' "${test_tmp}/symlink.output" \
    || find "${symlink_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore followed an intermediate snapshot symlink (status %d)\n' \
    "${status}" >&2
  exit 1
fi
sed -i '\|^escape/secret$|d' "${snapshot}/manifest"
unlink "${snapshot}/tree/escape"

mount_source="${test_tmp}/mount-source"
mount_target="${snapshot}/tree/mounted"
mount_guest="${test_tmp}/mount-guest"
mount_ssh_started="${test_tmp}/mount-ssh-started"
mkdir "${mount_source}" "${mount_target}" "${mount_guest}"
printf 'mounted payload\n' > "${mount_source}/payload"
printf 'mounted/\n' >> "${snapshot}/manifest"
status=0
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/config" \
NO_COLOR=1 \
SYSTEMCTL_ACTIVE_STATE=active \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_SSH_KEY="${ssh_key}" \
VIRTDEV_RESTORE_MAX_BYTES="${logical_bytes}" \
VIRTDEV_RESTORE_MAX_ENTRIES=100 \
VIRTDEV_RESTORE_TIMEOUT=10 \
VIRTDEV_RESTORE_KILL_AFTER=1 \
RESTORE_GUEST_ROOT="${mount_guest}" \
RESTORE_SSH_STARTED_FILE="${mount_ssh_started}" \
  unshare --user --map-root-user --mount bash -c '
    set -euo pipefail
    mount --bind "${1}" "${2}"
    exec "${3}" probe 2026-08-28/12-00-00
  ' _ "${mount_source}" "${mount_target}" \
    "${repository}/bin/virtdev-restore" \
    >"${test_tmp}/mount.output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${mount_ssh_started}" ]] \
    || ! grep -Fq 'mounted filesystem' "${test_tmp}/mount.output" \
    || find "${mount_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore crossed a nested snapshot mount (status %d)\n' \
    "${status}" >&2
  exit 1
fi
sed -i '\|^mounted/$|d' "${snapshot}/manifest"

timeout_guest="${test_tmp}/timeout-guest"
timeout_pid_file="${test_tmp}/timeout.pid"
status=0
run_restore "${timeout_guest}" "${logical_bytes}" 100 2 \
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
printf 'ok - restore bounds regular logical bytes, entry count, and total time\n'
