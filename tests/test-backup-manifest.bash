#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import manifest

source_tree="${test_tmp}/source"
destination="${test_tmp}/destination"
mkdir -p "${source_tree}/real/sub" "${destination}"
printf 'payload\n' > "${source_tree}/real/sub/file"
ln -s real "${source_tree}/link"
printf 'real/\nlink/\n' > "${test_tmp}/manifest"

manifest_write_rsync_files_from \
  "${test_tmp}/manifest" "${test_tmp}/files-from"

if [[ "$(sed -n '1p' "${test_tmp}/files-from")" != real ||
      "$(sed -n '2p' "${test_tmp}/files-from")" != link ]]; then
  printf 'files-from roots retained unsafe trailing slashes\n' >&2
  exit 1
fi

rsync -a -r --safe-links --files-from="${test_tmp}/files-from" \
  "${source_tree}/" "${destination}/"

if [[ ! -f "${destination}/real/sub/file" ]]; then
  printf 'real directory root no longer recurses after normalization\n' >&2
  exit 1
fi
if [[ ! -L "${destination}/link" ]]; then
  printf 'symlink manifest root was dereferenced as a directory\n' >&2
  exit 1
fi

status=0
NO_COLOR=1 VIRTDEV_HOME="${test_tmp}/home" \
  "${repository}/bin/virtdev-backup" --copy-links probe \
  >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 64 )); then
  printf 'backup still accepts unsafe symlink dereferencing\n' >&2
  exit 1
fi

if grep -Eq -- '--link-dest|--copy-links' "${repository}/bin/virtdev-backup"; then
  printf 'backup still aliases snapshots or dereferences guest symlinks\n' >&2
  exit 1
fi

printf 'ok - backup roots stay local and snapshots own independent inodes\n'
