#!/usr/bin/env bash
# shellcheck disable=SC2154  # machine constants provided by import

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

export VIRTDEV_HOME="${test_tmp}/virtdev"
export PATH="${repository}/tests/fixtures:${PATH}"
mkdir -p "${VIRTDEV_HOME}/projects/probe" \
  "${VIRTDEV_HOME}/projects/maintenance" "${VIRTDEV_HOME}/maintenance"

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import machine project

machine_target_require probe
if [[ "${VIRTDEV_MACHINE_KIND}" != project \
      || "${VIRTDEV_MACHINE_UNIT}" != virtdev-probe \
      || "${VIRTDEV_MACHINE_DATA_DIR}" != "${VIRTDEV_HOME}/projects/probe" \
      || "${VIRTDEV_MACHINE_RUNTIME_DIR}" != "${VIRTDEV_HOME}/projects/probe" ]]; then
  printf 'ordinary project descriptor is inconsistent\n' >&2
  exit 1
fi

machine_target_require maintenance
if [[ "${VIRTDEV_MACHINE_KIND}" != maintenance \
      || "${VIRTDEV_MACHINE_UNIT}" != virtdev-maintenance \
      || "${VIRTDEV_MACHINE_DATA_DIR}" != "${VIRTDEV_HOME}/maintenance" \
      || "${VIRTDEV_MACHINE_RUNTIME_DIR}" != "${VIRTDEV_HOME}/projects/maintenance" ]]; then
  printf 'maintenance descriptor did not separate data and runtime roots\n' >&2
  exit 1
fi

status=0
(project_require_ordinary maintenance) >/dev/null 2>&1 || status=$?
if (( status != 3 )); then
  printf 'ordinary project validation accepted maintenance (status %d)\n' "${status}" >&2
  exit 1
fi

mkdir -p "${test_tmp}/outside-project"
ln -s "${test_tmp}/outside-project" \
  "${VIRTDEV_HOME}/projects/linked-project"
status=0
machine_target_require linked-project || status=$?
if (( status != machine_target_missing )); then
  printf 'machine target accepted a symlinked project root (status %d)\n' \
    "${status}" >&2
  exit 1
fi
status=0
(project_require linked-project) >/dev/null 2>&1 || status=$?
if (( status != 3 )); then
  printf 'project requirement accepted a symlinked root (status %d)\n' \
    "${status}" >&2
  exit 1
fi

status=0
NO_COLOR=1 "${repository}/bin/virtdev-disk" maintenance \
  >"${test_tmp}/disk-output" 2>&1 || status=$?
if (( status != 3 )) || ! grep -Fq 'Not an ordinary project target' \
    "${test_tmp}/disk-output"; then
  printf 'project data command accepted maintenance (status %d)\n' "${status}" >&2
  exit 1
fi

for target in base firewall 'bad.name' ''; do
  status=0
  machine_target_resolve "${target}" || status=$?
  if (( status != machine_target_invalid )); then
    printf 'reserved/invalid target %q returned %d\n' "${target}" "${status}" >&2
    exit 1
  fi
done

export SYSTEMCTL_ACTIVE_STATE=active
if [[ "$(machine_state maintenance)" != running \
      || "$("${repository}/bin/virtdev-status" maintenance)" != running ]]; then
  printf 'maintenance target did not share authoritative state mapping\n' >&2
  exit 1
fi

if [[ "$("${repository}/bin/virtdev-path" maintenance data)" \
        != "${VIRTDEV_HOME}/maintenance" \
      || "$("${repository}/bin/virtdev-path" maintenance runtime)" \
        != "${VIRTDEV_HOME}/projects/maintenance" ]]; then
  printf 'maintenance path resources did not use its descriptor\n' >&2
  exit 1
fi

rmdir "${VIRTDEV_HOME}/projects/maintenance" "${VIRTDEV_HOME}/maintenance"
export SYSTEMCTL_ACTIVE_STATE=inactive
if ! machine_target_require maintenance \
    || [[ "$("${repository}/bin/virtdev-status" maintenance)" != stopped ]]; then
  printf 'maintenance identity disappeared when its directories were absent\n' >&2
  exit 1
fi

printf 'ok - machine descriptors separate maintenance data and runtime roots\n'
printf 'ok - ordinary project validation rejects machine-only targets\n'
printf 'ok - ordinary project validation rejects symlinked roots\n'
printf 'ok - maintenance remains a stable stopped target between sessions\n'
