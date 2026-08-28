#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
mkdir -p "${fixture_bin}"
cp "${repository}/tests/fixtures/qemu-img-install" "${fixture_bin}/qemu-img"
cp "${repository}/tests/fixtures/qemu-system-x86_64-install" \
  "${fixture_bin}/qemu-system-x86_64"
chmod +x "${fixture_bin}/qemu-img" "${fixture_bin}/qemu-system-x86_64"

ssh_key="${test_tmp}/id"
printf 'test private key\n' > "${ssh_key}"
printf 'test public key\n' > "${ssh_key}.pub"
chmod 600 "${ssh_key}"

iso="${test_tmp}/virtdev.iso"
ovmf_code="${test_tmp}/OVMF_CODE.fd"
ovmf_vars="${test_tmp}/OVMF_VARS.fd"
: > "${iso}"
: > "${ovmf_code}"
: > "${ovmf_vars}"

run_installer() {
  local -r virtdev_home="${1}" mode="${2}" progress="${3}" \
    qemu_status="${4}" pid_file="${5}" term_file="${6}" output="${7}"
  PATH="${fixture_bin}:${PATH}" \
    NO_COLOR=1 \
    VIRTDEV_HOME="${virtdev_home}" \
    VIRTDEV_CACHE="${test_tmp}/cache" \
    VIRTDEV_ISO="${iso}" \
    VIRTDEV_SSH_KEY="${ssh_key}" \
    OVMF_CODE="${ovmf_code}" \
    OVMF_VARS="${ovmf_vars}" \
    VIRTDEV_INSTALL_SOCKET_TIMEOUT=1 \
    VIRTDEV_INSTALL_PROGRESS_TIMEOUT=3 \
    VIRTDEV_INSTALL_SHUTDOWN_TIMEOUT=2 \
    QEMU_TEST_MODE="${mode}" \
    QEMU_PROGRESS_FILE="${progress}" \
    QEMU_EXIT_STATUS="${qemu_status}" \
    QEMU_PID_FILE="${pid_file}" \
    QEMU_TERM_FILE="${term_file}" \
    "${repository}/bin/virtdev-install" >"${output}" 2>&1
}

stuck_home="${test_tmp}/stuck-home"
stuck_pid="${test_tmp}/stuck.pid"
stuck_term="${test_tmp}/stuck.term"
output="${test_tmp}/output"
status=0
run_installer "${stuck_home}" stuck /dev/null 0 \
  "${stuck_pid}" "${stuck_term}" "${output}" || status=$?

if (( status != 10 )); then
  printf 'expected progress-socket timeout exit 10, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ ! -f "${stuck_term}" ]]; then
  printf 'installer did not terminate its QEMU child on timeout\n' >&2
  cat "${output}" >&2
  exit 1
fi
if kill -0 "$(< "${stuck_pid}")" 2>/dev/null; then
  printf 'installer left QEMU alive after timeout cleanup\n' >&2
  exit 1
fi
if [[ -e "${stuck_home}/installation" ]]; then
  printf 'installer removed paths before child death or retained dead-child staging\n' >&2
  exit 1
fi

printf 'complete\n' > "${test_tmp}/complete.progress"
failed_home="${test_tmp}/failed-home"
status=0
run_installer "${failed_home}" progress "${test_tmp}/complete.progress" 42 \
  "${test_tmp}/failed.pid" "${test_tmp}/failed.term" "${output}" || status=$?

if (( status != 10 )); then
  printf 'expected post-complete QEMU failure exit 10, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if ! grep -Fq 'QEMU exited with status 42' "${output}"; then
  printf 'installer ignored or obscured the post-complete QEMU status\n' >&2
  cat "${output}" >&2
  exit 1
fi
if [[ -e "${failed_home}/installation" ]]; then
  printf 'failed clean-termination check preserved an accepted installation\n' >&2
  exit 1
fi

success_home="${test_tmp}/success-home"
run_installer "${success_home}" progress "${test_tmp}/complete.progress" 0 \
  "${test_tmp}/success.pid" "${test_tmp}/success.term" "${output}"

if [[ ! -d "${success_home}/installation" \
      || ! -f "${success_home}/installation/system.qcow2" ]]; then
  printf 'cleanly completed installation was not preserved for sealing\n' >&2
  cat "${output}" >&2
  exit 1
fi
if [[ -e "${success_home}/installation/install.sock" \
      || -e "${success_home}/installation/progress.fifo" ]]; then
  printf 'successful installation retained progress controls\n' >&2
  exit 1
fi

special_root="${test_tmp}/a,b,,c=d e\\f"
special_encoded_root="${test_tmp}/a,,b,,,,c=d e\\f"
special_home="${special_root}/home"
special_cache="${special_root}/cache"
special_iso="${special_root}/installer.iso"
special_ssh_key="${special_root}/id"
special_ovmf_code="${special_root}/OVMF_CODE.fd"
special_ovmf_vars="${special_root}/OVMF_VARS.fd"
special_packages="${special_root}/packages"
special_script="${special_root}/script"
special_inventory="${special_root}/inventory"
special_argv_file="${test_tmp}/special.argv"
mkdir -p "${special_root}"
for input in "${special_iso}" "${special_ovmf_code}" "${special_ovmf_vars}" \
             "${special_packages}" "${special_script}" "${special_inventory}"; do
  : > "${input}"
done
printf 'test private key\n' > "${special_ssh_key}"
printf 'test public key\n' > "${special_ssh_key}.pub"
chmod 600 "${special_ssh_key}"

status=0
PATH="${fixture_bin}:${PATH}" \
  NO_COLOR=1 \
  VIRTDEV_HOME="${special_home}" \
  VIRTDEV_CACHE="${special_cache}" \
  VIRTDEV_ISO="${special_iso}" \
  VIRTDEV_SSH_KEY="${special_ssh_key}" \
  VIRTDEV_TIMEZONE='tz,a,,b=c d\e' \
  VIRTDEV_LOCALE='locale,a,,b=c d\e' \
  VIRTDEV_KEYMAP='keymap,a,,b=c d\e' \
  VIRTDEV_INSTALL_DNS='2001:db8::53' \
  VIRTDEV_PACKAGES="${special_packages}" \
  VIRTDEV_SCRIPT="${special_script}" \
  VIRTDEV_INVENTORY="${special_inventory}" \
  OVMF_CODE="${special_ovmf_code}" \
  OVMF_VARS="${special_ovmf_vars}" \
  VIRTDEV_INSTALL_SOCKET_TIMEOUT=1 \
  VIRTDEV_INSTALL_PROGRESS_TIMEOUT=3 \
  VIRTDEV_INSTALL_SHUTDOWN_TIMEOUT=2 \
  QEMU_TEST_MODE=stuck \
  QEMU_PID_FILE="${test_tmp}/special.pid" \
  QEMU_TERM_FILE="${test_tmp}/special.term" \
  QEMU_ARGV_FILE="${special_argv_file}" \
  "${repository}/bin/virtdev-install" >"${output}" 2>&1 || status=$?
if (( status != 10 )); then
  printf 'expected special-path socket timeout exit 10, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

mapfile -d '' -t install_argv < "${special_argv_file}"
assert_install_pair() {
  local -r expected_option="${1}" expected_value="${2}"
  local index
  for (( index = 0; index + 1 < ${#install_argv[@]}; index++ )); do
    if [[ "${install_argv[index]}" == "${expected_option}" \
          && "${install_argv[index + 1]}" == "${expected_value}" ]]; then
      return 0
    fi
  done
  printf 'installer argv lacks exact pair %q %q\n' \
    "${expected_option}" "${expected_value}" >&2
  printf 'argv: ' >&2
  printf '%q ' "${install_argv[@]}" >&2
  printf '\n' >&2
  exit 1
}

encoded_home="${special_encoded_root}/home"
encoded_cache="${special_encoded_root}/cache"
assert_install_pair -drive \
  "if=pflash,format=raw,readonly=on,file=${special_encoded_root}/OVMF_CODE.fd"
assert_install_pair -drive \
  "if=pflash,format=raw,file=${encoded_home}/installation/nvram"
assert_install_pair -drive \
  "file=${encoded_home}/installation/system.qcow2,if=virtio,format=qcow2"
assert_install_pair -drive \
  "file=${encoded_home}/installation/home.qcow2,if=virtio,format=qcow2"
assert_install_pair -cdrom "${special_iso}"
assert_install_pair -serial \
  "unix:${encoded_home}/installation/console.sock,server=on,wait=off"
assert_install_pair -chardev \
  "socket,path=${encoded_home}/installation/install.sock,server=on,wait=off,id=install_ch"
assert_install_pair -virtfs \
  "local,path=${encoded_cache}/pacman,mount_tag=pacman_cache,security_model=mapped-xattr"
assert_install_pair -fw_cfg \
  "name=opt/virtdev/ssh_key,file=${special_encoded_root}/id.pub"
assert_install_pair -fw_cfg 'name=opt/virtdev/timezone,string=tz,,a,,,,b=c d\e'
assert_install_pair -fw_cfg 'name=opt/virtdev/locale,string=locale,,a,,,,b=c d\e'
assert_install_pair -fw_cfg 'name=opt/virtdev/keymap,string=keymap,,a,,,,b=c d\e'
assert_install_pair -fw_cfg 'name=opt/virtdev/dns,string=2001:db8::53'
assert_install_pair -fw_cfg \
  "name=opt/virtdev/packages,file=${special_encoded_root}/packages"
assert_install_pair -fw_cfg \
  "name=opt/virtdev/script,file=${special_encoded_root}/script"
assert_install_pair -fw_cfg \
  "name=opt/virtdev/inventory,file=${special_encoded_root}/inventory"

if ! grep -Fxq 'TimeoutStartSec=infinity' \
  "${repository}/iso/airootfs/etc/systemd/system/virtdev-install.service"; then
  printf 'guest installer retains a fixed wall-clock timeout\n' >&2
  exit 1
fi

printf 'ok - installer owns children, permits progress, and requires clean termination\n'
printf 'ok - installer comma-encodes structured QEMU values and preserves standalone argv\n'
