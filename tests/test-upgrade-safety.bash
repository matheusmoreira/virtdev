#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

virtdev_home="${test_tmp}/virtdev"
config_home="${test_tmp}/config"
mkdir -p "${virtdev_home}/system" "${virtdev_home}/projects/keep" \
  "${virtdev_home}/projects/omitted" "${config_home}"
printf '7\n' > "${virtdev_home}/system/generation"
printf 'ssh-host-identity=1\n' > "${virtdev_home}/system/guest-contract"
printf '7\n' > "${virtdev_home}/projects/keep/generation"
printf '7\n' > "${virtdev_home}/projects/omitted/generation"
printf 'etc/hostname\n' > "${virtdev_home}/projects/keep/manifest"

output="${test_tmp}/output"
status=0
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
  "${repository}/bin/virtdev-upgrade" --unfiltered --only=keep --yes \
  >"${output}" 2>&1 || status=$?

if (( status != 12 )); then
  printf 'expected exit 12, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

if ! grep -Fq 'Cannot reseal while coupled projects are excluded.' "${output}"; then
  printf 'missing coupled-project refusal\n' >&2
  cat "${output}" >&2
  exit 1
fi

if ! grep -Fq 'omitted' "${output}"; then
  printf 'refusal did not identify the omitted project\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - filtered upgrade refuses a coupled omitted project\n'

# A genuinely detached exclusion is safe for backing identity, but maintenance
# still requires it stopped. This must fail before Phase 1 touches `keep`.
printf 'detached\n' > "${virtdev_home}/projects/omitted/generation"
: > "${virtdev_home}/projects/omitted/system.qcow2"
: > "${virtdev_home}/projects/omitted/home.qcow2"
output="${test_tmp}/running-detached.output"
status=0
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${repository}/tests/fixtures:${PATH}" QEMU_HAS_BACKING=0 \
SYSTEMCTL_ACTIVE_STATE=active \
  "${repository}/bin/virtdev-upgrade" --unfiltered --only=keep --yes \
  >"${output}" 2>&1 || status=$?

if (( status != 13 )); then
  printf 'expected exit 13 for running detached exclusion, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if ! grep -Fq 'Excluded detached projects must be stopped before upgrade' "${output}"; then
  printf 'missing early running-exclusion refusal\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - upgrade preflights running excluded projects before Phase 1\n'

status=0
VIRTDEV_HOME="${virtdev_home}" XDG_CONFIG_HOME="${config_home}" \
PATH="${repository}/tests/fixtures:${PATH}" QEMU_INFO_STATUS=42 \
SYSTEMCTL_ACTIVE_STATE=inactive \
  "${repository}/bin/virtdev-upgrade" --unfiltered --only=keep --yes \
  >"${output}" 2>&1 || status=$?
if (( status != 9 )) \
    || ! grep -Fq 'topology is corrupt or cannot be inspected' "${output}"; then
  printf 'upgrade treated indeterminate detached topology as coupled (status %d)\n' \
    "${status}" >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - upgrade fails closed on indeterminate detached topology\n'

upgrade_root="${test_tmp}/upgrade-root"
upgrade_bin="${upgrade_root}/bin"
upgrade_fixtures="${test_tmp}/upgrade-fixtures"
mkdir -p "${upgrade_bin}" "${upgrade_root}/libexec/virtdev" \
  "${upgrade_fixtures}"
cp -a "${repository}/lib" "${upgrade_root}/lib"
cp "${repository}/bin/virtdev-upgrade" "${upgrade_bin}/virtdev-upgrade"
cp "${repository}/tests/fixtures/systemctl" "${upgrade_fixtures}/systemctl"
chmod 0755 "${upgrade_fixtures}/systemctl"
for command_name in backup start wait stop maintain recreate create restore ssh; do
  ln -s "${repository}/tests/fixtures/recreate-command" \
    "${upgrade_bin}/virtdev-${command_name}"
done

prepare_upgrade_home() {
  local -r home="${1}" generation="${2:-1}"
  rm -rf -- "${home}"
  mkdir -p "${home}/system" "${home}/projects/probe"
  printf '1\n' > "${home}/system/generation"
  printf 'ssh-host-identity=1\n' > "${home}/system/guest-contract"
  printf '%s\n' "${generation}" > "${home}/projects/probe/generation"
  printf 'data\n' > "${home}/projects/probe/manifest"
}

recovery_home="${test_tmp}/recovery-home"
recovery_config="${test_tmp}/recovery config"
recovery_snapshot='2026-08-29/12-00-00'
recovery_snapshot_path="${recovery_home}/backups/probe/${recovery_snapshot}"
provision_path="${recovery_config}/virtdev/projects/probe/provision"
prepare_upgrade_home "${recovery_home}"
mkdir -p "$(dirname "${provision_path}")"
printf 'true\n' > "${provision_path}"
recovery_output="${test_tmp}/upgrade-create-recovery.output"
status=0
PATH="${upgrade_bin}:${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
RECREATE_SNAPSHOT_PATH="${recovery_snapshot_path}" \
UPGRADE_RECREATE_STATUS=23 \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${recovery_config}" \
VIRTDEV_HOME="${recovery_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/recovery-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --unfiltered --yes --verbose \
    >"${recovery_output}" 2>&1 || status=$?
if (( status != 40 )); then
  printf 'upgrade did not report recreate create failure (status %d)\n' \
    "${status}" >&2
  cat "${recovery_output}" >&2
  exit 1
fi
mapfile -t recovery_commands < <(sed -n \
  's/^        \(virtdev-.*\)$/\1/p' "${recovery_output}")
if (( ${#recovery_commands[@]} != 5 )) \
    || [[ "${recovery_commands[0]}" != 'virtdev-create -- probe' \
      || "${recovery_commands[1]}" != 'virtdev-start --unfiltered -- probe' \
      || "${recovery_commands[2]}" != 'virtdev-wait -- probe' \
      || "${recovery_commands[3]}" != virtdev-ssh\ --\ probe\ --\ bash\ -s\ \<* \
      || "${recovery_commands[4]}" != \
        "virtdev-restore --verbose -- probe ${recovery_snapshot}" ]]; then
  printf 'upgrade create recovery was incomplete or out of order\n' >&2
  printf '    %s\n' "${recovery_commands[@]}" >&2
  exit 1
fi
restore_args_file="${test_tmp}/upgrade-restore.args"
ssh_args_file="${test_tmp}/upgrade-ssh.args"
for recovery_command in "${recovery_commands[@]}"; do
  PATH="${upgrade_bin}:${PATH}" \
  RECREATE_RESTORE_ARGS_FILE="${restore_args_file}" \
  RECREATE_SSH_ARGS_FILE="${ssh_args_file}" \
  VIRTDEV_HOME="${recovery_home}" \
    bash -c "${recovery_command}"
done
mapfile -d '' -t restore_args < "${restore_args_file}"
mapfile -d '' -t ssh_args < "${ssh_args_file}"
[[ "${restore_args[*]}" == "--verbose -- probe ${recovery_snapshot}" ]]
[[ "${ssh_args[*]}" == '-- probe -- bash -s' ]]

pinned_home="${test_tmp}/pinned-home"
pinned_config="${test_tmp}/pinned-config"
pinned_source="${pinned_config}/virtdev/projects/probe/provision"
pinned_capture="${test_tmp}/pinned-provision.capture"
prepare_upgrade_home "${pinned_home}"
mkdir -p "$(dirname "${pinned_source}")"
printf 'original\n' > "${pinned_source}"
pinned_output="${test_tmp}/upgrade-pinned.output"
status=0
PATH="${upgrade_bin}:${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
RECREATE_MUTATE_UPGRADE_PROVISION_SOURCE="${pinned_source}" \
UPGRADE_PROVISION_CAPTURE_FILE="${pinned_capture}" \
RECREATE_SNAPSHOT_PATH="${pinned_home}/backups/probe/${recovery_snapshot}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${pinned_config}" \
VIRTDEV_HOME="${pinned_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/pinned-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --unfiltered --yes \
    >"${pinned_output}" 2>&1 || status=$?
if (( status != 0 )) || [[ "$(< "${pinned_source}")" != mutated \
      || "$(< "${pinned_capture}")" != original ]] \
    || find "${pinned_home}/transactions" -mindepth 1 -print -quit \
      | grep -q .; then
  printf 'upgrade did not pin/clean its confirmed provision input (status %d)\n' \
    "${status}" >&2
  cat "${pinned_output}" >&2
  exit 1
fi

indeterminate_home="${test_tmp}/indeterminate-home"
prepare_upgrade_home "${indeterminate_home}"
indeterminate_output="${test_tmp}/upgrade-indeterminate.output"
status=0
PATH="${upgrade_bin}:${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
RECREATE_FAIL_STEPS=wait,stop \
RECREATE_SNAPSHOT_PATH="${indeterminate_home}/backups/probe/${recovery_snapshot}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/no-config" \
VIRTDEV_HOME="${indeterminate_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/indeterminate-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --unfiltered --yes \
    >"${indeterminate_output}" 2>&1 || status=$?
if (( status != 20 )) \
    || ! grep -Fq 'Virtual machines whose stop could not be proven:' \
      "${indeterminate_output}" \
    || grep -Fq 'Virtual machines stopped during this phase:' \
      "${indeterminate_output}"; then
  printf 'upgrade mislabeled a failed cleanup stop (status %d)\n' \
    "${status}" >&2
  cat "${indeterminate_output}" >&2
  exit 1
fi

maintain_home="${test_tmp}/maintain-home"
prepare_upgrade_home "${maintain_home}"
maintain_output="${test_tmp}/upgrade-maintain-indeterminate.output"
status=0
PATH="${upgrade_bin}:${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
RECREATE_MAINTAIN_STATUS=27 \
RECREATE_SNAPSHOT_PATH="${maintain_home}/backups/probe/${recovery_snapshot}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/no-config" \
VIRTDEV_HOME="${maintain_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/maintain-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --unfiltered --yes \
    >"${maintain_output}" 2>&1 || status=$?
if (( status != 31 )) \
    || ! grep -Fq 'Do not start them.' "${maintain_output}" \
    || ! grep -Fq "system:      ${maintain_home}/system" "${maintain_output}" \
    || ! grep -Fq "maintenance: ${maintain_home}/maintenance" "${maintain_output}" \
    || grep -Fq 'Base is unchanged' "${maintain_output}" \
    || grep -Fq 'virtdev-start --' "${maintain_output}"; then
  printf 'upgrade lost indeterminate maintain commit state (status %d)\n' \
    "${status}" >&2
  cat "${maintain_output}" >&2
  exit 1
fi

cleanup_home="${test_tmp}/cleanup-home"
prepare_upgrade_home "${cleanup_home}"
cleanup_output="${test_tmp}/upgrade-cleanup.output"
status=0
PATH="${upgrade_bin}:${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
RECREATE_FAIL_STEPS=wait \
RECREATE_STOP_STATUS=7 \
RECREATE_SNAPSHOT_PATH="${cleanup_home}/backups/probe/${recovery_snapshot}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/no-config" \
VIRTDEV_HOME="${cleanup_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/cleanup-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --unfiltered --yes \
    >"${cleanup_output}" 2>&1 || status=$?
if (( status != 20 )) \
    || ! grep -Fq 'Stopped virtual machines with incomplete runtime cleanup:' \
      "${cleanup_output}" \
    || grep -Fq 'Virtual machines whose stop could not be proven:' \
      "${cleanup_output}"; then
  printf 'upgrade misclassified stopped-but-unclean state (status %d)\n' \
    "${status}" >&2
  cat "${cleanup_output}" >&2
  exit 1
fi

outdated_home="${test_tmp}/outdated-home"
prepare_upgrade_home "${outdated_home}" 0
outdated_output="${test_tmp}/upgrade-outdated.output"
status=0
PATH="${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/no-config" \
VIRTDEV_HOME="${outdated_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/outdated-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --unfiltered --yes \
    >"${outdated_output}" 2>&1 || status=$?
if (( status != 7 )) || grep -Fq -- '--skip-outdated' "${outdated_output}" \
    || ! grep -Fq 'Do not exclude or destroy them' "${outdated_output}"; then
  printf 'outdated upgrade did not fail with data-safe guidance (status %d)\n' \
    "${status}" >&2
  cat "${outdated_output}" >&2
  exit 1
fi
status=0
PATH="${upgrade_fixtures}:${PATH}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/no-config" \
VIRTDEV_HOME="${outdated_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/outdated-locks-flag" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --skip-outdated --unfiltered --yes \
    >"${test_tmp}/upgrade-removed-flag.output" 2>&1 || status=$?
(( status == 64 ))

missing_generation_home="${test_tmp}/missing-generation-home"
prepare_upgrade_home "${missing_generation_home}"
rm -f "${missing_generation_home}/projects/probe/generation"
missing_generation_log="${test_tmp}/missing-generation.commands"
status=0
PATH="${upgrade_bin}:${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
RECREATE_COMMAND_LOG="${missing_generation_log}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/no-config" \
VIRTDEV_HOME="${missing_generation_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/missing-generation-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --unfiltered --yes \
    >"${test_tmp}/upgrade-missing-generation.output" 2>&1 || status=$?
if (( status != 9 )) || [[ -e "${missing_generation_log}" ]]; then
  printf 'upgrade crossed command preflight with missing generation (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/upgrade-missing-generation.output" >&2
  exit 1
fi

preflight_home="${test_tmp}/preflight-home"
prepare_upgrade_home "${preflight_home}"
preflight_log="${test_tmp}/preflight.commands"
status=0
PATH="${upgrade_bin}:${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
RECREATE_COMMAND_LOG="${preflight_log}" \
RECREATE_FAIL_PREFLIGHT=1 \
RECREATE_SNAPSHOT_PATH="${preflight_home}/backups/probe/${recovery_snapshot}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/no-config" \
VIRTDEV_HOME="${preflight_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/preflight-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --unfiltered --yes \
    >"${test_tmp}/upgrade-preflight.output" 2>&1 || status=$?
if (( status != 20 )) \
    || ! grep -Fxq restore "${preflight_log}" \
    || grep -Fxq maintain "${preflight_log}"; then
  printf 'upgrade crossed maintenance after exact snapshot preflight failure (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/upgrade-preflight.output" >&2
  exit 1
fi

captured_zone_home="${test_tmp}/captured-zone-home"
prepare_upgrade_home "${captured_zone_home}"
captured_zone_output="${test_tmp}/upgrade-captured-zone.output"
status=0
PATH="${upgrade_bin}:${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=active \
SYSTEMCTL_SLICE=virtdev-wan.slice \
RECREATE_FAIL_PREFLIGHT=1 \
RECREATE_SNAPSHOT_PATH="${captured_zone_home}/backups/probe/${recovery_snapshot}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/no-config" \
VIRTDEV_HOME="${captured_zone_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/captured-zone-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --unfiltered --yes \
    >"${captured_zone_output}" 2>&1 || status=$?
if (( status != 20 )) \
    || ! grep -Fq \
      'virtdev-start --zone wan --unfiltered -- probe' \
      "${captured_zone_output}"; then
  printf 'phase-1 recovery discarded a captured transient zone (status %d)\n' \
    "${status}" >&2
  cat "${captured_zone_output}" >&2
  exit 1
fi

explicit_zone_home="${test_tmp}/explicit-zone-home"
prepare_upgrade_home "${explicit_zone_home}"
explicit_zone_output="${test_tmp}/upgrade-explicit-zone.output"
status=0
PATH="${upgrade_bin}:${upgrade_fixtures}:${PATH}" \
SYSTEMCTL_ACTIVE_STATE=inactive \
RECREATE_MAINTAIN_STATUS=1 \
RECREATE_SNAPSHOT_PATH="${explicit_zone_home}/backups/probe/${recovery_snapshot}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/no-config" \
VIRTDEV_HOME="${explicit_zone_home}" \
VIRTDEV_LOCK_DIRECTORY="${test_tmp}/explicit-zone-locks" \
NO_COLOR=1 \
  "${upgrade_bin}/virtdev-upgrade" --zone full --unfiltered --yes \
    >"${explicit_zone_output}" 2>&1 || status=$?
if (( status != 30 )) \
    || ! grep -Fq \
      'virtdev-start --zone full --unfiltered -- probe' \
      "${explicit_zone_output}"; then
  printf 'maintenance recovery discarded the explicit upgrade zone (status %d)\n' \
    "${status}" >&2
  cat "${explicit_zone_output}" >&2
  exit 1
fi

printf 'ok - upgrade emits executable phase-specific recovery\n'
printf 'ok - upgrade distinguishes failed stops from stopped machines\n'
printf 'ok - outdated projects fail closed without an impossible skip path\n'
printf 'ok - upgrade rejects missing generation before external commands\n'
printf 'ok - upgrade preflights exact snapshots before maintenance\n'
printf 'ok - upgrade recovery preserves captured and explicit zones\n'
