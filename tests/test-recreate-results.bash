#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${repo_root}/lib/virtdev/recreate-result"

expected=(
  '20 backup'
  '21 stop'
  '22 destroy'
  '23 create'
  '24 start'
  '25 wait'
  '26 unprovisioned'
  '27 restore'
  '28 zone removed'
)

actual=()
for status in {20..28}; do
  actual+=("${status} $(recreate_result_phase "${status}")")
done
[[ "${actual[*]}" == "${expected[*]}" ]]

if recreate_result_phase 19 >/dev/null || recreate_result_phase 29 >/dev/null; then
  printf 'unknown recreate result was accepted\n' >&2
  exit 1
fi

if grep -En 'exit_code == 26|^[[:space:]]*(22|23|24|25|27|28)\)' \
    "${repo_root}/bin/virtdev-upgrade" >/dev/null; then
  printf 'upgrade contains a literal recreate result\n' >&2
  exit 1
fi

printf 'ok - recreate and upgrade share one named result contract\n'
