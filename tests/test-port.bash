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

probe_bin="${test_tmp}/probe-bin"
mkdir -- "${probe_bin}"

expect_probe_status() {
  local -r expected="${1}" description="${2}"
  local probe_status=0
  PATH="${probe_bin}" port_in_use 2222 || probe_status=$?
  if (( probe_status != expected )); then
    printf '%s returned status %d, expected %d\n' \
      "${description}" "${probe_status}" "${expected}" >&2
    exit 1
  fi
}

expect_probe_status 3 'missing ss probe'

printf '%s\n' '#!/usr/bin/bash' 'exit 42' > "${probe_bin}/ss"
chmod 0755 -- "${probe_bin}/ss"
expect_probe_status 3 'failed ss probe'

printf '%s\n' '#!/usr/bin/bash' \
  "printf '%s\\n' 'LISTEN malformed output'" > "${probe_bin}/ss"
expect_probe_status 3 'malformed ss probe'

printf '%s\n' '#!/usr/bin/bash' 'exit 0' > "${probe_bin}/ss"
expect_probe_status 1 'empty ss probe'

printf '%s\n' '#!/usr/bin/bash' \
  "printf '%s\\n' 'LISTEN 0 128 127.0.0.1:2222 0.0.0.0:*'" \
  > "${probe_bin}/ss"
expect_probe_status 0 'bound ss probe'

probe_status=0
PATH="${probe_bin}" port_in_use 80 || probe_status=$?
(( probe_status == 2 )) || {
  printf 'invalid port probe returned status %d\n' "${probe_status}" >&2
  exit 1
}

printf 'ok - ports are canonical, range-checked, and bounded on read\n'
printf 'ok - port availability is proven or reported as indeterminate\n'
