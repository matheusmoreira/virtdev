#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

left="${test_tmp}/system"
right="${test_tmp}/maintenance"
mkdir "${left}" "${right}"
printf 'old\n' > "${left}/identity"
printf 'new\n' > "${right}/identity"

"${repository}/bin/virtdev-exchange" "${left}" "${right}"

if [[ "$(< "${left}/identity")" != new ]]; then
  printf 'system did not receive staged content\n' >&2
  exit 1
fi
if [[ "$(< "${right}/identity")" != old ]]; then
  printf 'maintenance did not retain previous content\n' >&2
  exit 1
fi

printf 'ok - exchange commits the staged and previous directory names\n'
