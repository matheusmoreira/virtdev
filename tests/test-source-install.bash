#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

install_root="${test_tmp}/root"
install_output="${test_tmp}/install-output"
if ! make --no-print-directory -C "${repository}" \
    DESTDIR="${install_root}" PREFIX=/opt/virtdev install \
    >"${install_output}" 2>&1; then
  cat "${install_output}" >&2
  exit 1
fi

assert_copy() {
  local -r source="${1}" destination="${2}" expected_mode="${3}"
  if [[ ! -f "${destination}" || -L "${destination}" ]] \
      || ! cmp -s -- "${source}" "${destination}" \
      || [[ "$(stat -c '%a' -- "${destination}")" != "${expected_mode}" ]]; then
    printf 'installed file mismatch: %s\n' "${destination}" >&2
    exit 1
  fi
}

for source in "${repository}"/bin/virtdev "${repository}"/bin/virtdev-*; do
  assert_copy "${source}" \
    "${install_root}/opt/virtdev/bin/${source##*/}" 755
done

for source in "${repository}"/libexec/virtdev/*; do
  [[ -f "${source}" && ! -L "${source}" ]] || continue
  assert_copy "${source}" \
    "${install_root}/opt/virtdev/libexec/virtdev/${source##*/}" 755
done

for source in "${repository}"/lib/virtdev/*; do
  assert_copy "${source}" \
    "${install_root}/opt/virtdev/lib/virtdev/${source##*/}" 644
done

holder="${install_root}/usr/lib/systemd/system/virtdev-firewall.service"
pin="${install_root}/usr/lib/systemd/user/virtdev-firewall-pin@.service"
[[ -f "${holder}" && "$(stat -c '%a' -- "${holder}")" == 644 ]]
grep -Fqx 'ExecStart=/opt/virtdev/bin/virtdev-firewall hold' "${holder}"
assert_copy "${repository}/systemd/virtdev-firewall-pin@.service" "${pin}" 644

profile="${install_root}/opt/virtdev/share/virtdev/profile"
while IFS= read -r -d '' source; do
  relative="${source#"${repository}/iso/"}"
  assert_copy "${source}" "${profile}/${relative}" \
    "$(stat -c '%a' -- "${source}")"
done < <(find "${repository}/iso" -type f -print0)

source_link="${repository}/iso/airootfs/etc/systemd/system/multi-user.target.wants/virtdev-install.service"
installed_link="${profile}/airootfs/etc/systemd/system/multi-user.target.wants/virtdev-install.service"
if [[ ! -L "${installed_link}" \
    || "$(readlink -- "${installed_link}")" != "$(readlink -- "${source_link}")" ]]; then
  printf 'installed ISO profile lost its service symlink\n' >&2
  exit 1
fi

assert_copy "${repository}/README.md" \
  "${install_root}/opt/virtdev/share/doc/virtdev/README.md" 644
assert_copy "${repository}/DESIGN.md" \
  "${install_root}/opt/virtdev/share/doc/virtdev/DESIGN.md" 644
assert_copy "${repository}/LICENSE.AGPLv3" \
  "${install_root}/opt/virtdev/share/licenses/virtdev/LICENSE" 644
assert_copy "${repository}/man/virtdev-firewall.8" \
  "${install_root}/opt/virtdev/share/man/man8/virtdev-firewall.8" 644

installed_bin="${install_root}/opt/virtdev/bin"
PATH="${installed_bin}:/usr/bin" HOME="${test_tmp}" \
  "${installed_bin}/virtdev" --help > "${test_tmp}/help"
grep -Fqx '  create' "${test_tmp}/help"

probe_bin="${test_tmp}/probe-bin"
mkdir -- "${probe_bin}"
for command in cat dirname readlink realpath; do
  ln -s -- "/usr/bin/${command}" "${probe_bin}/${command}"
done
status=0
PATH="${probe_bin}" HOME="${test_tmp}" NO_COLOR=1 \
VIRTDEV_HOME="${test_tmp}/virtdev" VIRTDEV_CACHE="${test_tmp}/cache" \
  /usr/bin/bash "${installed_bin}/virtdev-iso" \
    >"${test_tmp}/iso-output" 2>&1 || status=$?
if (( status != 4 )) || ! grep -Fq 'mkarchiso not found' "${test_tmp}/iso-output"; then
  printf 'installed ISO command did not resolve its prefixed profile (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/iso-output" >&2
  exit 1
fi

printf 'ok - source install publishes the complete relocatable command layout\n'
printf 'ok - installed ISO profile preserves modes, links, and prefix discovery\n'
