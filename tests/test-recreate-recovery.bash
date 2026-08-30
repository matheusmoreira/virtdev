#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

test_root="${test_tmp}/root"
test_bin="${test_root}/bin"
fixture_bin="${test_tmp}/fixtures"
virtdev_home="${test_tmp}/store"
project_directory="${virtdev_home}/projects/probe"
backups_directory="${virtdev_home}/backups/probe/2026-08-29"
old_snapshot='2026-08-29/12-00-00'
latest_snapshot='2026-08-29/13-00-00'
backup_snapshot='2026-08-29/14-00-00'
mkdir -p "${test_bin}" "${test_root}/libexec/virtdev" "${fixture_bin}" \
  "${virtdev_home}/system" "${backups_directory}/12-00-00/tree" \
  "${backups_directory}/13-00-00/tree"
cp -a "${repository}/lib" "${test_root}/lib"
cp "${repository}/bin/virtdev-recreate" "${test_bin}/virtdev-recreate"
cp "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
chmod 0755 "${fixture_bin}/systemctl"
for command_name in backup stop destroy create start wait restore ssh; do
  ln -s "${repository}/tests/fixtures/recreate-command" \
    "${test_bin}/virtdev-${command_name}"
done
printf 'ssh-host-identity=1\n' > "${virtdev_home}/system/guest-contract"

prepare_project() {
  rm -rf -- "${project_directory}"
  mkdir -p "${project_directory}"
  printf 'home/\n' > "${project_directory}/manifest"
}

run_recreate() {
  local -r active_state="${1}" failure="${2}" output="${3}"
  shift 3
  local -a options=(--unfiltered --yes)
  local status=0

  if [[ "${RECREATE_WITH_PROVISION:-0}" != 1 ]]; then
    options+=(--no-provision)
  fi
  SYSTEMCTL_ACTIVE_STATE="${active_state}" \
  RECREATE_FAIL_STEP="${failure}" \
  RECREATE_FAIL_STEPS="${RECREATE_FAIL_STEPS:-}" \
  RECREATE_SNAPSHOT_PATH="${virtdev_home}/backups/probe/${backup_snapshot}" \
  PATH="${fixture_bin}:${PATH}" \
  HOME="${test_tmp}" \
  XDG_CONFIG_HOME="${test_tmp}/config" \
  VIRTDEV_HOME="${virtdev_home}" \
  VIRTDEV_LOCK_DIRECTORY="${test_tmp}/locks" \
  NO_COLOR=1 \
    "${test_bin}/virtdev-recreate" "${options[@]}" "$@" probe \
      > "${output}" 2>&1 || status=$?
  printf '%d' "${status}"
}

for failure in stop destroy create start wait; do
  prepare_project
  output="${test_tmp}/${failure}.output"
  active_state=inactive
  expected_status=22
  case "${failure}" in
    stop) active_state=active; expected_status=21 ;;
    create) expected_status=23 ;;
    start) expected_status=24 ;;
    wait) expected_status=25 ;;
  esac
  status="$(run_recreate "${active_state}" "${failure}" "${output}" \
    --no-backup --snapshot "${old_snapshot}")"
  if (( status != expected_status )); then
    printf 'recreate %s fixture returned %d, expected %d\n' \
      "${failure}" "${status}" "${expected_status}" >&2
    cat "${output}" >&2
    exit 1
  fi
  case "${failure}" in
    stop|destroy)
      grep -Fq "virtdev-recreate --no-backup --snapshot ${old_snapshot}" \
        "${output}"
      ;;
    create|start|wait)
      grep -Fq "virtdev-restore probe ${old_snapshot}" "${output}"
      ;;
  esac
done

grep -Fq "systemctl --user status virtdev-probe" "${test_tmp}/start.output"
grep -Fq "fixed unit's ownership is" "${test_tmp}/start.output"
grep -Fq 'wait for inactive/failed state' "${test_tmp}/start.output"

prepare_project
backup_output="${test_tmp}/backup-stop.output"
status="$(run_recreate active stop "${backup_output}")"
if (( status != 21 )); then
  printf 'recreate did not reach post-backup stop failure (status %d)\n' \
    "${status}" >&2
  cat "${backup_output}" >&2
  exit 1
fi
grep -Fq "virtdev-recreate --no-backup --snapshot ${backup_snapshot}" \
  "${backup_output}"
rm -rf -- "${virtdev_home}/backups/probe/${backup_snapshot}"

prepare_project
latest_output="${test_tmp}/latest-wait.output"
status="$(run_recreate inactive wait "${latest_output}" --no-backup)"
if (( status != 25 )); then
  printf 'recreate did not reach latest-snapshot wait failure (status %d)\n' \
    "${status}" >&2
  cat "${latest_output}" >&2
  exit 1
fi
grep -Fq "virtdev-restore probe ${latest_snapshot}" "${latest_output}"

mkdir -p "${backups_directory}/15-00-00/tree"
recovery_command="$(sed -n 's/^    \(virtdev-restore .*\)$/\1/p' \
  "${latest_output}" | tail -n1)"
restore_args_file="${test_tmp}/restore.args"
PATH="${test_bin}:${PATH}" \
RECREATE_RESTORE_ARGS_FILE="${restore_args_file}" \
  bash -c "${recovery_command}"
mapfile -d '' -t restore_args < "${restore_args_file}"
if [[ "${restore_args[*]}" != "probe ${latest_snapshot}" ]]; then
  printf 'recovery command selected a newer snapshot: %q\n' \
    "${restore_args[@]}" >&2
  exit 1
fi

prepare_project
provision_path="${test_tmp}/provision hook.bash"
printf 'true\n' > "${provision_path}"
provision_output="${test_tmp}/provision-wait.output"
status="$(RECREATE_WITH_PROVISION=1 run_recreate inactive wait \
  "${provision_output}" --no-backup --snapshot "${old_snapshot}" \
  --provision "${provision_path}" --verbose)"
if (( status != 25 )); then
  printf 'recreate did not reach provisioned wait failure (status %d)\n' \
    "${status}" >&2
  cat "${provision_output}" >&2
  exit 1
fi
provision_line="$(grep -n -m1 '^    virtdev-ssh ' "${provision_output}" | cut -d: -f1)"
restore_line="$(grep -n -m1 '^    virtdev-restore ' "${provision_output}" | cut -d: -f1)"
grep -Fq "virtdev-restore --verbose probe ${old_snapshot}" \
  "${provision_output}"
if [[ -z "${provision_line}" || -z "${restore_line}" ]] \
  || (( provision_line >= restore_line )); then
  printf 'recovery did not preserve provision-before-restore order\n' >&2
  cat "${provision_output}" >&2
  exit 1
fi
provision_command="$(sed -n 's/^    \(virtdev-ssh .*\)$/\1/p' \
  "${provision_output}" | tail -n1)"
ssh_args_file="${test_tmp}/ssh.args"
PATH="${test_bin}:${PATH}" \
RECREATE_SSH_ARGS_FILE="${ssh_args_file}" \
  bash -c "${provision_command}"
mapfile -d '' -t ssh_args < "${ssh_args_file}"
if [[ "${ssh_args[*]}" != 'probe -- bash -s' ]]; then
  printf 'provision recovery command changed arguments: %q\n' \
    "${ssh_args[@]}" >&2
  exit 1
fi

prepare_project
provision_failure_output="${test_tmp}/provision-failure.output"
status="$(RECREATE_WITH_PROVISION=1 run_recreate inactive ssh \
  "${provision_failure_output}" --no-backup --snapshot "${old_snapshot}" \
  --provision "${provision_path}")"
if (( status != 26 )); then
  printf 'recreate did not report failed provisioning (status %d)\n' \
    "${status}" >&2
  cat "${provision_failure_output}" >&2
  exit 1
fi
provision_command="$(sed -n 's/^    \(virtdev-ssh .*\)$/\1/p' \
  "${provision_failure_output}" | tail -n1)"
rm -f -- "${ssh_args_file}"
PATH="${test_bin}:${PATH}" \
RECREATE_SSH_ARGS_FILE="${ssh_args_file}" \
  bash -c "${provision_command}"
mapfile -d '' -t ssh_args < "${ssh_args_file}"
[[ "${ssh_args[*]}" == 'probe -- bash -s' ]]

prepare_project
combined_failure_output="${test_tmp}/combined-failure.output"
status="$(RECREATE_WITH_PROVISION=1 RECREATE_FAIL_STEPS=ssh,restore \
  run_recreate inactive none "${combined_failure_output}" \
  --no-backup --snapshot "${old_snapshot}" \
  --provision "${provision_path}")"
if (( status != 27 )); then
  printf 'recreate did not report combined recovery failure (status %d)\n' \
    "${status}" >&2
  cat "${combined_failure_output}" >&2
  exit 1
fi
grep -Fq "Selected snapshot: ${backups_directory}/12-00-00/" \
  "${combined_failure_output}"
combined_provision_command="$(sed -n \
  's/^    \(virtdev-ssh .*\)$/\1/p' "${combined_failure_output}" | tail -n1)"
rm -f -- "${ssh_args_file}"
PATH="${test_bin}:${PATH}" \
RECREATE_SSH_ARGS_FILE="${ssh_args_file}" \
  bash -c "${combined_provision_command}"
mapfile -d '' -t ssh_args < "${ssh_args_file}"
[[ "${ssh_args[*]}" == 'probe -- bash -s' ]]

prepare_project
no_restore_output="${test_tmp}/no-restore-wait.output"
status="$(run_recreate inactive wait "${no_restore_output}" \
  --no-backup --no-restore)"
if (( status != 25 )); then
  printf 'recreate did not reach no-restore wait failure (status %d)\n' \
    "${status}" >&2
  cat "${no_restore_output}" >&2
  exit 1
fi
grep -Fq 'Once SSH is up, no later recreate steps remain.' \
  "${no_restore_output}"
if grep -Fq 'virtdev-restore' "${no_restore_output}"; then
  printf 'no-restore recovery incorrectly recommended restore\n' >&2
  cat "${no_restore_output}" >&2
  exit 1
fi

printf 'ok - recreate recovery commands retain the transaction snapshot\n'
printf 'ok - recreate recovery preserves selected post-wait steps\n'
printf 'ok - provision failure recovery preserves the selected script path\n'
printf 'ok - failed starts report indeterminate fixed-unit ownership\n'
