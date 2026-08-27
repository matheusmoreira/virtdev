#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

test_home="${test_tmp}/home"
mkdir -p "${test_home}/linked-target" "${test_home}/cache"
printf 'preserve target\n' > "${test_home}/linked-target/sentinel"
ln -s linked-target "${test_home}/data-link"

output="${test_tmp}/output"
status=0
printf 'nuke\n' | HOME="${test_home}" \
  VIRTDEV_HOME="${test_home}/data-link" \
  VIRTDEV_CACHE="${test_home}/cache" \
  NO_COLOR=1 \
  "${repository}/bin/virtdev-nuke" >"${output}" 2>&1 || status=$?

if (( status != 3 )); then
  printf 'expected symlink-root refusal exit 3, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ ! -L "${test_home}/data-link" \
      || ! -f "${test_home}/linked-target/sentinel" ]]; then
  printf 'symlink-root refusal mutated the link or its target\n' >&2
  exit 1
fi

mkdir -p "${test_home}/storage/virtdev/projects" \
  "${test_home}/canonical-cache"
printf 'delete data\n' > "${test_home}/storage/virtdev/sentinel"
printf 'delete cache\n' > "${test_home}/canonical-cache/sentinel"
ln -s storage "${test_home}/storage-alias"

status=0
printf 'nuke\n' | HOME="${test_home}" \
  VIRTDEV_HOME="${test_home}/storage-alias/virtdev" \
  VIRTDEV_CACHE="${test_home}/canonical-cache" \
  NO_COLOR=1 \
  "${repository}/bin/virtdev-nuke" >"${output}" 2>&1 || status=$?

if (( status != 0 )); then
  printf 'expected canonical-root nuke success, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ -e "${test_home}/storage/virtdev" \
      || -e "${test_home}/canonical-cache" ]]; then
  printf 'nuke did not remove the exact approved physical roots\n' >&2
  exit 1
fi
if [[ ! -L "${test_home}/storage-alias" \
      || ! -f "${test_home}/linked-target/sentinel" ]]; then
  printf 'nuke removed a path outside its approved physical roots\n' >&2
  exit 1
fi

printf 'ok - nuke rejects link roots and deletes exact canonical roots\n'
