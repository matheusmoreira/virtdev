#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # nameref output and imported directory

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

stall_library="${test_tmp}/remove-tree-stall.so"
cc -std=c99 -shared -fPIC -Wall -Wextra -Wpedantic -Werror \
  -o "${stall_library}" "${repository}/tests/support/remove-tree-stall.c"

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import mount

tree="${test_tmp}/tree"
marker="${test_tmp}/marker"
mkdir "${tree}"
printf 'preserve me\n' > "${tree}/stall"
mount_path=''
status=0
started="${BASH_MONOSECONDS}"
LD_PRELOAD="${stall_library}" \
REMOVE_TREE_STALL_MARKER="${marker}" \
REMOVE_TREE_STALL_NAME=stall \
  mount_remove_tree_bounded "${tree}" mount_path 1 1 || status=$?
elapsed=$(( BASH_MONOSECONDS - started ))
if (( status != 4 || elapsed > 3 )) || [[ ! -e "${marker}" \
      || ! -d "${tree}" ]]; then
  printf 'recursive cleanup escaped its grace window (status %d, %ds)\n' \
    "${status}" "${elapsed}" >&2
  exit 1
fi

printf 'ok - recursive cleanup preserves remaining state after its grace expires\n'
