#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

export VIRTDEV_HOME="${test_tmp}/virtdev"
# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import snapshot

mkdir -p \
  "${VIRTDEV_HOME}/backups/probe/2026-08-26/12-00-00/tree/empty-directory" \
  "${VIRTDEV_HOME}/backups/probe/2026-08-27"

if [[ "$(snapshot_latest probe)" != '2026-08-26/12-00-00' ]]; then
  printf 'newer empty day hid the latest complete snapshot\n' >&2
  exit 1
fi

tree="${VIRTDEV_HOME}/backups/probe/2026-08-26/12-00-00/tree"
if ! snapshot_tree_has_entries "${tree}"; then
  printf 'directory-only snapshot was classified empty\n' >&2
  exit 1
fi
if [[ "$(snapshot_tree_count_entries "${tree}")" != 1 ]]; then
  printf 'directory-only snapshot entry count is incorrect\n' >&2
  exit 1
fi

printf 'ok - snapshot selection skips empty days and retains directories\n'
