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

grep -Fq '| 105 | SSH config contains a forbidden client-identity directive |' \
  "${repository}/CLAUDE.md"
grep -Fq "| \`ssh\` | Guest-contract checks, project host identities, strict shared transport argv, rsync wrapper, and bounded polling | 77, 78, 103, 104, 105 |" \
  "${repository}/DESIGN.md"

for script in virtdev-backup virtdev-restore virtdev-wait virtdev-transfer \
              virtdev-ssh; do
  header="$(sed -n '1,/^set -euo pipefail$/p' "${repository}/bin/${script}")"
  for code in 103 104; do
    if ! grep -Eq "^# +${code} " <<< "${header}"; then
      printf '%s does not document propagated exit %s\n' "${script}" "${code}" >&2
      exit 1
    fi
  done
done

printf 'ok - public commands and private helpers have explicit boundaries\n'
printf 'ok - shared SSH exit contracts are registered and documented\n'
