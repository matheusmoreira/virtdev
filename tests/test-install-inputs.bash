#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

output="${test_tmp}/output"
status=0
VIRTDEV_PACKAGES="${test_tmp}/missing-packages" \
  "${repository}/bin/virtdev-install" >"${output}" 2>&1 || status=$?

if (( status != 11 )); then
  printf 'expected missing-packages exit 11, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if ! grep -Fq 'Packages file not found or not readable' "${output}"; then
  printf 'missing explicit-input diagnostic\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - installer rejects a missing explicit customization file\n'
