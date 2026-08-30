#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import enumerate project

fixture_bin="${test_tmp}/bin"
mkdir -p "${fixture_bin}" "${test_tmp}/home/projects/probe"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "probe\\0"' \
  'exit 7' > "${fixture_bin}/find"
chmod +x "${fixture_bin}/find"

declare -a projects=(stale)
status=0
PATH="${fixture_bin}:/usr/bin" \
VIRTDEV_HOME="${test_tmp}/home" \
  project_list_into projects || status=$?
if (( status != 2 || ${#projects[@]} != 0 )); then
  printf 'partial project enumeration was accepted (status %d)\n' \
    "${status}" >&2
  exit 1
fi

overflow_records() {
  printf '12345'
}

declare -a records=()
status=0
enumerate_nul_sorted records 4 overflow_records || status=$?
if (( status != 3 || ${#records[@]} != 0 )); then
  printf 'oversized enumeration was accepted (status %d)\n' "${status}" >&2
  exit 1
fi

printf 'ok - strict enumeration rejects partial and oversized producers\n'
