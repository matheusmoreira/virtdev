#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

virtdev_home="${test_tmp}/virtdev"
project_directory="${virtdev_home}/projects/probe"
mkdir -p "${project_directory}"
printf 'detached\n' > "${project_directory}/generation"
: > "${project_directory}/system.qcow2"
: > "${project_directory}/home.qcow2"

qemu-img() {
if [[ "${QEMU_HAS_BACKING:-0}" == 1 ]]; then
  printf '{"backing-filename":"/base/system.qcow2"}\n'
else
  printf '{}\n'
fi
}

export VIRTDEV_HOME="${virtdev_home}"
# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import project

QEMU_HAS_BACKING=1
export QEMU_HAS_BACKING
if project_is_detached probe; then
  printf 'text marker bypassed a real backing dependency\n' >&2
  exit 1
fi

QEMU_HAS_BACKING=0
export QEMU_HAS_BACKING
if ! project_is_detached probe; then
  printf 'standalone disks with detached marker were not recognized\n' >&2
  exit 1
fi

printf 'ok - detached state requires standalone disk topology\n'
