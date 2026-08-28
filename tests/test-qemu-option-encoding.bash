#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import qemu

sample=$'a,b,,c=d e\\f\n'
qemu_suboption_encode sample
if [[ "${sample}" != $'a,,b,,,,c=d e\\f\n' ]]; then
  printf 'QEMU suboption encoder changed bytes other than commas\n' >&2
  exit 1
fi

disk_dir='disk,a,,b=c d\e'
sock_dir='sock,a,,b=c d\e'
project='project,a,,b=c d\e'
ovmf_code='firmware,a,,b=c d\e'
standalone='standalone,a,,b=c d\e'

declare -a actual=()
qemu_command actual "${disk_dir}" "${sock_dir}" "${project}" \
  4096 4 "${ovmf_code}" -cdrom "${standalone}"

# shellcheck disable=SC2054  # commas are literal QEMU option syntax
declare -a expected=(
  qemu-system-x86_64
  -enable-kvm
  -cpu host
  -machine q35
  -m 4096
  -smp 4
  -drive 'if=pflash,format=raw,readonly=on,file=firmware,,a,,,,b=c d\e'
  -drive 'if=pflash,format=raw,file=disk,,a,,,,b=c d\e/nvram'
  -drive 'file=disk,,a,,,,b=c d\e/system.qcow2,if=virtio,format=qcow2'
  -drive 'file=disk,,a,,,,b=c d\e/home.qcow2,if=virtio,format=qcow2'
  -netdev 'stream,id=net0,server=off,addr.type=unix,addr.path=sock,,a,,,,b=c d\e/passt.sock'
  -device virtio-net-pci,netdev=net0
  -device virtio-rng-pci
  -display none
  -chardev 'socket,id=monitor,path=sock,,a,,,,b=c d\e/monitor.sock,server=on,wait=off'
  -monitor chardev:monitor
  -chardev 'socket,id=qmp,path=sock,,a,,,,b=c d\e/qmp.sock,server=on,wait=off'
  -mon chardev=qmp,mode=control
  -chardev 'socket,id=serial,path=sock,,a,,,,b=c d\e/console.sock,server=on,wait=off'
  -serial chardev:serial
  -fw_cfg 'name=opt/virtdev/project,string=project,,a,,,,b=c d\e'
  -cdrom 'standalone,a,,b=c d\e'
)

if (( ${#actual[@]} != ${#expected[@]} )); then
  printf 'QEMU argv length mismatch: expected %d, got %d\n' \
    "${#expected[@]}" "${#actual[@]}" >&2
  exit 1
fi
for (( index = 0; index < ${#expected[@]}; index++ )); do
  if [[ "${actual[index]}" != "${expected[index]}" ]]; then
    printf 'QEMU argv[%d] mismatch: expected %q, got %q\n' \
      "${index}" "${expected[index]}" "${actual[index]}" >&2
    exit 1
  fi
done

printf 'ok - QEMU comma suboptions are encoded without changing standalone argv\n'
