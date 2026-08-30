#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
helper="${repository}/libexec/virtdev/virtdev-publish"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

[[ -x "${helper}" ]] || {
  printf 'virtdev-publish is not built\n' >&2
  exit 1
}

printf 'new\n' > "${test_tmp}/stage"
"${helper}" noreplace "${test_tmp}/stage" "${test_tmp}/target"
if [[ -e "${test_tmp}/stage" || "$(< "${test_tmp}/target")" != new ]]; then
  printf 'noreplace did not atomically publish an absent target\n' >&2
  exit 1
fi

printf 'candidate\n' > "${test_tmp}/stage"
status=0
"${helper}" noreplace "${test_tmp}/stage" "${test_tmp}/target" \
  || status=$?
if (( status != 3 )) || [[ "$(< "${test_tmp}/stage")" != candidate ]] \
    || [[ "$(< "${test_tmp}/target")" != new ]]; then
  printf 'noreplace did not preserve both sides on conflict\n' >&2
  exit 1
fi

"${helper}" exchange "${test_tmp}/stage" "${test_tmp}/target"
if [[ "$(< "${test_tmp}/stage")" != new \
      || "$(< "${test_tmp}/target")" != candidate ]]; then
  printf 'exchange did not atomically retain the previous target\n' >&2
  exit 1
fi

sync_fault="${test_tmp}/publish-sync-fail.so"
cc -shared -fPIC -Wall -Wextra -Werror \
  -o "${sync_fault}" "${repository}/tests/support/publish-sync-fail.c"
printf 'newer\n' > "${test_tmp}/stage"
status=0
LD_PRELOAD="${sync_fault}" \
  "${helper}" exchange "${test_tmp}/stage" "${test_tmp}/target" \
  >/dev/null 2>&1 || status=$?
if (( status != 2 )) || [[ "$(< "${test_tmp}/stage")" != candidate ]] \
    || [[ "$(< "${test_tmp}/target")" != newer ]]; then
  printf 'post-publication sync failure did not preserve committed state\n' >&2
  exit 1
fi

printf 'ok - publication distinguishes conflicts from committed sync failures\n'
