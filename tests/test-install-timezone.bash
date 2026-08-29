#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

# shellcheck disable=SC1091
source "${repository}/iso/airootfs/root/virtdev/timezone"

zoneinfo="${test_tmp}/zoneinfo"
outside="${test_tmp}/outside"
mkdir -p "${zoneinfo}/Region" "${outside}"
printf 'UTC\n' > "${zoneinfo}/UTC"
printf 'city\n' > "${zoneinfo}/Region/City"
printf 'outside\n' > "${outside}/secret"
ln -s Region/City "${zoneinfo}/Alias"
ln -s "${outside}/secret" "${zoneinfo}/Escape"

for valid in UTC Region/City Alias; do
  timezone_path_is_confined "${zoneinfo}" "${valid}" \
    || { printf 'valid timezone rejected: %s\n' "${valid}" >&2; exit 1; }
done

for invalid in '' /UTC ../outside Region/../UTC Region//City . .. Escape \
    $'Region/City\nUTC'; do
  if timezone_path_is_confined "${zoneinfo}" "${invalid}"; then
    printf 'unsafe timezone accepted: %q\n' "${invalid}" >&2
    exit 1
  fi
done

grep -Fq 'source /root/virtdev/timezone' \
  "${repository}/iso/airootfs/root/virtdev/install.sh"
# shellcheck disable=SC2016  # assert the literal installer expansion
grep -Fq 'timezone_path_is_confined "${zoneinfo_root}" "${timezone}"' \
  "${repository}/iso/airootfs/root/virtdev/install.sh"

printf 'ok - installer confines timezone names and resolved zoneinfo paths\n'
