#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # nameref output and imported constants

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

stall_bin="${test_tmp}/bin"
mkdir "${stall_bin}"
for command_name in mv sync; do
  ln -s "${repository}/tests/fixtures/stall-command" \
    "${stall_bin}/${command_name}"
done
export PATH="${stall_bin}:${PATH}"

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import frozen-input manifest

manifest_source="${test_tmp}/source.manifest"
printf 'data\n' > "${manifest_source}"
for stall_call in 1 2; do
  manifest_destination="${test_tmp}/manifest-${stall_call}"
  files_destination="${test_tmp}/files-${stall_call}"
  marker="${test_tmp}/manifest-${stall_call}.marker"
  count_file="${test_tmp}/manifest-${stall_call}.count"
  status=0
  started="${BASH_MONOSECONDS}"
  STALL_COMMAND=mv STALL_CALL="${stall_call}" STALL_COUNT_FILE="${count_file}" \
  STALL_MARKER="${marker}" STALL_DELAY=5 \
    manifest_freeze_validate "${manifest_source}" "${manifest_destination}" \
      "${files_destination}" "$(( BASH_MONOSECONDS + 1 ))" 1 \
      || status=$?
  elapsed=$(( BASH_MONOSECONDS - started ))
  if (( status != manifest_result_timeout || elapsed > 3 )) \
      || [[ ! -e "${marker}" || -e "${manifest_destination}" \
        || -e "${files_destination}" ]]; then
    printf 'manifest move %d escaped its deadline or exposed a partial pair (status %d, %ds)\n' \
      "${stall_call}" "${status}" "${elapsed}" >&2
    exit 1
  fi
done

frozen_source="${test_tmp}/provision"
frozen_destination="${test_tmp}/provision.frozen"
printf '#!/bin/sh\ntrue\n' > "${frozen_source}"
digest=''
status=0
STALL_COMMAND=mv STALL_MARKER="${test_tmp}/frozen-mv.marker" STALL_DELAY=5 \
  frozen_input_copy digest "${frozen_source}" "${frozen_destination}" \
    "$(( BASH_MONOSECONDS + 1 ))" 1 || status=$?
if (( status != frozen_input_result_timeout )) \
    || [[ ! -e "${test_tmp}/frozen-mv.marker" \
      || -e "${frozen_destination}" || -e "${frozen_destination}.tmp" ]]; then
  printf 'frozen-input rename timeout did not remain unpublished (status %d)\n' \
    "${status}" >&2
  exit 1
fi

status=0
STALL_COMMAND=sync STALL_MARKER="${test_tmp}/frozen-sync.marker" STALL_DELAY=5 \
  frozen_input_copy digest "${frozen_source}" "${frozen_destination}" \
    "$(( BASH_MONOSECONDS + 1 ))" 1 || status=$?
if (( status != frozen_input_result_durability )) \
    || [[ ! -e "${test_tmp}/frozen-sync.marker" \
      || ! -f "${frozen_destination}" ]] \
    || ! cmp -s -- "${frozen_source}" "${frozen_destination}"; then
  printf 'frozen-input sync timeout lost its committed-state result (status %d)\n' \
    "${status}" >&2
  exit 1
fi

printf 'ok - manifest and frozen-input publication preserve exact deadline states\n'
