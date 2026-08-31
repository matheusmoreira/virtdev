#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

guest_root="${test_tmp}/home-dev"
outside="${test_tmp}/outside"
mkdir -p "${guest_root}/real/sub" "${guest_root}/punctuation[&|]/sub" \
  "${outside}"
printf 'payload\n' > "${guest_root}/real/sub/file"
printf 'punctuation\n' > "${guest_root}/punctuation[&|]/sub/file"
printf 'outside\n' > "${outside}/secret"
ln -s "${outside}/secret" "${guest_root}/final-link"

archive="${test_tmp}/capture.tar"
printf '%s\n' real 'punctuation[&|]/sub/file' final-link missing \
  | _VIRTDEV_BACKUP_GUEST_ROOT="${guest_root}" \
      bash "${repository}/lib/virtdev/backup-guest" > "${archive}"

listing="$(tar -tf "${archive}")"
if [[ "${listing}" != *'real/sub/file'* \
      || "${listing}" != *'punctuation[&|]/sub/file'* \
      || "${listing}" != *'final-link'* \
      || "${listing}" == *missing* ]]; then
  printf 'guest backup helper did not preserve canonical manifest roots\n' >&2
  exit 1
fi
if [[ "$(tar -tvf "${archive}" final-link)" != l* ]]; then
  printf 'guest backup helper dereferenced a final symlink root\n' >&2
  exit 1
fi

for link_target in "${outside}" "${guest_root}/real"; do
  rm -f -- "${guest_root}/intermediate"
  ln -s "${link_target}" "${guest_root}/intermediate"
  status=0
  printf '%s\n' intermediate/secret \
    | _VIRTDEV_BACKUP_GUEST_ROOT="${guest_root}" \
        bash "${repository}/lib/virtdev/backup-guest" \
        > "${test_tmp}/rejected.tar" || status=$?
  if (( status != 40 )); then
    printf 'intermediate guest symlink was not rejected (status %d)\n' \
      "${status}" >&2
    exit 1
  fi
done

printf 'ok - guest backup rejects intermediate symlinks and preserves final symlinks\n'
