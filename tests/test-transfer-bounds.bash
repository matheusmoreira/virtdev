#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
command_fixture_bin="${test_tmp}/command-bin"
mutation_bin="${test_tmp}/mutation-bin"
virtdev_home="${test_tmp}/virtdev"
ssh_key="${test_tmp}/id"
mkdir -p "${fixture_bin}" "${command_fixture_bin}" "${mutation_bin}" \
  "${virtdev_home}/projects/probe" \
  "${test_tmp}/archive-source"
cp "${repository}/tests/fixtures/ssh-backup" "${fixture_bin}/ssh"
cp "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
chmod +x "${fixture_bin}/ssh" "${fixture_bin}/systemctl"
cp "${repository}/tests/fixtures/ssh-command" "${command_fixture_bin}/ssh"
cp "${repository}/tests/fixtures/systemctl" "${command_fixture_bin}/systemctl"
chmod +x "${command_fixture_bin}/ssh" "${command_fixture_bin}/systemctl"
cp "${repository}/tests/fixtures/rsync-mutate-target" \
  "${mutation_bin}/rsync"
chmod 755 "${mutation_bin}/rsync"
printf '2222\n' > "${virtdev_home}/projects/probe/port"
printf 'ssh-host-identity=1\n' \
  > "${virtdev_home}/projects/probe/guest-contract"
printf 'test private key\n' > "${ssh_key}"
chmod 600 "${ssh_key}"
(
  # shellcheck disable=SC2030  # project identity setup is isolated
  export VIRTDEV_HOME="${virtdev_home}"
  # shellcheck disable=SC1090
  source "${repository}/lib/virtdev/import"
  import ssh
  ssh_host_identity_ensure probe
)

run_transfer() {
  local -r archive="${1}" source="${2}" destination="${3}"
  shift 3
  env \
    PATH="${fixture_bin}:${PATH}" \
    HOME="${test_tmp}" \
    XDG_CONFIG_HOME="${test_tmp}/config" \
    NO_COLOR=1 \
    SYSTEMCTL_ACTIVE_STATE=active \
    VIRTDEV_HOME="${virtdev_home}" \
    VIRTDEV_SSH_KEY="${ssh_key}" \
    VIRTDEV_TRANSFER_MAX_BYTES=1024 \
    VIRTDEV_TRANSFER_MAX_ALLOCATED_BYTES=1048576 \
    VIRTDEV_TRANSFER_MAX_ENTRIES=10 \
    VIRTDEV_TRANSFER_TIMEOUT=10 \
    VIRTDEV_TRANSFER_KILL_AFTER=1 \
    BACKUP_TAR_STREAM="${archive}" \
    "$@" \
    "${repository}/bin/virtdev-transfer" probe ":${source}" "${destination}"
}

printf 'payload\n' > "${test_tmp}/archive-source/item"
tar -C "${test_tmp}/archive-source" -cf "${test_tmp}/file.tar" \
  --transform='s,^item$,payload/item,' item
destination="${test_tmp}/downloaded"
status=0
run_transfer "${test_tmp}/file.tar" file "${destination}" \
  >"${test_tmp}/success.output" 2>&1 || status=$?
if (( status != 0 )) || [[ ! -f "${destination}" ]] \
    || [[ "$(< "${destination}")" != payload ]]; then
  printf 'bounded file download failed (status %d)\n' "${status}" >&2
  cat "${test_tmp}/success.output" >&2
  exit 1
fi
if find "${test_tmp}" -maxdepth 2 -type d \
    -name '.virtdev-transfer.*' -print -quit | grep -q .; then
  printf 'successful download stranded its private stage\n' >&2
  exit 1
fi

printf 'ok - bounded download publishes one stable file atomically\n'

locked_destination="${test_tmp}/locked-destination"
target_lock_directory="${test_tmp}/target-locks"
target_lock_ready="${test_tmp}/target-lock.ready"
target_lock_release="${test_tmp}/target-lock.release"
(
  export HOME="${test_tmp}"
  # shellcheck disable=SC2031  # lock holder is isolated
  export VIRTDEV_HOME="${virtdev_home}"
  export VIRTDEV_LOCK_DIRECTORY="${target_lock_directory}"
  # shellcheck disable=SC1090
  source "${repository}/lib/virtdev/import"
  import lock
  target_lock_path="$(lock_identity_path transfer-target \
    "${locked_destination}")"
  lock_prepare_control_directory
  lock_prepare_file "${target_lock_path}"
  exec 6>>"${target_lock_path}"
  flock -n 6
  : > "${target_lock_ready}"
  while [[ ! -e "${target_lock_release}" ]]; do
    sleep 0.01
  done
) &
target_lock_pid=$!
for _ in {1..1000}; do
  [[ -e "${target_lock_ready}" ]] && break
  kill -0 "${target_lock_pid}" 2>/dev/null || break
  sleep 0.01
done
status=0
run_transfer "${test_tmp}/file.tar" file "${locked_destination}" \
  env VIRTDEV_LOCK_DIRECTORY="${target_lock_directory}" \
  >"${test_tmp}/target-lock.output" 2>&1 || status=$?
: > "${target_lock_release}"
wait "${target_lock_pid}"
if (( status != 75 )) || [[ -e "${locked_destination}" ]]; then
  printf 'target-lock contention was not fail-safe (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/target-lock.output" >&2
  exit 1
fi

printf 'ok - concurrent publications to one host target are serialized\n'

mkdir -p "${test_tmp}/live-guest/tree/sub"
printf 'live\n' > "${test_tmp}/live-guest/tree/sub/file"
live_destination="${test_tmp}/live-destination"
status=0
env \
  PATH="${command_fixture_bin}:${PATH}" \
  HOME="${test_tmp}" \
  XDG_CONFIG_HOME="${test_tmp}/config" \
  NO_COLOR=1 \
  SYSTEMCTL_ACTIVE_STATE=active \
  VIRTDEV_HOME="${virtdev_home}" \
  VIRTDEV_SSH_KEY="${ssh_key}" \
  VIRTDEV_TRANSFER_MAX_BYTES=1024 \
  VIRTDEV_TRANSFER_MAX_ALLOCATED_BYTES=1048576 \
  VIRTDEV_TRANSFER_MAX_ENTRIES=10 \
  VIRTDEV_TRANSFER_TIMEOUT=10 \
  VIRTDEV_TRANSFER_KILL_AFTER=1 \
  "${repository}/bin/virtdev-transfer" probe \
    ":${test_tmp}/live-guest/tree/" "${live_destination}" \
    >"${test_tmp}/live.output" 2>&1 || status=$?
if (( status != 0 )) \
    || [[ "$(< "${live_destination}/sub/file")" != live ]]; then
  printf 'real remote tar command path failed (status %d)\n' "${status}" >&2
  cat "${test_tmp}/live.output" >&2
  exit 1
fi

printf 'ok - remote tar command captures exact trailing-slash contents\n'

mkdir -p "${test_tmp}/directory-source/item"
printf 'new\n' > "${test_tmp}/directory-source/item/new"
tar -C "${test_tmp}/directory-source" -cf "${test_tmp}/directory.tar" \
  --transform='s,^item,payload/item,' item
merge_root="${test_tmp}/merge-root"
merge_target="${merge_root}/remote-dir"
mkdir -p "${merge_target}"
printf 'keep\n' > "${merge_target}/keep"
status=0
run_transfer "${test_tmp}/directory.tar" remote-dir "${merge_root}" \
  >"${test_tmp}/merge.output" 2>&1 || status=$?
if (( status != 0 )) || [[ "$(< "${merge_target}/keep")" != keep ]] \
    || [[ "$(< "${merge_target}/new")" != new ]]; then
  printf 'atomic existing-directory merge failed (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/merge.output" >&2
  exit 1
fi

trailing_target="${test_tmp}/trailing-target"
mkdir "${trailing_target}"
printf 'existing\n' > "${trailing_target}/existing"
status=0
run_transfer "${test_tmp}/directory.tar" remote-dir/ "${trailing_target}" \
  >"${test_tmp}/trailing.output" 2>&1 || status=$?
if (( status != 0 )) || [[ "$(< "${trailing_target}/existing")" != existing ]] \
    || [[ "$(< "${trailing_target}/new")" != new ]]; then
  printf 'trailing-slash directory merge failed (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/trailing.output" >&2
  exit 1
fi

printf 'replacement\n' > "${test_tmp}/archive-source/item"
tar -C "${test_tmp}/archive-source" -cf "${test_tmp}/replacement.tar" \
  --transform='s,^item$,payload/item,' item
printf 'old\n' > "${destination}"
status=0
run_transfer "${test_tmp}/replacement.tar" file "${destination}" \
  >"${test_tmp}/replacement.output" 2>&1 || status=$?
if (( status != 0 )) || [[ "$(< "${destination}")" != replacement ]]; then
  printf 'atomic existing-file replacement failed (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/replacement.output" >&2
  exit 1
fi

printf 'ok - directory merges and file replacement publish complete candidates\n'

nested_race_root="${test_tmp}/nested-race-root"
nested_race_target="${nested_race_root}/remote-dir"
mkdir -p "${nested_race_target}"
printf 'keep\n' > "${nested_race_target}/keep"
nested_race_marker="${test_tmp}/nested-race.marker"
status=0
run_transfer "${test_tmp}/directory.tar" remote-dir "${nested_race_root}" \
  env PATH="${mutation_bin}:${fixture_bin}:${PATH}" \
    TRANSFER_MUTATION_MODE=nested \
    TRANSFER_MUTATION_TARGET="${nested_race_target}" \
    TRANSFER_MUTATION_MARKER="${nested_race_marker}" \
  >"${test_tmp}/nested-race.output" 2>&1 || status=$?
nested_race_transaction="$(find "${nested_race_root}" -maxdepth 1 -type d \
  -name '.virtdev-transfer.*' -print -quit)"
if (( status != 15 )) \
    || [[ "$(< "${nested_race_target}/keep")" != writer-update \
      || "$(< "${nested_race_target}/writer-added")" != writer-added \
      || -e "${nested_race_target}/new" \
      || -z "${nested_race_transaction}" ]]; then
  printf 'nested destination race was not rolled back safely (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/nested-race.output" >&2
  exit 1
fi
rm -rf --one-file-system -- "${nested_race_transaction}"

replacement_race_root="${test_tmp}/replacement-race-root"
replacement_race_target="${replacement_race_root}/remote-dir"
mkdir -p "${replacement_race_target}"
printf 'original\n' > "${replacement_race_target}/original"
replacement_race_marker="${test_tmp}/replacement-race.marker"
status=0
run_transfer "${test_tmp}/directory.tar" remote-dir \
  "${replacement_race_root}" \
  env PATH="${mutation_bin}:${fixture_bin}:${PATH}" \
    TRANSFER_MUTATION_MODE=replace \
    TRANSFER_MUTATION_TARGET="${replacement_race_target}" \
    TRANSFER_MUTATION_MARKER="${replacement_race_marker}" \
  >"${test_tmp}/replacement-race.output" 2>&1 || status=$?
replacement_race_transaction="$(find "${replacement_race_root}" \
  -maxdepth 1 -type d -name '.virtdev-transfer.*' -print -quit)"
if (( status != 15 )) \
    || [[ "$(< "${replacement_race_target}/replacement")" \
        != writer-replacement \
      || -e "${replacement_race_target}/new" \
      || "$(< "${replacement_race_target}.writer-old/original")" != original \
      || -z "${replacement_race_transaction}" ]]; then
  printf 'destination replacement race was not rolled back safely (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/replacement-race.output" >&2
  exit 1
fi
rm -rf --one-file-system -- "${replacement_race_transaction}"

file_mutation_library="${test_tmp}/publish-mutate-file.so"
cc -std=c99 -shared -fPIC -Wall -Wextra -Wpedantic -Werror \
  -o "${file_mutation_library}" \
  "${repository}/tests/support/publish-mutate-file.c"
printf 'old\n' > "${destination}"
file_race_marker="${test_tmp}/file-race.marker"
status=0
run_transfer "${test_tmp}/replacement.tar" file "${destination}" \
  env LD_PRELOAD="${file_mutation_library}" \
    TRANSFER_MUTATION_TARGET="${destination}" \
    TRANSFER_MUTATION_MARKER="${file_race_marker}" \
  >"${test_tmp}/file-race.output" 2>&1 || status=$?
file_race_transaction="$(find "${test_tmp}" -maxdepth 1 -type d \
  -name '.virtdev-transfer.*' -print -quit)"
if (( status != 15 )) || [[ "$(< "${destination}")" != writer-update \
      || -z "${file_race_transaction}" ]]; then
  printf 'existing-file race was not rolled back safely (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/file-race.output" >&2
  exit 1
fi
rm -rf --one-file-system -- "${file_race_transaction}"

printf 'ok - existing-target races roll back without discarding writer data\n'

sync_fault="${test_tmp}/publish-sync-fail.so"
cc -shared -fPIC -Wall -Wextra -Werror \
  -o "${sync_fault}" "${repository}/tests/support/publish-sync-fail.c"
printf 'pre-sync-failure\n' > "${destination}"
status=0
run_transfer "${test_tmp}/replacement.tar" file "${destination}" \
  LD_PRELOAD="${sync_fault}" >"${test_tmp}/publish-sync.output" 2>&1 \
  || status=$?
preserved_transaction="$(find "${test_tmp}" -maxdepth 2 -type d \
  -name '.virtdev-transfer.*' -print -quit)"
if (( status != 16 )) || [[ "$(< "${destination}")" != replacement ]] \
    || [[ -z "${preserved_transaction}" ]]; then
  printf 'committed publication sync failure was misclassified (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/publish-sync.output" >&2
  exit 1
fi
rm -rf --one-file-system -- "${preserved_transaction}"

printf 'ok - committed publication sync failures preserve recovery state\n'

mkdir -p "${test_tmp}/oversize-source"
head -c 1025 /dev/zero | tr '\0' x > "${test_tmp}/oversize-source/item"
tar -C "${test_tmp}/oversize-source" -cf "${test_tmp}/oversize.tar" \
  --transform='s,^item$,payload/item,' item
printf 'unchanged\n' > "${destination}"
status=0
run_transfer "${test_tmp}/oversize.tar" file "${destination}" \
  >"${test_tmp}/oversize.output" 2>&1 || status=$?
if (( status != 11 )) || [[ "$(< "${destination}")" != unchanged ]]; then
  printf 'logical-byte overflow changed the destination (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/oversize.output" >&2
  exit 1
fi

mkdir -p "${test_tmp}/entries-source/item"
for entry in 1 2 3; do
  : > "${test_tmp}/entries-source/item/${entry}"
done
tar -C "${test_tmp}/entries-source" -cf "${test_tmp}/entries.tar" \
  --transform='s,^item,payload/item,' item
entry_destination="${test_tmp}/entry-destination"
status=0
run_transfer "${test_tmp}/entries.tar" tree "${entry_destination}" \
  VIRTDEV_TRANSFER_MAX_ENTRIES=2 \
  >"${test_tmp}/entries.output" 2>&1 || status=$?
if (( status != 11 )) || [[ -e "${entry_destination}" ]]; then
  printf 'entry overflow published a destination (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/entries.output" >&2
  exit 1
fi

deep_relative=item
for (( depth = 0; depth < 129; depth++ )); do
  deep_relative+='/d'
done
mkdir -p "${test_tmp}/deep-source/${deep_relative}"
printf 'deep\n' > "${test_tmp}/deep-source/${deep_relative}/file"
tar -C "${test_tmp}/deep-source" -cf "${test_tmp}/deep.tar" \
  --transform='s,^item,payload/item,' item
status=0
run_transfer "${test_tmp}/deep.tar" tree "${entry_destination}" \
  VIRTDEV_TRANSFER_MAX_ENTRIES=200 \
  VIRTDEV_TRANSFER_MAX_ALLOCATED_BYTES=4194304 \
  >"${test_tmp}/deep.output" 2>&1 || status=$?
if (( status != 11 )) || [[ -e "${entry_destination}" ]] \
    || ! grep -Fq 'nesting depth' "${test_tmp}/deep.output"; then
  printf 'deep archive path was not rejected before extraction (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/deep.output" >&2
  exit 1
fi

printf 'ok - aggregate byte, entry, and depth limits fail before publication\n'

mkdir -p "${test_tmp}/internal-link-source/item"
printf 'linked\n' > "${test_tmp}/internal-link-source/item/data"
ln -s data "${test_tmp}/internal-link-source/item/link"
tar -C "${test_tmp}/internal-link-source" \
  -cf "${test_tmp}/internal-link.tar" \
  --transform='flags=rh;s,^item,payload/item,' item
internal_link_destination="${test_tmp}/internal-link-destination"
status=0
run_transfer "${test_tmp}/internal-link.tar" tree \
  "${internal_link_destination}" >"${test_tmp}/internal-link.output" 2>&1 \
  || status=$?
if (( status != 0 )) \
    || [[ "$(readlink -- "${internal_link_destination}/link")" != data ]] \
    || [[ "$(< "${internal_link_destination}/data")" != linked ]]; then
  printf 'confined internal symlink was not preserved (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/internal-link.output" >&2
  exit 1
fi

mkdir -p "${test_tmp}/symlink-source/item"
ln -s ../../escape "${test_tmp}/symlink-source/item/link"
tar -C "${test_tmp}/symlink-source" -cf "${test_tmp}/symlink.tar" \
  --transform='flags=rh;s,^item,payload/item,' item
unsafe_destination="${test_tmp}/unsafe-destination"
status=0
run_transfer "${test_tmp}/symlink.tar" tree "${unsafe_destination}" \
  >"${test_tmp}/symlink.output" 2>&1 || status=$?
if (( status != 14 )) || [[ -e "${unsafe_destination}" ]]; then
  printf 'escaping symlink was not rejected before publication (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/symlink.output" >&2
  exit 1
fi

mkdir -p "${test_tmp}/special-source/item"
mkfifo "${test_tmp}/special-source/item/fifo"
tar -C "${test_tmp}/special-source" -cf "${test_tmp}/special.tar" \
  --transform='s,^item,payload/item,' item
status=0
run_transfer "${test_tmp}/special.tar" tree "${unsafe_destination}" \
  >"${test_tmp}/special.output" 2>&1 || status=$?
if (( status != 14 )) || [[ -e "${unsafe_destination}" ]]; then
  printf 'special archive member was not rejected (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/special.output" >&2
  exit 1
fi

mkdir -p "${test_tmp}/root-link-source"
ln -s sibling "${test_tmp}/root-link-source/item"
tar -C "${test_tmp}/root-link-source" -cf "${test_tmp}/root-link.tar" \
  --transform='flags=rh;s,^item$,payload/item,' item
status=0
run_transfer "${test_tmp}/root-link.tar" link "${unsafe_destination}" \
  >"${test_tmp}/root-link.output" 2>&1 || status=$?
if (( status != 14 )) || [[ -e "${unsafe_destination}" ]]; then
  printf 'unconfined root symlink was not rejected (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/root-link.output" >&2
  exit 1
fi

cp "${test_tmp}/file.tar" "${test_tmp}/trailing-data.tar"
printf 'trailing-data' >> "${test_tmp}/trailing-data.tar"
status=0
run_transfer "${test_tmp}/trailing-data.tar" file "${unsafe_destination}" \
  >"${test_tmp}/trailing-data.output" 2>&1 || status=$?
if (( status != 14 )) || [[ -e "${unsafe_destination}" ]]; then
  printf 'archive trailing data was not rejected (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/trailing-data.output" >&2
  exit 1
fi

cp "${test_tmp}/file.tar" "${test_tmp}/duplicate.tar"
tar -C "${test_tmp}/archive-source" -rf "${test_tmp}/duplicate.tar" \
  --transform='s,^item$,payload/item,' item
status=0
run_transfer "${test_tmp}/duplicate.tar" file "${unsafe_destination}" \
  >"${test_tmp}/duplicate.output" 2>&1 || status=$?
if (( status != 14 )) || [[ -e "${unsafe_destination}" ]]; then
  printf 'duplicate archive member was not rejected (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/duplicate.output" >&2
  exit 1
fi

printf 'ok - links are confined and malformed archive structure is rejected\n'

status=0
run_transfer "${test_tmp}/file.tar" file "${unsafe_destination}" \
  BACKUP_SSH_STATUS=1 >"${test_tmp}/remote-failure.output" 2>&1 \
  || status=$?
if (( status != 13 )) || [[ -e "${unsafe_destination}" ]]; then
  printf 'remote tar failure published a valid-looking archive (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/remote-failure.output" >&2
  exit 1
fi

status=0
run_transfer "${test_tmp}/file.tar" file "${unsafe_destination}" \
  VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES=64 BACKUP_STDERR_BYTES=65 \
  >"${test_tmp}/stderr.output" 2>&1 || status=$?
if (( status != 11 )) || [[ -e "${unsafe_destination}" ]]; then
  printf 'diagnostic overflow was not bounded before publication (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/stderr.output" >&2
  exit 1
fi

status=0
run_transfer "${test_tmp}/file.tar" file "${unsafe_destination}" \
  VIRTDEV_TRANSFER_TIMEOUT=1 BACKUP_STREAM_DELAY=5 \
  >"${test_tmp}/timeout.output" 2>&1 || status=$?
if (( status != 12 )) || [[ -e "${unsafe_destination}" ]]; then
  printf 'absolute transfer timeout was not enforced (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/timeout.output" >&2
  exit 1
fi

if find "${test_tmp}" -type d -name '.virtdev-transfer.*' \
    -print -quit | grep -q .; then
  printf 'failed bounded downloads stranded private stages\n' >&2
  exit 1
fi

printf 'ok - transport diagnostics, failures, and total time are bounded\n'
