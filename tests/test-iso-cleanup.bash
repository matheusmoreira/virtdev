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

cache="${ISO_TEST_TMP}/cache with space"
mount_source="${ISO_TEST_TMP}/sentinel-source"
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

USER=untrusted-name \
VIRTDEV_CACHE="${cache}" \
VIRTDEV_HOME="${ISO_TEST_TMP}/home" \
VIRTDEV_ISO_PROFILE="${ISO_TEST_REPOSITORY}/iso" \
VIRTDEV_LOCK_DIRECTORY="${ISO_TEST_TMP}/locks" \
  bash "${ISO_TEST_REPOSITORY}/bin/virtdev-iso" \
    >"${ISO_TEST_TMP}/clean.stdout" 2>"${ISO_TEST_TMP}/clean.stderr"

[[ -f "${cache}/virtdev.iso" ]]
grep -Fq '/usr/bin/find' "${ISO_TEST_SUDO_LOG}"
grep -Fq -- '-xdev' "${ISO_TEST_SUDO_LOG}"
grep -Fq '/usr/bin/chown -h -- 0:0' "${ISO_TEST_SUDO_LOG}"
if grep -Fq 'untrusted-name' "${ISO_TEST_SUDO_LOG}"; then
  printf 'ISO cleanup trusted the textual USER identity\n' >&2
  exit 1
fi
NAMESPACE

printf 'ok - ISO cleanup refuses mounts and bounds privileged traversal\n'
