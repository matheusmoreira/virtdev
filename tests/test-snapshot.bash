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

snapshot_path="${VIRTDEV_HOME}/backups/probe/2026-08-26/12-00-00"
if [[ "$(snapshot_id_from_path probe "${snapshot_path}")" != '2026-08-26/12-00-00' ]]; then
  printf 'backup output path was not converted to its stable snapshot ID\n' >&2
  exit 1
fi
if snapshot_id_from_path other "${snapshot_path}" >/dev/null; then
  printf 'cross-project backup path was accepted as a snapshot ID\n' >&2
  exit 1
fi

latest_output="$(
  HOME="${test_tmp}" NO_COLOR=1 \
    "${repository}/bin/virtdev-backup" --latest probe
)"
if [[ "${latest_output}" != '2026-08-26/12-00-00' ]]; then
  printf 'preserved snapshots were not discoverable without a project\n' >&2
  exit 1
fi
list_output="$(
  HOME="${test_tmp}" NO_COLOR=1 \
    "${repository}/bin/virtdev-backup" --list probe
)"
if [[ "${list_output}" != *'2026-08-26'* || "${list_output}" != *'12-00-00'* ]]; then
  printf 'preserved snapshot listing failed without a project\n' >&2
  exit 1
fi

printf 'ok - snapshot selection skips empty days and retains directories\n'
printf 'ok - list and latest discover backups after project removal\n'
