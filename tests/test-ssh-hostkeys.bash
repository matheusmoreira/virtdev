#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
helper="${repository}/iso/airootfs/root/virtdev/virtdev-ssh-hostkeys"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

project_file="${test_tmp}/project"
ssh_directory="${test_tmp}/ssh"
runtime_directory="${test_tmp}/run"
all_marker="${test_tmp}/keygen-all"
mkdir -p "${ssh_directory}"
printf %s maintenance > "${project_file}"
printf 'config sentinel\n' > "${ssh_directory}/sshd_config"
for algorithm in dsa ecdsa ed25519 rsa; do
  printf 'private\n' > "${ssh_directory}/ssh_host_${algorithm}_key"
  printf 'public\n' > "${ssh_directory}/ssh_host_${algorithm}_key.pub"
done
printf 'future private\n' > \
  "${ssh_directory}/ssh_host_mldsa44_ed25519_key"
printf 'future public\n' > \
  "${ssh_directory}/ssh_host_mldsa44_ed25519_key.pub"

VIRTDEV_FW_CFG_PROJECT="${project_file}" \
VIRTDEV_SSH_DIRECTORY="${ssh_directory}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${runtime_directory}" \
  "${helper}" prepare

for algorithm in dsa ecdsa ed25519 rsa; do
  if [[ -e "${ssh_directory}/ssh_host_${algorithm}_key" \
        || -e "${ssh_directory}/ssh_host_${algorithm}_key.pub" ]]; then
    printf 'maintenance preserved a persistent %s host key\n' \
      "${algorithm}" >&2
    exit 1
  fi
done
if compgen -G "${ssh_directory}/ssh_host_*_key" >/dev/null \
    || compgen -G "${ssh_directory}/ssh_host_*_key.pub" >/dev/null; then
  printf 'maintenance preserved an unrecognized persistent host key\n' >&2
  exit 1
fi
if [[ ! -s "${runtime_directory}/ssh_host_ed25519_key" \
      || ! -s "${runtime_directory}/ssh_host_ed25519_key.pub" \
      || ! -f "${runtime_directory}/maintenance" ]]; then
  printf 'maintenance did not prepare its ephemeral host identity\n' >&2
  exit 1
fi
if [[ "$(stat -c '%a' "${runtime_directory}/ssh_host_ed25519_key")" != 600 ]]; then
  printf 'ephemeral host private key has unsafe permissions\n' >&2
  exit 1
fi
expected_hostkey="HostKey ${runtime_directory}/ssh_host_ed25519_key"
if [[ "$(< "${runtime_directory}/hostkey.conf")" != "${expected_hostkey}" ]]; then
  printf 'maintenance sshd include does not select the ephemeral key\n' >&2
  exit 1
fi
if [[ "$(< "${ssh_directory}/sshd_config")" != 'config sentinel' ]]; then
  printf 'host-key cleanup changed unrelated SSH configuration\n' >&2
  exit 1
fi

VIRTDEV_FW_CFG_PROJECT="${project_file}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${runtime_directory}" \
VIRTDEV_SSH_KEYGEN="${repository}/tests/fixtures/ssh-keygen-hostkeys" \
SSH_KEYGEN_ALL_MARKER="${all_marker}" \
  "${helper}" generate
if [[ -e "${all_marker}" ]]; then
  printf 'maintenance invoked persistent host-key generation\n' >&2
  exit 1
fi

rm -f -- "${runtime_directory}/maintenance"
status=0
VIRTDEV_FW_CFG_PROJECT="${project_file}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${runtime_directory}" \
VIRTDEV_SSH_KEYGEN="${repository}/tests/fixtures/ssh-keygen-hostkeys" \
SSH_KEYGEN_ALL_MARKER="${all_marker}" \
  "${helper}" generate 2>/dev/null || status=$?
if (( status == 0 )) || [[ -e "${all_marker}" ]]; then
  printf 'incomplete maintenance preparation failed open\n' >&2
  exit 1
fi

printf %s project-one > "${project_file}"
project_ssh="${test_tmp}/project-ssh"
project_runtime="${test_tmp}/project-run"
mkdir -p "${project_ssh}"
printf 'keep\n' > "${project_ssh}/ssh_host_ed25519_key"
VIRTDEV_FW_CFG_PROJECT="${project_file}" \
VIRTDEV_SSH_DIRECTORY="${project_ssh}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${project_runtime}" \
  "${helper}" prepare
if [[ "$(< "${project_ssh}/ssh_host_ed25519_key")" != keep \
      || -e "${project_runtime}/maintenance" ]]; then
  printf 'ordinary project identity was treated as maintenance\n' >&2
  exit 1
fi

VIRTDEV_FW_CFG_PROJECT="${project_file}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${project_runtime}" \
VIRTDEV_SSH_KEYGEN="${repository}/tests/fixtures/ssh-keygen-hostkeys" \
SSH_KEYGEN_ALL_MARKER="${all_marker}" \
  "${helper}" generate
if [[ ! -e "${all_marker}" ]]; then
  printf 'ordinary project skipped persistent host-key generation\n' >&2
  exit 1
fi

missing_project="${test_tmp}/missing-project"
status=0
VIRTDEV_FW_CFG_PROJECT="${missing_project}" \
VIRTDEV_SSH_DIRECTORY="${project_ssh}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${test_tmp}/missing-run" \
  "${helper}" prepare 2>/dev/null || status=$?
if (( status == 0 )); then
  printf 'missing fw_cfg identity was accepted\n' >&2
  exit 1
fi

install_ssh="${test_tmp}/install-target/etc/ssh"
mkdir -p "${install_ssh}"
printf 'hook private\n' > "${install_ssh}/ssh_host_ed25519_key"
printf 'hook public\n' > "${install_ssh}/ssh_host_ed25519_key.pub"
printf 'future private\n' > "${install_ssh}/ssh_host_mldsa44_ed25519_key"
VIRTDEV_SSH_DIRECTORY="${install_ssh}" "${helper}" scrub
if compgen -G "${install_ssh}/ssh_host_*_key" >/dev/null \
    || compgen -G "${install_ssh}/ssh_host_*_key.pub" >/dev/null; then
  printf 'final installer scrub preserved a hook-generated host key\n' >&2
  exit 1
fi

parser_ssh="${test_tmp}/parser-ssh"
parser_runtime="${test_tmp}/parser-run"
mkdir -p "${parser_ssh}"

assert_project_rejected() {
  local -r description="${1}"
  status=0
  VIRTDEV_FW_CFG_PROJECT="${project_file}" \
  VIRTDEV_SSH_DIRECTORY="${parser_ssh}" \
  VIRTDEV_SSH_RUNTIME_DIRECTORY="${parser_runtime}" \
    "${helper}" prepare 2>/dev/null || status=$?
  if (( status == 0 )) || [[ -e "${parser_runtime}/maintenance" ]]; then
    printf 'invalid fw_cfg identity was accepted: %s\n' \
      "${description}" >&2
    exit 1
  fi
  rm -rf -- "${parser_runtime}"
}

: > "${project_file}"
assert_project_rejected empty
printf 'maintenance\n' > "${project_file}"
assert_project_rejected newline
printf 'maintenance\0suffix' > "${project_file}"
assert_project_rejected NUL
printf 'project/name' > "${project_file}"
assert_project_rejected character
printf '%065d' 0 > "${project_file}"
assert_project_rejected length

printf %s maintenance-other > "${project_file}"
printf 'prefix sentinel\n' > "${parser_ssh}/ssh_host_ed25519_key"
VIRTDEV_FW_CFG_PROJECT="${project_file}" \
VIRTDEV_SSH_DIRECTORY="${parser_ssh}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${parser_runtime}" \
  "${helper}" prepare
if [[ "$(< "${parser_ssh}/ssh_host_ed25519_key")" != 'prefix sentinel' \
      || -e "${parser_runtime}/maintenance" ]]; then
  printf 'maintenance prefix was treated as the reserved identity\n' >&2
  exit 1
fi

failure_bin="${test_tmp}/failure-bin"
mkdir -p "${failure_bin}"
ln -s "${repository}/tests/fixtures/rm-hostkeys" "${failure_bin}/rm"
ln -s "${repository}/tests/fixtures/sync-hostkeys" "${failure_bin}/sync"
printf %s maintenance > "${project_file}"

for unsafe_type in directory fifo; do
  unsafe_ssh="${test_tmp}/unsafe-${unsafe_type}-ssh"
  unsafe_runtime="${test_tmp}/unsafe-${unsafe_type}-run"
  mkdir -p "${unsafe_ssh}"
  if [[ "${unsafe_type}" == directory ]]; then
    mkdir "${unsafe_ssh}/ssh_host_future_key"
  else
    mkfifo "${unsafe_ssh}/ssh_host_future_key"
  fi
  status=0
  VIRTDEV_FW_CFG_PROJECT="${project_file}" \
  VIRTDEV_SSH_DIRECTORY="${unsafe_ssh}" \
  VIRTDEV_SSH_RUNTIME_DIRECTORY="${unsafe_runtime}" \
    "${helper}" prepare 2>/dev/null || status=$?
  if (( status == 0 )) || [[ -e "${unsafe_runtime}/maintenance" ]]; then
    printf 'unsafe %s host-key entry was accepted\n' \
      "${unsafe_type}" >&2
    exit 1
  fi
done

keygen_ssh="${test_tmp}/keygen-failure-ssh"
keygen_runtime="${test_tmp}/keygen-failure-run"
mkdir -p "${keygen_ssh}"
printf 'persistent\n' > "${keygen_ssh}/ssh_host_ed25519_key"
status=0
VIRTDEV_FW_CFG_PROJECT="${project_file}" \
VIRTDEV_SSH_DIRECTORY="${keygen_ssh}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${keygen_runtime}" \
VIRTDEV_SSH_KEYGEN=/usr/bin/false \
  "${helper}" prepare 2>/dev/null || status=$?
if (( status == 0 )) || [[ -e "${keygen_runtime}/maintenance" ]] \
    || [[ ! -e "${keygen_ssh}/ssh_host_ed25519_key" ]]; then
  printf 'ephemeral key-generation failure did not fail closed\n' >&2
  exit 1
fi

rm_ssh="${test_tmp}/rm-failure-ssh"
rm_runtime="${test_tmp}/rm-failure-run"
rm_target="${rm_ssh}/ssh_host_ed25519_key"
mkdir -p "${rm_ssh}"
printf 'persistent\n' > "${rm_target}"
status=0
PATH="${failure_bin}:${PATH}" \
SSH_RM_FAIL_TARGET="${rm_target}" \
VIRTDEV_FW_CFG_PROJECT="${project_file}" \
VIRTDEV_SSH_DIRECTORY="${rm_ssh}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${rm_runtime}" \
VIRTDEV_SSH_KEYGEN="${repository}/tests/fixtures/ssh-keygen-hostkeys" \
  "${helper}" prepare 2>/dev/null || status=$?
if (( status == 0 )) || [[ -e "${rm_runtime}/maintenance" ]] \
    || [[ ! -e "${rm_target}" ]]; then
  printf 'persistent key-removal failure did not fail closed\n' >&2
  exit 1
fi

sync_ssh="${test_tmp}/sync-failure-ssh"
sync_runtime="${test_tmp}/sync-failure-run"
mkdir -p "${sync_ssh}"
printf 'persistent\n' > "${sync_ssh}/ssh_host_ed25519_key"
status=0
PATH="${failure_bin}:${PATH}" \
VIRTDEV_FW_CFG_PROJECT="${project_file}" \
VIRTDEV_SSH_DIRECTORY="${sync_ssh}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${sync_runtime}" \
VIRTDEV_SSH_KEYGEN="${repository}/tests/fixtures/ssh-keygen-hostkeys" \
  "${helper}" prepare 2>/dev/null || status=$?
if (( status == 0 )) || [[ -e "${sync_runtime}/maintenance" ]]; then
  printf 'host-key deletion sync failure did not fail closed\n' >&2
  exit 1
fi

project_a_file="${test_tmp}/project-a"
project_b_file="${test_tmp}/project-b"
project_a_ssh="${test_tmp}/project-a-ssh"
project_b_ssh="${test_tmp}/project-b-ssh"
printf %s project-a > "${project_a_file}"
printf %s project-b > "${project_b_file}"
for project_case in a b; do
  project_path_name="project_${project_case}_file"
  ssh_path_name="project_${project_case}_ssh"
  project_path="${!project_path_name}"
  ssh_path="${!ssh_path_name}"
  lifecycle_marker="${test_tmp}/project-${project_case}-keygen"
  VIRTDEV_FW_CFG_PROJECT="${project_path}" \
  VIRTDEV_SSH_RUNTIME_DIRECTORY="${test_tmp}/project-${project_case}-run" \
  VIRTDEV_SSH_KEYGEN="${repository}/tests/fixtures/ssh-keygen-hostkeys" \
  SSH_KEYGEN_ALL_MARKER="${lifecycle_marker}" \
  SSH_KEYGEN_DIRECTORY="${ssh_path}" \
    "${helper}" generate
done
project_a_public="$(< "${project_a_ssh}/ssh_host_ed25519_key.pub")"
project_b_public="$(< "${project_b_ssh}/ssh_host_ed25519_key.pub")"
if [[ "${project_a_public}" == "${project_b_public}" ]]; then
  printf 'two projects received the same host identity\n' >&2
  exit 1
fi
VIRTDEV_FW_CFG_PROJECT="${project_a_file}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${test_tmp}/project-a-run" \
VIRTDEV_SSH_KEYGEN="${repository}/tests/fixtures/ssh-keygen-hostkeys" \
SSH_KEYGEN_ALL_MARKER="${test_tmp}/project-a-keygen" \
SSH_KEYGEN_DIRECTORY="${project_a_ssh}" \
  "${helper}" generate
if [[ "$(< "${project_a_ssh}/ssh_host_ed25519_key.pub")" \
      != "${project_a_public}" ]]; then
  printf 'ordinary project host identity changed across restart\n' >&2
  exit 1
fi
rm -f -- "${project_a_ssh}/ssh_host_ed25519_key" \
  "${project_a_ssh}/ssh_host_ed25519_key.pub"
VIRTDEV_FW_CFG_PROJECT="${project_a_file}" \
VIRTDEV_SSH_RUNTIME_DIRECTORY="${test_tmp}/project-a-run" \
VIRTDEV_SSH_KEYGEN="${repository}/tests/fixtures/ssh-keygen-hostkeys" \
SSH_KEYGEN_ALL_MARKER="${test_tmp}/project-a-keygen" \
SSH_KEYGEN_DIRECTORY="${project_a_ssh}" \
  "${helper}" generate
if [[ "$(< "${project_a_ssh}/ssh_host_ed25519_key.pub")" \
      == "${project_a_public}" ]]; then
  printf 'recreated project retained its old host identity\n' >&2
  exit 1
fi

install_script="${repository}/iso/airootfs/root/virtdev/install.sh"
profiledef="${repository}/iso/profiledef.sh"
prepare_unit="${repository}/iso/airootfs/root/virtdev/virtdev-ssh-hostkeys.service"
sshd_dropin="${repository}/iso/airootfs/root/virtdev/sshd-virtdev-hostkeys.conf"
keygen_dropin="${repository}/iso/airootfs/root/virtdev/sshdgenkeys-virtdev-hostkeys.conf"
sshd_config="${repository}/iso/airootfs/etc/ssh/sshd_config"

assert_line() {
  local -r file="${1}" line="${2}"
  grep -Fqx -- "${line}" "${file}" || {
    printf 'missing integration line in %s: %s\n' "${file}" "${line}" >&2
    exit 1
  }
}

assert_text() {
  local -r file="${1}" value="${2}"
  grep -Fq -- "${value}" "${file}" || {
    printf 'missing installation wiring in %s: %s\n' \
      "${file}" "${value}" >&2
    exit 1
  }
}

assert_line "${prepare_unit}" 'After=systemd-modules-load.service'
assert_line "${prepare_unit}" 'Before=sshdgenkeys.service sshd.service'
assert_line "${prepare_unit}" \
  'ExecStart=/usr/local/lib/virtdev/ssh-hostkeys prepare'
assert_line "${sshd_dropin}" \
  'Requires=virtdev-ssh-hostkeys.service sshdgenkeys.service'
assert_line "${sshd_dropin}" \
  'After=virtdev-ssh-hostkeys.service sshdgenkeys.service'
assert_line "${keygen_dropin}" 'Requires=virtdev-ssh-hostkeys.service'
assert_line "${keygen_dropin}" 'After=virtdev-ssh-hostkeys.service'
assert_line "${keygen_dropin}" 'ExecStart='
assert_line "${keygen_dropin}" \
  'ExecStart=/usr/local/lib/virtdev/ssh-hostkeys generate'
assert_line "${sshd_config}" 'Include                  /run/virtdev-sshd/*.conf'
for installed_asset in virtdev-ssh-hostkeys \
    virtdev-ssh-hostkeys.service sshd-virtdev-hostkeys.conf \
    sshdgenkeys-virtdev-hostkeys.conf; do
  assert_text "${install_script}" "/root/virtdev/${installed_asset}"
done
assert_text "${install_script}" \
  '/usr/local/lib/virtdev/ssh-hostkeys'
assert_text "${install_script}" \
  '/etc/systemd/system/virtdev-ssh-hostkeys.service'
assert_text "${install_script}" \
  '/etc/systemd/system/sshd.service.d/virtdev-hostkeys.conf'
assert_text "${install_script}" \
  '/etc/systemd/system/sshdgenkeys.service.d/virtdev-hostkeys.conf'
assert_line "${profiledef}" \
  '  ["/root/virtdev/virtdev-ssh-hostkeys"]="0:0:755"'
if [[ "$(stat -c '%a' "${helper}")" != 755 ]]; then
  printf 'ISO host-key helper is not executable in the source profile\n' >&2
  exit 1
fi
inventory_hook_line="$(grep -nF "arch-chroot \"\${target}\" /tmp/virtdev-inventory.sh" \
  "${install_script}" | cut -d: -f1)"
final_scrub_line="$(grep -nF \
  "arch-chroot \"\${target}\" /usr/local/lib/virtdev/ssh-hostkeys scrub" \
  "${install_script}" | cut -d: -f1)"
final_sync_line="$(grep -nFx 'sync' "${install_script}" | tail -1 | cut -d: -f1)"
if [[ -z "${inventory_hook_line}" || -z "${final_scrub_line}" \
      || -z "${final_sync_line}" ]] \
    || (( final_scrub_line <= inventory_hook_line \
      || final_scrub_line >= final_sync_line )); then
  printf 'installer host-key scrub is not after hooks and before final sync\n' >&2
  exit 1
fi

unit_directory="${test_tmp}/units"
mkdir -p "${unit_directory}/sshd.service.d" \
  "${unit_directory}/sshdgenkeys.service.d"
install -m 0644 /usr/lib/systemd/system/sshd.service \
  "${unit_directory}/sshd.service"
install -m 0644 /usr/lib/systemd/system/sshdgenkeys.service \
  "${unit_directory}/sshdgenkeys.service"
sed 's|/usr/local/lib/virtdev/ssh-hostkeys|/usr/bin/true|' \
  "${prepare_unit}" > "${unit_directory}/virtdev-ssh-hostkeys.service"
install -m 0644 "${sshd_dropin}" \
  "${unit_directory}/sshd.service.d/virtdev-hostkeys.conf"
sed 's|/usr/local/lib/virtdev/ssh-hostkeys|/usr/bin/true|' \
  "${keygen_dropin}" \
  > "${unit_directory}/sshdgenkeys.service.d/virtdev-hostkeys.conf"
SYSTEMD_UNIT_PATH="${unit_directory}:" \
  systemd-analyze verify sshd.service >/dev/null

sshd_runtime="${test_tmp}/sshd-runtime"
mkdir -p "${sshd_runtime}"
/usr/bin/ssh-keygen -q -t ed25519 -N '' \
  -f "${sshd_runtime}/ssh_host_ed25519_key"
printf 'HostKey %s\n' "${sshd_runtime}/ssh_host_ed25519_key" \
  > "${sshd_runtime}/hostkey.conf"
sed -e "s|^Include .*|Include ${sshd_runtime}/*.conf|" \
  -e "s|^HostKey .*|HostKey ${test_tmp}/missing-host-key|" \
  "${sshd_config}" > "${test_tmp}/sshd_config"
/usr/bin/sshd -t -f "${test_tmp}/sshd_config" 2>/dev/null

printf 'ok - maintenance uses an ephemeral host key and scrubs legacy keys\n'
printf 'ok - ordinary projects retain distinct lifecycle-bound identities\n'
printf 'ok - malformed identity and preparation failures block sshd\n'
printf 'ok - final install scrub removes hook-generated host keys\n'
printf 'ok - install, systemd, and OpenSSH wiring selects the right key\n'
