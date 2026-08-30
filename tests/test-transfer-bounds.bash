#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
target_lock_pid=''
target_lock_release=''
cleanup() {
  if [[ -n "${target_lock_pid}" ]]; then
    [[ -z "${target_lock_release}" ]] || : > "${target_lock_release}"
    kill "${target_lock_pid}" 2>/dev/null || true
    wait "${target_lock_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

fixture_bin="${test_tmp}/bin"
command_fixture_bin="${test_tmp}/command-bin"
mutation_bin="${test_tmp}/mutation-bin"
stat_bin="${test_tmp}/stat-bin"
virtdev_home="${test_tmp}/virtdev"
ssh_key="${test_tmp}/id"
mkdir -p "${fixture_bin}" "${command_fixture_bin}" "${mutation_bin}" \
  "${stat_bin}" \
  "${virtdev_home}/projects/probe" \
  "${test_tmp}/archive-source"
cp "${repository}/tests/fixtures/ssh-backup" "${fixture_bin}/ssh"
cp "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
# shellcheck disable=SC2016  # generated fixture must retain literal expansions
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'phase=' \
  'verbose=0' \
  'for argument in "$@"; do' \
  '  case "${argument}" in' \
  '    --extract) phase=extraction ;;' \
  '    --list) [[ "${phase}" == extraction ]] || phase=path-listing ;;' \
  '    --verbose) verbose=1 ;;' \
  '  esac' \
  'done' \
  'if [[ "${phase}" == path-listing && "${verbose}" == 1 ]]; then' \
  '  phase=entry-accounting' \
  'fi' \
  'if [[ -n "${TRANSFER_HOST_TAR_STDERR_PHASE:-}"' \
  '    && "${TRANSFER_HOST_TAR_STDERR_PHASE}" == "${phase}" ]]; then' \
  '  if [[ "${TRANSFER_HOST_TAR_CONTROL_STDERR:-0}" == 1 ]]; then' \
  '    printf "\\001host-tar\\177\\n" >&2' \
  '  fi' \
  '  if (( ${TRANSFER_HOST_TAR_STDERR_BYTES:-0} > 0 )); then' \
  '    head -c "${TRANSFER_HOST_TAR_STDERR_BYTES}" /dev/zero | tr "\0" x >&2' \
  '  fi' \
  '  if (( ${TRANSFER_HOST_TAR_DELAY:-0} > 0 )); then' \
  '    sleep "${TRANSFER_HOST_TAR_DELAY}"' \
  '  fi' \
  'fi' \
  'exec /usr/bin/tar "$@"' \
  > "${fixture_bin}/tar"
chmod +x "${fixture_bin}/ssh" "${fixture_bin}/systemctl" \
  "${fixture_bin}/tar"
cp "${repository}/tests/fixtures/ssh-command" "${command_fixture_bin}/ssh"
cp "${repository}/tests/fixtures/systemctl" "${command_fixture_bin}/systemctl"
chmod +x "${command_fixture_bin}/ssh" "${command_fixture_bin}/systemctl"
cp "${repository}/tests/fixtures/rsync-mutate-target" \
  "${mutation_bin}/rsync"
chmod 755 "${mutation_bin}/rsync"
cp "${repository}/tests/fixtures/stat-hang-displaced" "${stat_bin}/stat"
chmod 755 "${stat_bin}/stat"
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
    VIRTDEV_TRANSFER_MAX_TRANSACTION_BYTES=8388608 \
    VIRTDEV_TRANSFER_MAX_ENTRIES=10 \
    VIRTDEV_TRANSFER_TIMEOUT=10 \
    VIRTDEV_TRANSFER_KILL_AFTER=1 \
    BACKUP_TAR_STREAM="${archive}" \
    "$@" \
    "${repository}/bin/virtdev-transfer" probe ":${source}" "${destination}"
}

publication_value() {
  local -r manifest="${1}" key="${2}"
  local record

  while IFS= read -r -d '' record; do
    if [[ "${record}" == "${key}="* ]]; then
      printf '%s\n' "${record#*=}"
      return 0
    fi
  done < "${manifest}"
  return 1
}

recovery_entry_from_output() {
  local -r output="${1}"
  local line

  [[ "$(grep -Fc 'Previous host target retained for recovery: ' \
    "${output}")" == 1 ]] || return 1
  line="$(grep -F 'Previous host target retained for recovery: ' \
    "${output}")" || return 1
  printf '%s\n' \
    "${line#Previous host target retained for recovery: }"
}

printf 'payload\n' > "${test_tmp}/archive-source/item"
tar -C "${test_tmp}/archive-source" -cf "${test_tmp}/file.tar" \
  --transform='s,^item$,payload/item,' item

mkdir -p "${test_tmp}/pax-source/payload/item"
for index in 1 2 3 4; do
  : > "${test_tmp}/pax-source/payload/item/member-${index}"
done
tar --format=pax --pax-option='foo:=guest-controlled-value' \
  -C "${test_tmp}/pax-source" -cf "${test_tmp}/pax-warning.tar" \
  payload/item
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
  lock_acquire_transfer_target "${locked_destination}"
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
if [[ ! -e "${target_lock_ready}" ]] \
    || ! kill -0 "${target_lock_pid}" 2>/dev/null; then
  printf 'target-lock fixture did not acquire the public lock\n' >&2
  exit 1
fi
status=0
run_transfer "${test_tmp}/file.tar" file "${locked_destination}" \
  env VIRTDEV_LOCK_DIRECTORY="${target_lock_directory}" \
  >"${test_tmp}/target-lock.output" 2>&1 || status=$?
: > "${target_lock_release}"
wait "${target_lock_pid}"
target_lock_pid=''
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
  VIRTDEV_TRANSFER_MAX_TRANSACTION_BYTES=8388608 \
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
merge_identity="$(stat -c '%d:%i' -- "${merge_target}")"
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
merge_recovery_entry="$(recovery_entry_from_output \
  "${test_tmp}/merge.output")" || {
  printf 'existing-directory merge did not report its recovery entry\n' >&2
  exit 1
}
merge_recovery_directory="${merge_recovery_entry%/*}"
merge_manifest="${merge_recovery_directory}/publication"
if [[ ! -d "${merge_recovery_entry}" \
      || "$(< "${merge_recovery_entry}/keep")" != keep \
      || -e "${merge_recovery_entry}/new" \
      || "$(stat -c '%d:%i' -- "${merge_recovery_entry}")" \
        != "${merge_identity}" \
      || "$(stat -c '%a' -- "${merge_recovery_directory}")" != 700 \
      || "$(stat -c '%a' -- "${merge_manifest}")" != 600 \
      || "$(publication_value "${merge_manifest}" phase)" != retained \
      || "$(publication_value "${merge_manifest}" target)" \
        != "${merge_target}" \
      || "$(publication_value "${merge_manifest}" entry)" \
        != "${merge_recovery_entry}" \
      || "$(publication_value "${merge_manifest}" previous_type)" \
        != directory \
      || "$(publication_value "${merge_manifest}" previous_identity)" \
        != "${merge_identity}" ]]; then
  printf 'existing-directory recovery state was incomplete or ambiguous\n' >&2
  exit 1
fi
rm -rf --one-file-system -- "${merge_recovery_directory}"

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
trailing_recovery_entry="$(recovery_entry_from_output \
  "${test_tmp}/trailing.output")" || {
  printf 'trailing merge did not report its recovery entry\n' >&2
  exit 1
}
rm -rf --one-file-system -- "${trailing_recovery_entry%/*}"

printf 'replacement\n' > "${test_tmp}/archive-source/item"
tar -C "${test_tmp}/archive-source" -cf "${test_tmp}/replacement.tar" \
  --transform='s,^item$,payload/item,' item
printf 'old\n' > "${destination}"
file_replacement_identity="$(stat -c '%d:%i' -- "${destination}")"
status=0
run_transfer "${test_tmp}/replacement.tar" file "${destination}" \
  >"${test_tmp}/replacement.output" 2>&1 || status=$?
if (( status != 0 )) || [[ "$(< "${destination}")" != replacement ]]; then
  printf 'atomic existing-file replacement failed (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/replacement.output" >&2
  exit 1
fi
file_recovery_entry="$(recovery_entry_from_output \
  "${test_tmp}/replacement.output")" || {
  printf 'existing-file replacement did not report its recovery entry\n' >&2
  exit 1
}
file_recovery_directory="${file_recovery_entry%/*}"
file_manifest="${file_recovery_directory}/publication"
if [[ ! -f "${file_recovery_entry}" \
      || "$(< "${file_recovery_entry}")" != old \
      || "$(stat -c '%d:%i' -- "${file_recovery_entry}")" \
        != "${file_replacement_identity}" \
      || "$(publication_value "${file_manifest}" phase)" != retained \
      || "$(publication_value "${file_manifest}" previous_type)" != file \
      || "$(publication_value "${file_manifest}" previous_identity)" \
        != "${file_replacement_identity}" ]]; then
  printf 'existing-file recovery state was incomplete or ambiguous\n' >&2
  exit 1
fi
rm -rf --one-file-system -- "${file_recovery_directory}"

printf 'ok - overwrites publish complete candidates and retain exact recovery state\n'

(
  late_transfer_pid=''
  late_release="${test_tmp}/late-fd.release"
  # shellcheck disable=SC2329  # invoked by the EXIT trap
  cleanup_late_transfer() {
    : > "${late_release}"
    if [[ "${late_transfer_pid}" =~ ^[0-9]+$ ]] \
        && kill -0 "${late_transfer_pid}" 2>/dev/null; then
      kill "${late_transfer_pid}" 2>/dev/null || true
      wait "${late_transfer_pid}" 2>/dev/null || true
    fi
  }
  trap cleanup_late_transfer EXIT

  late_root="${test_tmp}/late-fd-root"
  late_target="${late_root}/remote-dir"
  late_counter="${test_tmp}/late-fd.counter"
  late_ready="${test_tmp}/late-fd.ready"
  mkdir -p "${late_target}"
  printf 'keep\n' > "${late_target}/keep"
  exec {late_fd}>> "${late_target}/keep"
  status=0
  run_transfer "${test_tmp}/directory.tar" remote-dir "${late_root}" \
    env PATH="${mutation_bin}:${fixture_bin}:${PATH}" \
      TRANSFER_MUTATION_MODE=gate-second \
      TRANSFER_MUTATION_COUNTER="${late_counter}" \
      TRANSFER_MUTATION_READY="${late_ready}" \
      TRANSFER_MUTATION_RELEASE="${late_release}" \
    >"${test_tmp}/late-fd.output" 2>&1 &
  late_transfer_pid=$!
  for _ in {1..1000}; do
    [[ -e "${late_ready}" ]] && break
    kill -0 "${late_transfer_pid}" 2>/dev/null || break
    sleep 0.01
  done
  if [[ ! -e "${late_ready}" ]] \
      || ! kill -0 "${late_transfer_pid}" 2>/dev/null; then
    printf 'late-writer validation gate did not become ready\n' >&2
    cat "${test_tmp}/late-fd.output" >&2
    exit 1
  fi
  printf 'late-writer\n' >&"${late_fd}"
  exec {late_fd}>&-
  : > "${late_release}"
  wait "${late_transfer_pid}" || status=$?
  late_transfer_pid=''

  late_recovery_entry="$(recovery_entry_from_output \
    "${test_tmp}/late-fd.output")" || {
    printf 'late-writer transfer did not report retained recovery state\n' >&2
    exit 1
  }
  if (( status != 0 )) \
      || [[ "$(< "${late_target}/keep")" != keep \
        || "$(< "${late_recovery_entry}/keep")" \
          != $'keep\nlate-writer' \
        || "$(publication_value \
          "${late_recovery_entry%/*}/publication" phase)" != retained ]]; then
    printf 'late writable descriptor update became unreachable (status %d)\n' \
      "${status}" >&2
    cat "${test_tmp}/late-fd.output" >&2
    exit 1
  fi
  rm -rf --one-file-system -- "${late_recovery_entry%/*}"
)

printf 'ok - late writes through displaced handles remain named for recovery\n'

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

nanosecond_root="${test_tmp}/nanosecond-race-root"
nanosecond_target="${nanosecond_root}/remote-dir"
nanosecond_marker="${test_tmp}/nanosecond-race.marker"
mkdir -p "${nanosecond_target}"
printf 'keep\n' > "${nanosecond_target}/keep"
touch -d '@1700000000.100000000' -- "${nanosecond_target}"
status=0
run_transfer "${test_tmp}/directory.tar" remote-dir "${nanosecond_root}" \
  env PATH="${mutation_bin}:${fixture_bin}:${PATH}" \
    TRANSFER_MUTATION_MODE=root-mtime-ns \
    TRANSFER_MUTATION_TARGET="${nanosecond_target}" \
    TRANSFER_MUTATION_MARKER="${nanosecond_marker}" \
    TRANSFER_MUTATION_MTIME='@1700000000.900000000' \
  >"${test_tmp}/nanosecond-race.output" 2>&1 || status=$?
nanosecond_transaction="$(find "${nanosecond_root}" -maxdepth 1 -type d \
  -name '.virtdev-transfer.*' -print -quit)"
if (( status != 15 )) \
    || [[ "$(stat -c '%y' -- "${nanosecond_target}")" \
      != *'.900000000 '* \
      || -e "${nanosecond_target}/new" \
      || -z "${nanosecond_transaction}" ]]; then
  printf 'same-second metadata race was not rolled back safely (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/nanosecond-race.output" >&2
  exit 1
fi
rm -rf --one-file-system -- "${nanosecond_transaction}"

printf 'ok - existing-target races include nanosecond metadata changes\n'
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

exchange_exit_fault="${test_tmp}/publish-exchange-then-exit.so"
cc -std=c99 -shared -fPIC -Wall -Wextra -Wpedantic -Werror \
  -o "${exchange_exit_fault}" \
  "${repository}/tests/support/publish-exchange-then-exit.c"
printf 'uncertain-old\n' > "${destination}"
exchange_exit_marker="${test_tmp}/exchange-exit.marker"
status=0
run_transfer "${test_tmp}/replacement.tar" file "${destination}" \
  LD_PRELOAD="${exchange_exit_fault}" \
  TRANSFER_EXIT_AFTER_EXCHANGE_TARGET="${destination}" \
  TRANSFER_EXIT_AFTER_EXCHANGE_MARKER="${exchange_exit_marker}" \
  >"${test_tmp}/exchange-exit.output" 2>&1 || status=$?
exchange_exit_transaction="$(find "${test_tmp}" -maxdepth 1 -type d \
  -name '.virtdev-transfer.*' -print -quit)"
exchange_exit_manifest="${exchange_exit_transaction}/publication"
exchange_exit_entry=''
[[ -z "${exchange_exit_transaction}" ]] \
  || exchange_exit_entry="$(publication_value \
    "${exchange_exit_manifest}" entry)"
if (( status != 16 )) || [[ ! -e "${exchange_exit_marker}" \
      || "$(< "${destination}")" != replacement \
      || -z "${exchange_exit_transaction}" \
      || ! -f "${exchange_exit_entry}" \
      || "$(< "${exchange_exit_entry}")" != uncertain-old \
      || "$(publication_value "${exchange_exit_manifest}" phase)" \
        != publication-uncertain ]]; then
  printf 'after-exchange publisher death lost recovery state (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/exchange-exit.output" >&2
  exit 1
fi
rm -rf --one-file-system -- "${exchange_exit_transaction}"

printf 'ok - after-exchange publisher death preserves the displaced target\n'

validation_timeout_root="${test_tmp}/validation-timeout-root"
validation_timeout_target="${validation_timeout_root}/remote-dir"
validation_timeout_ready="${test_tmp}/validation-timeout.ready"
mkdir -p "${validation_timeout_target}"
printf 'deadline-original\n' > "${validation_timeout_target}/keep"
status=0
run_transfer "${test_tmp}/directory.tar" remote-dir \
  "${validation_timeout_root}" \
  env PATH="${stat_bin}:${fixture_bin}:${PATH}" \
    VIRTDEV_TRANSFER_TIMEOUT=3 \
    TRANSFER_STAT_HANG_DISPLACED=1 \
    TRANSFER_STAT_HANG_READY="${validation_timeout_ready}" \
  >"${test_tmp}/validation-timeout.output" 2>&1 || status=$?
validation_timeout_transaction="$(find "${validation_timeout_root}" \
  -maxdepth 1 -type d -name '.virtdev-transfer.*' -print -quit)"
if (( status != 12 )) || [[ ! -e "${validation_timeout_ready}" \
      || "$(< "${validation_timeout_target}/keep")" != deadline-original \
      || -e "${validation_timeout_target}/new" \
      || -z "${validation_timeout_transaction}" \
      || "$(publication_value \
        "${validation_timeout_transaction}/publication" phase)" \
        != rolled-back ]]; then
  printf 'post-publication deadline was not reported after rollback (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/validation-timeout.output" >&2
  exit 1
fi
rm -rf --one-file-system -- "${validation_timeout_transaction}"

printf 'ok - post-publication validation deadlines return 12 after rollback\n'

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

transaction_limit_destination="${test_tmp}/transaction-limit-destination"
status=0
run_transfer "${test_tmp}/file.tar" file "${transaction_limit_destination}" \
  VIRTDEV_TRANSFER_MAX_TRANSACTION_BYTES=4096 \
  >"${test_tmp}/transaction-limit.output" 2>&1 || status=$?
if (( status != 11 )) || [[ -e "${transaction_limit_destination}" ]] \
    || ! grep -Fq 'aggregate byte budget' \
      "${test_tmp}/transaction-limit.output"; then
  printf 'aggregate transaction overflow published data (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/transaction-limit.output" >&2
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

printf 'ok - tree, transaction, entry, and depth limits fail before publication\n'

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

pax_destination="${test_tmp}/pax-destination"
status=0
run_transfer "${test_tmp}/pax-warning.tar" tree "${pax_destination}" \
  VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES=512 \
  >"${test_tmp}/pax-success.output" 2>&1 || status=$?
if (( status != 0 )) \
    || [[ ! -f "${pax_destination}/member-4" ]] \
    || ! grep -Fq "Ignoring unknown extended header keyword 'foo'" \
      "${test_tmp}/pax-success.output"; then
  printf 'bounded host tar warnings changed a valid download (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/pax-success.output" >&2
  exit 1
fi

pax_overflow_root="${test_tmp}/pax-overflow-root"
pax_overflow_destination="${pax_overflow_root}/destination"
mkdir "${pax_overflow_root}"
status=0
run_transfer "${test_tmp}/pax-warning.tar" tree \
  "${pax_overflow_destination}" VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES=64 \
  >"${test_tmp}/pax-overflow.output" 2>&1 || status=$?
if (( status != 11 )) || [[ -e "${pax_overflow_destination}" ]] \
    || ! grep -Fq 'output budget during download path listing' \
      "${test_tmp}/pax-overflow.output" \
    || (( $(stat -c '%s' "${test_tmp}/pax-overflow.output") > 4096 )) \
    || find "${pax_overflow_root}" -maxdepth 1 -type d \
      -name '.virtdev-transfer.*' -print -quit | grep -q .; then
  printf 'real PAX diagnostics escaped the host tar output bound (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/pax-overflow.output" >&2
  exit 1
fi

sanitized_root="${test_tmp}/host-tar-sanitized-root"
sanitized_destination="${sanitized_root}/destination"
mkdir "${sanitized_root}"
status=0
run_transfer "${test_tmp}/file.tar" file "${sanitized_destination}" \
  VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES=64 \
  TRANSFER_HOST_TAR_STDERR_PHASE=path-listing \
  TRANSFER_HOST_TAR_CONTROL_STDERR=1 \
  >"${test_tmp}/host-tar-sanitized.output" 2>&1 || status=$?
if (( status != 0 )) || [[ ! -f "${sanitized_destination}" ]] \
    || ! grep -Fq '?host-tar?' "${test_tmp}/host-tar-sanitized.output"; then
  printf 'host tar diagnostics were not sanitized (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/host-tar-sanitized.output" >&2
  exit 1
fi

for phase in path-listing entry-accounting extraction; do
  phase_root="${test_tmp}/host-tar-${phase}-root"
  phase_destination="${phase_root}/destination"
  mkdir "${phase_root}"
  status=0
  run_transfer "${test_tmp}/file.tar" file "${phase_destination}" \
    VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES=64 \
    TRANSFER_HOST_TAR_STDERR_PHASE="${phase}" \
    TRANSFER_HOST_TAR_STDERR_BYTES=1048576 \
    >"${test_tmp}/host-tar-${phase}.output" 2>&1 || status=$?
  if (( status != 11 )) || [[ -e "${phase_destination}" ]] \
      || ! grep -Fq 'Host tar diagnostics exceeded their output budget' \
        "${test_tmp}/host-tar-${phase}.output" \
      || (( $(stat -c '%s' "${test_tmp}/host-tar-${phase}.output") > 4096 )) \
      || find "${phase_root}" -maxdepth 1 -type d \
        -name '.virtdev-transfer.*' -print -quit | grep -q .; then
    printf 'host tar %s diagnostics escaped their bound (status %d)\n' \
      "${phase}" "${status}" >&2
    cat "${test_tmp}/host-tar-${phase}.output" >&2
    exit 1
  fi
done

tar_timeout_root="${test_tmp}/host-tar-timeout-root"
tar_timeout_destination="${tar_timeout_root}/destination"
mkdir "${tar_timeout_root}"
status=0
run_transfer "${test_tmp}/file.tar" file "${tar_timeout_destination}" \
  VIRTDEV_TRANSFER_TIMEOUT=2 \
  TRANSFER_HOST_TAR_STDERR_PHASE=path-listing TRANSFER_HOST_TAR_DELAY=5 \
  >"${test_tmp}/host-tar-timeout.output" 2>&1 || status=$?
if (( status != 12 )) || [[ -e "${tar_timeout_destination}" ]] \
    || ! grep -Fq 'path validation exceeded the transfer deadline' \
      "${test_tmp}/host-tar-timeout.output" \
    || find "${tar_timeout_root}" -maxdepth 1 -type d \
      -name '.virtdev-transfer.*' -print -quit | grep -q .; then
  printf 'host tar escaped the absolute transfer deadline (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/host-tar-timeout.output" >&2
  exit 1
fi

if find "${test_tmp}" -type d -name '.virtdev-transfer.*' \
    -print -quit | grep -q .; then
  printf 'failed bounded downloads stranded private stages\n' >&2
  exit 1
fi

printf 'ok - transport diagnostics, failures, and total time are bounded\n'
printf 'ok - every host tar decoder has bounded sanitized diagnostics\n'
