#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

virtdev_home="${test_tmp}/virtdev"
project_directory="${virtdev_home}/projects/probe"
mkdir -p "${project_directory}"
export VIRTDEV_HOME="${virtdev_home}"

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import port

for valid in 1024 2222 65535; do
  if ! port_is_valid "${valid}"; then
    printf 'canonical port was rejected: %s\n' "${valid}" >&2
    exit 1
  fi
done
for invalid in 0 80 01024 02222 65536 999999999999999999999999 bad; do
  if port_is_valid "${invalid}"; then
    printf 'noncanonical/out-of-range port was accepted: %s\n' "${invalid}" >&2
    exit 1
  fi
done

printf '02222\n' > "${project_directory}/port"
if [[ "$(port_read_lenient probe)" != '?' ]]; then
  printf 'persisted leading-zero port was accepted\n' >&2
  exit 1
fi

printf '2222\n' > "${project_directory}/port"
if [[ "$(port_read_lenient probe)" != 2222 ]]; then
  printf 'canonical persisted port was rejected\n' >&2
  exit 1
fi

truncate -s 1048576 "${project_directory}/port"
if [[ "$(port_read_lenient probe)" != '?' ]]; then
  printf 'oversized port scalar was accepted\n' >&2
  exit 1
fi
status=0
( port_require result probe ) >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 81 )); then
  printf 'expected oversized port exit 81, got %d\n' "${status}" >&2
  exit 1
fi

printf 'ok - ports are canonical, range-checked, and bounded on read\n'
