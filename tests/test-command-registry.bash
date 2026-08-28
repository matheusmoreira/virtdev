#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

extension="${test_tmp}/virtdev-probe-extension"
apply_patch_marker="${test_tmp}/called"
sed "s|@MARKER@|${apply_patch_marker}|" > "${extension}" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" > '@MARKER@'
SCRIPT
chmod 755 "${extension}"

PATH="${test_tmp}:${PATH}" "${repository}/bin/virtdev" --help > "${test_tmp}/help"
for command in start stop backup; do
  [[ "$(grep -Ec "^  ${command}$" "${test_tmp}/help")" == 1 ]]
done
for helper in netexec exchange stop-acpi; do
  if grep -Eq "^  ${helper}$" "${test_tmp}/help"; then
    printf 'private helper was advertised: %s\n' "${helper}" >&2
    exit 1
  fi
done
grep -Fqx 'External commands on PATH:' "${test_tmp}/help"
grep -Fqx '  probe-extension' "${test_tmp}/help"

PATH="${test_tmp}:${PATH}" "${repository}/bin/virtdev" \
  probe-extension one two
[[ "$(< "${apply_patch_marker}")" == 'one two' ]]

for helper in netexec exchange stop-acpi; do
  status=0
  PATH="${test_tmp}:${PATH}" "${repository}/bin/virtdev" "${helper}" \
    >"${test_tmp}/output" 2>&1 || status=$?
  (( status == 64 ))
done

status=0
"${repository}/bin/virtdev-stop" --acpi-only probe \
  >"${test_tmp}/output" 2>&1 || status=$?
(( status == 64 ))

printf 'ok - public commands and private helpers have explicit boundaries\n'
