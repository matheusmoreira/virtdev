#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

virtdev_home="${test_tmp}/virtdev"
config_home="${test_tmp}/config"
mkdir -p "${virtdev_home}/projects/target" "${config_home}"
printf 'unrelated\n' > "${virtdev_home}/projects/target/sentinel"

output="${test_tmp}/without-journal.output"
status=0
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-move" source target >"${output}" 2>&1 \
  || status=$?

if (( status != 3 )); then
  printf 'expected source-not-found exit 3 without journal, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ "$(< "${virtdev_home}/projects/target/sentinel")" != unrelated ]]; then
  printf 'unrelated target was mutated without transaction authority\n' >&2
  exit 1
fi

printf 'version=1\nsource=source\ntarget=target\n' > "${virtdev_home}/move.transaction"
output="${test_tmp}/with-journal.output"
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-move" source target >"${output}" 2>&1

if [[ -e "${virtdev_home}/move.transaction" ]]; then
  printf 'completed recovery left its transaction journal behind\n' >&2
  cat "${output}" >&2
  exit 1
fi
if ! grep -Fq 'Recovering from interrupted move' "${output}"; then
  printf 'matching journal did not enter recovery\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - move recovery requires an exact transaction journal\n'
