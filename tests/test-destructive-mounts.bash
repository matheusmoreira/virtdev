#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"

cleanup() {
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
export PATH="${DESTRUCTIVE_TEST_REPOSITORY}/tests/fixtures:${PATH}"

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
NAMESPACE

printf 'ok - destroy and nuke refuse nested filesystems and bind mounts\n'
printf 'ok - maintenance refuses reseal trees containing mounts\n'
