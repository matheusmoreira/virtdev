#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"

cleanup() {
  mountpoint -q "${test_tmp}/home/late tree/mounted" \
    && umount "${test_tmp}/home/late tree/mounted"
  mountpoint -q "${test_tmp}/home/store/projects/probe/mounted" \
    && umount "${test_tmp}/home/store/projects/probe/mounted"
  mountpoint -q "${test_tmp}/home/cache/mounted" \
    && umount "${test_tmp}/home/cache/mounted"
  rm -rf --one-file-system -- "${test_tmp}"
}
trap cleanup EXIT

if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'destructive mount tests require an unprivileged user/mount namespace\n' >&2
  exit 1
fi

export DESTRUCTIVE_TEST_REPOSITORY="${repository}"
export DESTRUCTIVE_TEST_TMP="${test_tmp}"

unshare --user --map-root-user --mount bash -s <<'NAMESPACE'
set -euo pipefail

test_home="${DESTRUCTIVE_TEST_TMP}/home"
store="${test_home}/store"
cache="${test_home}/cache"
locks="${test_home}/locks"
output="${DESTRUCTIVE_TEST_TMP}/output"
fixture_bin="${DESTRUCTIVE_TEST_TMP}/bin"
mkdir -p "${fixture_bin}"
export PATH="${fixture_bin}:${DESTRUCTIVE_TEST_REPOSITORY}/tests/fixtures:${PATH}"

# shellcheck disable=SC1090
source "${DESTRUCTIVE_TEST_REPOSITORY}/lib/virtdev/mount"

helper_source="${test_home}/helper source"
helper_tree="${test_home}/helper tree"
helper_mount="${helper_tree}/mounted"
mkdir -p "${helper_source}" "${helper_mount}"
printf 'outside helper tree\n' > "${helper_source}/sentinel"
mount --bind "${helper_source}" "${helper_mount}"

mount_path=""
status=0
mount_remove_tree "${helper_tree}" mount_path || status=$?
if (( status != 1 )) || [[ "${mount_path}" != "${helper_mount}" ]] \
    || [[ ! -f "${helper_source}/sentinel" ]]; then
  printf 'mount-aware helper did not preserve a mounted tree (status %d)\n' \
    "${status}" >&2
  exit 1
fi
guidance="$(mount_cleanup_guidance "${helper_tree}")"
printf -v quoted_helper_mount '%q' "${helper_mount}"
if [[ "${guidance}" != *"umount -- ${quoted_helper_mount}"* \
      || "${guidance}" == *'rm -rf'* ]]; then
  printf 'mounted-tree guidance was destructive or incomplete\n%s\n' \
    "${guidance}" >&2
  exit 1
fi
umount "${helper_mount}"
mount_remove_tree "${helper_tree}" mount_path
[[ ! -e "${helper_tree}" && -f "${helper_source}/sentinel" ]]

late_source="${test_home}/late source"
late_tree="${test_home}/late tree"
late_mount="${late_tree}/mounted"
late_gate="${DESTRUCTIVE_TEST_TMP}/remove-tree-gate.so"
mkdir -p "${late_source}" "${late_mount}"
printf 'outside late tree\n' > "${late_source}/sentinel"
gcc -std=c99 -Wall -Wextra -Wpedantic -Werror -shared -fPIC \
  -o "${late_gate}" \
  "${DESTRUCTIVE_TEST_REPOSITORY}/tests/support/remove-tree-gate.c"
status=0
mount_path="$(
  REMOVE_TREE_GATE_NAME=mounted \
  REMOVE_TREE_GATE_SOURCE="${late_source}" \
  REMOVE_TREE_GATE_TARGET="${late_mount}" \
  LD_PRELOAD="${late_gate}" \
    "${DESTRUCTIVE_TEST_REPOSITORY}/libexec/virtdev/virtdev-remove-tree" \
      "${late_tree}"
)" || status=$?
if (( status != 1 )) || [[ "${mount_path}" != "${late_mount}" ]] \
    || [[ ! -f "${late_source}/sentinel" ]]; then
  printf 'descriptor remover crossed a late bind mount (status %d)\n' \
    "${status}" >&2
  exit 1
fi
umount "${late_mount}"
mount_remove_tree "${late_tree}" mount_path
[[ ! -e "${late_tree}" && -f "${late_source}/sentinel" ]]

mkdir -p "${store}/projects/probe/mounted" "${cache}" "${locks}"
printf 'project data\n' > "${store}/projects/probe/disk"
mount -t tmpfs tmpfs "${store}/projects/probe/mounted"
printf 'mounted project data\n' > "${store}/projects/probe/mounted/sentinel"

status=0
HOME="${test_home}" \
VIRTDEV_HOME="${store}" \
VIRTDEV_LOCK_DIRECTORY="${locks}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
NO_COLOR=1 \
  "${DESTRUCTIVE_TEST_REPOSITORY}/bin/virtdev-destroy" --yes probe \
    >"${output}" 2>&1 || status=$?
if (( status != 6 )); then
  printf 'destroy accepted a nested filesystem (status %d)\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq "${store}/projects/probe/mounted" "${output}"
[[ -f "${store}/projects/probe/disk" \
   && -f "${store}/projects/probe/mounted/sentinel" ]]
umount "${store}/projects/probe/mounted"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'case "$*" in' \
  '  "-u +%Y-%m-%d") printf "2026-08-29\\n" ;;' \
  '  "-u +%H-%M-%S") printf "12-00-00\\n" ;;' \
  '  *) exec /usr/bin/date "$@" ;;' \
  'esac' > "${fixture_bin}/date"
chmod +x "${fixture_bin}/date"

printf 'data\n' > "${store}/projects/probe/manifest"
printf '2222\n' > "${store}/projects/probe/port"
printf '1\n' > "${store}/projects/probe/generation"
printf 'test key\n' > "${test_home}/id"
chmod 600 "${test_home}/id"
backup_partial="${store}/backups/probe/2026-08-29/12-00-00.partial"
backup_source="${test_home}/backup-source"
backup_mount="${backup_partial}/mounted"
mkdir -p "${backup_source}" "${backup_mount}"
printf 'outside backup\n' > "${backup_source}/sentinel"
mount --bind "${backup_source}" "${backup_mount}"

status=0
HOME="${test_home}" \
VIRTDEV_HOME="${store}" \
VIRTDEV_LOCK_DIRECTORY="${locks}" \
VIRTDEV_SSH_KEY="${test_home}/id" \
SYSTEMCTL_ACTIVE_STATE=active \
NO_COLOR=1 \
  "${DESTRUCTIVE_TEST_REPOSITORY}/bin/virtdev-backup" probe \
    >"${output}" 2>&1 || status=$?
if (( status != 10 )); then
  printf 'backup accepted a stale partial snapshot (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq "umount -- ${backup_mount}" "${output}"
if grep -Fq 'rm -rf' "${output}"; then
  printf 'backup advised recursive removal of a mount-bearing partial\n' >&2
  cat "${output}" >&2
  exit 1
fi
[[ -f "${backup_source}/sentinel" ]]
umount "${backup_mount}"

bind_source="${test_home}/bind-source"
bind_target="${cache}/mounted"
mkdir -p "${bind_source}" "${bind_target}"
printf 'outside cache\n' > "${bind_source}/sentinel"
mount --bind "${bind_source}" "${bind_target}"

status=0
printf 'nuke\n' | HOME="${test_home}" \
  VIRTDEV_HOME="${store}" \
  VIRTDEV_CACHE="${cache}" \
  VIRTDEV_LOCK_DIRECTORY="${locks}" \
  SYSTEMCTL_ACTIVE_STATE=inactive \
  NO_COLOR=1 \
  "${DESTRUCTIVE_TEST_REPOSITORY}/bin/virtdev-nuke" \
    >"${output}" 2>&1 || status=$?
if (( status != 6 )); then
  printf 'nuke accepted a bind mount (status %d)\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq "${bind_target}" "${output}"
[[ -f "${bind_source}/sentinel" && -f "${store}/projects/probe/disk" ]]
umount "${bind_target}"

system_directory="${store}/system"
mount_source="${test_home}/base-mount-source"
mount_target="${system_directory}/mounted"
mkdir -p "${system_directory}" "${mount_source}" "${mount_target}"
for image in system.qcow2 home.qcow2 nvram; do
  : > "${system_directory}/${image}"
done
printf '0\n' > "${system_directory}/generation"
printf 'ssh-host-identity=1\n' > "${system_directory}/guest-contract"
printf 'outside base\n' > "${mount_source}/sentinel"
mount --bind "${mount_source}" "${mount_target}"

status=0
HOME="${test_home}" \
VIRTDEV_HOME="${store}" \
VIRTDEV_CACHE="${cache}" \
VIRTDEV_LOCK_DIRECTORY="${locks}" \
NO_COLOR=1 \
  "${DESTRUCTIVE_TEST_REPOSITORY}/bin/virtdev-maintain" \
    --unfiltered --no-provision --no-inventory \
    >"${output}" 2>&1 || status=$?
if (( status != 34 )); then
  printf 'maintain accepted a mount in the sealed base (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq "${mount_target}" "${output}"
[[ -f "${mount_source}/sentinel" && ! -e "${store}/maintenance" ]]
umount "${mount_target}"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'target="${!#}"' \
  'project_directory="${target%/*}"' \
  'mkdir -p "${project_directory}/mounted"' \
  'mount --bind "${CREATE_MOUNT_SOURCE}" "${project_directory}/mounted"' \
  'exit 99' > "${fixture_bin}/qemu-img"
chmod +x "${fixture_bin}/qemu-img"

create_source="${test_home}/create-source"
create_project="${store}/projects/cleanup-probe"
create_mount="${create_project}/mounted"
mkdir -p "${create_source}"
printf 'outside project\n' > "${create_source}/sentinel"
status=0
HOME="${test_home}" \
VIRTDEV_HOME="${store}" \
VIRTDEV_LOCK_DIRECTORY="${locks}" \
CREATE_MOUNT_SOURCE="${create_source}" \
NO_COLOR=1 \
  "${DESTRUCTIVE_TEST_REPOSITORY}/bin/virtdev-create" cleanup-probe \
    >"${output}" 2>&1 || status=$?
if (( status != 99 )); then
  printf 'create mount-injection fixture returned status %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq "preserving partial project with mounted subtree: ${create_mount}" \
  "${output}"
[[ -d "${create_project}" && -f "${create_source}/sentinel" ]]
umount "${create_mount}"
mount_remove_tree "${create_project}" mount_path

preserved_source="${test_home}/preserved-base"
preserved_tree="${store}/maintenance"
preserved_mount="${preserved_tree}/mounted"
mkdir -p "${preserved_source}" "${preserved_mount}"
printf 'preserved base data\n' > "${preserved_source}/sentinel"
mount --bind "${preserved_source}" "${preserved_mount}"

status=0
HOME="${test_home}" \
VIRTDEV_HOME="${store}" \
VIRTDEV_CACHE="${cache}" \
VIRTDEV_LOCK_DIRECTORY="${locks}" \
NO_COLOR=1 \
  "${DESTRUCTIVE_TEST_REPOSITORY}/bin/virtdev-maintain" \
    --unfiltered --no-provision --no-inventory \
    >"${output}" 2>&1 || status=$?
if (( status != 5 )); then
  printf 'maintain did not preserve a mount-bearing previous base (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
grep -Fq "Mounted filesystem detected below staging: ${preserved_mount}" \
  "${output}"
grep -Fq "umount -- ${preserved_mount}" "${output}"
if grep -Fq 'rm -rf' "${output}"; then
  printf 'maintain advised recursive removal of a mount-bearing tree\n' >&2
  cat "${output}" >&2
  exit 1
fi
[[ -f "${preserved_source}/sentinel" ]]
umount "${preserved_mount}"

status=0
HOME="${test_home}" \
VIRTDEV_HOME="${store}" \
VIRTDEV_CACHE="${cache}" \
VIRTDEV_LOCK_DIRECTORY="${locks}" \
NO_COLOR=1 \
  "${DESTRUCTIVE_TEST_REPOSITORY}/bin/virtdev-maintain" \
    --unfiltered --no-provision --no-inventory \
    >"${output}" 2>&1 || status=$?
if (( status != 5 )) \
    || ! grep -Fq \
      "Rerun virtdev-maintain to retry descriptor-relative cleanup" \
      "${output}"; then
  printf 'mount-free maintenance recovery omitted safe retry guidance\n' >&2
  cat "${output}" >&2
  exit 1
fi
NAMESPACE

printf 'ok - destroy and nuke refuse nested filesystems and bind mounts\n'
printf 'ok - descriptor removal refuses a mount introduced after its precheck\n'
printf 'ok - staging cleanup preserves mount-bearing trees\n'
printf 'ok - backup stale-partial guidance requires an explicit unmount\n'
printf 'ok - maintenance refuses reseal trees containing mounts\n'
printf 'ok - maintenance recovery never removes through preserved mounts\n'
printf 'ok - mount-free maintenance removal is descriptor-relative\n'
