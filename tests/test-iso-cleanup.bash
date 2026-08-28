#!/usr/bin/env bash
# shellcheck disable=SC2016  # generated fixtures

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"

cleanup() {
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

fixture_bin="${test_tmp}/bin"
mkdir -p "${fixture_bin}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%q " "$@" >> "${ISO_TEST_SUDO_LOG:?}"' \
  'printf "\n" >> "${ISO_TEST_SUDO_LOG:?}"' \
  'if [[ "${ISO_TEST_RACE_ON_MV:-0}" == 1' \
  '    && "${1:-}" == /usr/bin/mv' \
  '    && ! -e "${ISO_TEST_RACE_READY:?}" ]]; then' \
  '  : > "${ISO_TEST_RACE_READY}"' \
  '  while [[ ! -e "${ISO_TEST_RACE_DONE:?}" ]]; do sleep 0.01; done' \
  'fi' \
  'exec "$@"' \
  > "${fixture_bin}/sudo"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'output=""' \
  'while (( $# )); do' \
  '  if [[ "${1}" == -o ]]; then' \
  '    shift' \
  '    output="${1}"' \
  '  fi' \
  '  shift' \
  'done' \
  '[[ -n "${output}" ]]' \
  ': > "${output}/fixture-x86_64.iso"' \
  > "${fixture_bin}/mkarchiso"
chmod +x "${fixture_bin}/sudo" "${fixture_bin}/mkarchiso"

if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'ISO cleanup test requires an unprivileged user/mount namespace\n' >&2
  exit 1
fi

export ISO_TEST_REPOSITORY="${repository}"
export ISO_TEST_TMP="${test_tmp}"
export ISO_TEST_SUDO_LOG="${test_tmp}/sudo.log"
export PATH="${fixture_bin}:${PATH}"

unshare --user --map-root-user --mount bash -s <<'NAMESPACE'
set -euo pipefail

test_filesystem="${ISO_TEST_TMP}/filesystem"
mkdir -p "${test_filesystem}"
mount -t tmpfs tmpfs "${test_filesystem}"

cache="${test_filesystem}/cache with space"
mount_source="${test_filesystem}/sentinel-source"
mount_target="${cache}/work/stale-mount"
mkdir -p "${mount_source}" "${mount_target}"
printf 'sentinel\n' > "${mount_source}/sentinel"
mount --bind "${mount_source}" "${mount_target}"

status=0
USER=untrusted-name \
VIRTDEV_CACHE="${cache}" \
VIRTDEV_HOME="${ISO_TEST_TMP}/home" \
VIRTDEV_ISO_PROFILE="${ISO_TEST_REPOSITORY}/iso" \
VIRTDEV_LOCK_DIRECTORY="${ISO_TEST_TMP}/locks" \
  bash "${ISO_TEST_REPOSITORY}/bin/virtdev-iso" \
    >"${ISO_TEST_TMP}/mounted.stdout" 2>"${ISO_TEST_TMP}/mounted.stderr" \
    || status=$?
if (( status != 12 )); then
  printf 'ISO cleanup accepted a mounted build subtree (status %d)\n' \
    "${status}" >&2
  cat "${ISO_TEST_TMP}/mounted.stderr" >&2
  exit 1
fi
grep -Fq 'Mounted filesystem detected below ISO build path' \
  "${ISO_TEST_TMP}/mounted.stderr"
grep -Fq "${mount_target}" "${ISO_TEST_TMP}/mounted.stderr"
[[ ! -e "${ISO_TEST_SUDO_LOG}" ]]
[[ "$(< "${mount_source}/sentinel")" == sentinel ]]
umount "${mount_target}"

# Swap an intermediate directory after validation. Quarantine deletion must
# unlink the replacement symlink without following it.
outside="${test_filesystem}/outside"
swap_target="${cache}/work/swap"
swap_ready="${ISO_TEST_TMP}/swap-ready"
swap_done="${ISO_TEST_TMP}/swap-done"
mkdir -p "${outside}" "${swap_target}"
printf 'outside sentinel\n' > "${outside}/sentinel"
printf 'stale\n' > "${swap_target}/stale"
(
  while [[ ! -e "${swap_ready}" ]]; do sleep 0.01; done
  mv "${swap_target}" "${swap_target}.old"
  ln -s "${outside}" "${swap_target}"
  : > "${swap_done}"
) &
swapper=$!

ISO_TEST_RACE_ON_MV=1 \
ISO_TEST_RACE_READY="${swap_ready}" \
ISO_TEST_RACE_DONE="${swap_done}" \
USER=untrusted-name \
VIRTDEV_CACHE="${cache}" \
VIRTDEV_HOME="${ISO_TEST_TMP}/home" \
VIRTDEV_ISO_PROFILE="${ISO_TEST_REPOSITORY}/iso" \
VIRTDEV_LOCK_DIRECTORY="${ISO_TEST_TMP}/locks" \
  bash "${ISO_TEST_REPOSITORY}/bin/virtdev-iso" \
    >"${ISO_TEST_TMP}/swap.stdout" 2>"${ISO_TEST_TMP}/swap.stderr"
wait "${swapper}"
[[ "$(< "${outside}/sentinel")" == 'outside sentinel' ]]

# Insert a same-filesystem bind mount after the first check. The second check
# must return the tree intact without traversing the mount.
race_source="${test_filesystem}/race-source"
race_target="${cache}/work/race-mount"
race_ready="${ISO_TEST_TMP}/race-ready"
race_done="${ISO_TEST_TMP}/race-done"
mkdir -p "${race_source}" "${race_target}"
printf 'race sentinel\n' > "${race_source}/sentinel"
(
  while [[ ! -e "${race_ready}" ]]; do sleep 0.01; done
  mount --bind "${race_source}" "${race_target}"
  : > "${race_done}"
) &
racer=$!

status=0
ISO_TEST_RACE_ON_MV=1 \
ISO_TEST_RACE_READY="${race_ready}" \
ISO_TEST_RACE_DONE="${race_done}" \
USER=untrusted-name \
VIRTDEV_CACHE="${cache}" \
VIRTDEV_HOME="${ISO_TEST_TMP}/home" \
VIRTDEV_ISO_PROFILE="${ISO_TEST_REPOSITORY}/iso" \
VIRTDEV_LOCK_DIRECTORY="${ISO_TEST_TMP}/locks" \
  bash "${ISO_TEST_REPOSITORY}/bin/virtdev-iso" \
    >"${ISO_TEST_TMP}/race.stdout" 2>"${ISO_TEST_TMP}/race.stderr" \
    || status=$?
wait "${racer}"
if (( status != 12 )); then
  printf 'ISO cleanup missed a raced bind mount (status %d)\n' \
    "${status}" >&2
  cat "${ISO_TEST_TMP}/race.stderr" >&2
  exit 1
fi
grep -Fq "${race_target}" "${ISO_TEST_TMP}/race.stderr"
[[ "$(< "${race_source}/sentinel")" == 'race sentinel' ]]
mountpoint -q "${race_target}"
umount "${race_target}"
: > "${ISO_TEST_SUDO_LOG}"

USER=untrusted-name \
VIRTDEV_CACHE="${cache}" \
VIRTDEV_HOME="${ISO_TEST_TMP}/home" \
VIRTDEV_ISO_PROFILE="${ISO_TEST_REPOSITORY}/iso" \
VIRTDEV_LOCK_DIRECTORY="${ISO_TEST_TMP}/locks" \
  bash "${ISO_TEST_REPOSITORY}/bin/virtdev-iso" \
    >"${ISO_TEST_TMP}/clean.stdout" 2>"${ISO_TEST_TMP}/clean.stderr"

[[ -f "${cache}/virtdev.iso" ]]
grep -Fq '/usr/bin/mktemp -d --tmpdir=/tmp' "${ISO_TEST_SUDO_LOG}"
grep -Fq '/usr/bin/mv --no-target-directory -- work' "${ISO_TEST_SUDO_LOG}"
grep -Fq '/usr/bin/rm -rf --one-file-system' "${ISO_TEST_SUDO_LOG}"
if grep -Eq '/usr/bin/(find|chown)' "${ISO_TEST_SUDO_LOG}"; then
  printf 'ISO cleanup retained a privileged path traversal\n' >&2
  exit 1
fi
if grep -Fq 'untrusted-name' "${ISO_TEST_SUDO_LOG}"; then
  printf 'ISO cleanup trusted the textual USER identity\n' >&2
  exit 1
fi
umount "${test_filesystem}"
NAMESPACE

printf 'ok - ISO cleanup quarantines trees and refuses stable or raced mounts\n'
