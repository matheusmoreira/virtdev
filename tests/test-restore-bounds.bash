#!/usr/bin/env bash
# shellcheck disable=SC2016  # child namespace script

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
gate_pid=''
gate_release=''
mmap_pid=''
mmap_trigger=''
mmap_release=''
cleanup() {
  if [[ -n "${gate_release}" ]]; then
    : > "${gate_release}"
  fi
  if [[ -n "${mmap_trigger}" ]]; then
    : > "${mmap_trigger}"
  fi
  if [[ -n "${mmap_release}" ]]; then
    : > "${mmap_release}"
  fi
  if [[ -n "${gate_pid}" ]]; then
    wait "${gate_pid}" 2>/dev/null || true
  fi
  if [[ -n "${mmap_pid}" ]]; then
    wait "${mmap_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

fixture_bin="${test_tmp}/bin"
mkdir "${fixture_bin}"
cp "${repository}/tests/fixtures/ssh-restore" "${fixture_bin}/ssh"
cp "${repository}/tests/fixtures/systemctl" "${fixture_bin}/systemctl"
chmod +x "${fixture_bin}/ssh" "${fixture_bin}/systemctl"
copy_helper="${repository}/libexec/virtdev/virtdev-copy-tree"

virtdev_home="${test_tmp}/store"
project_directory="${virtdev_home}/projects/probe"
snapshot="${virtdev_home}/backups/probe/2026-08-28/12-00-00"
mkdir -p "${project_directory}" "${snapshot}/tree/real/sub" \
  "${virtdev_home}/system"
printf '2222\n' > "${project_directory}/port"
printf '1\n' > "${project_directory}/generation"
printf 'ssh-host-identity=1\n' > "${project_directory}/guest-contract"
printf '1\n' > "${virtdev_home}/system/generation"
printf 'probe\n' > "${snapshot}/project"
printf '1\n' > "${snapshot}/generation"
printf '%s\n' 'real/' 'link/' 'link-two/' hard-one hard-two sparse \
  > "${snapshot}/manifest"
printf 'payload\n' > "${snapshot}/tree/real/sub/file"
ln -s real "${snapshot}/tree/link"
ln -P "${snapshot}/tree/link" "${snapshot}/tree/link-two"
printf 'linked payload\n' > "${snapshot}/tree/hard-one"
ln "${snapshot}/tree/hard-one" "${snapshot}/tree/hard-two"
truncate -s 2097152 "${snapshot}/tree/sparse"

ssh_key="${test_tmp}/id"
printf 'test private key\n' > "${ssh_key}"
chmod 600 "${ssh_key}"
(
  export VIRTDEV_HOME="${virtdev_home}"
  # shellcheck disable=SC1090
  source "${repository}/lib/virtdev/import"
  import ssh
  ssh_host_identity_ensure probe
)

run_restore() {
  local -r guest="${1}" maximum_bytes="${2}" maximum_entries="${3}"
  local -r timeout_seconds="${4}"
  shift 4
  mkdir -p "${guest}"
  PATH="${fixture_bin}:${PATH}" \
    HOME="${test_tmp}" \
    XDG_CONFIG_HOME="${test_tmp}/config" \
    NO_COLOR=1 \
    SYSTEMCTL_ACTIVE_STATE=active \
    VIRTDEV_HOME="${virtdev_home}" \
    VIRTDEV_SSH_KEY="${ssh_key}" \
    VIRTDEV_RESTORE_MAX_BYTES="${maximum_bytes}" \
    VIRTDEV_RESTORE_MAX_ENTRIES="${maximum_entries}" \
    VIRTDEV_RESTORE_TIMEOUT="${timeout_seconds}" \
    VIRTDEV_RESTORE_KILL_AFTER=1 \
    RESTORE_GUEST_ROOT="${guest}" \
    "$@" \
    "${repository}/bin/virtdev-restore" probe 2026-08-28/12-00-00
}

guest="${test_tmp}/guest"
logical_bytes=$((
  $(stat -c '%s' "${snapshot}/tree/real/sub/file")
  + $(stat -c '%s' "${snapshot}/tree/hard-one")
  + $(stat -c '%s' "${snapshot}/tree/sparse")
))
status=0
run_restore "${guest}" "${logical_bytes}" 100 10 \
  >"${test_tmp}/success.output" 2>&1 || status=$?
if (( status != 0 )) || [[ ! -f "${guest}/real/sub/file" \
      || ! -L "${guest}/link" \
      || "$(readlink "${guest}/link")" != real ]]; then
  printf 'real-rsync restore failed or dereferenced a symlink root (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/success.output" >&2
  exit 1
fi
if [[ "$(stat -c '%i' "${guest}/hard-one")" \
      != "$(stat -c '%i' "${guest}/hard-two")" ]]; then
  printf 'restore did not preserve hard-link identity\n' >&2
  exit 1
fi
if [[ ! -L "${guest}/link-two" \
      || "$(stat -c '%i' "${guest}/link")" \
         != "$(stat -c '%i' "${guest}/link-two")" ]]; then
  printf 'restore did not preserve hard-linked symlink identity\n' >&2
  exit 1
fi
sparse_size="$(stat -c '%s' "${guest}/sparse")"
sparse_blocks="$(stat -c '%b' "${guest}/sparse")"
if (( sparse_size != 2097152 || sparse_blocks * 512 >= sparse_size )); then
  printf 'restore expanded a sparse file\n' >&2
  exit 1
fi

latest_guest="${test_tmp}/latest-guest"
mkdir -p "${latest_guest}"
status=0
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/config" \
NO_COLOR=1 \
SYSTEMCTL_ACTIVE_STATE=active \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_SSH_KEY="${ssh_key}" \
VIRTDEV_RESTORE_MAX_BYTES="${logical_bytes}" \
VIRTDEV_RESTORE_MAX_ENTRIES=100 \
VIRTDEV_RESTORE_TIMEOUT=10 \
VIRTDEV_RESTORE_KILL_AFTER=1 \
RESTORE_GUEST_ROOT="${latest_guest}" \
  "${repository}/bin/virtdev-restore" probe \
    >"${test_tmp}/latest.output" 2>&1 || status=$?
if (( status != 0 )) || [[ ! -f "${latest_guest}/real/sub/file" ]]; then
  printf 'implicit-latest restore failed (status %d)\n' "${status}" >&2
  cat "${test_tmp}/latest.output" >&2
  exit 1
fi

preflight_guest="${test_tmp}/preflight-guest"
mkdir -p "${preflight_guest}"
status=0
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/config" \
NO_COLOR=1 \
SYSTEMCTL_ACTIVE_STATE=inactive \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_SSH_KEY="${test_tmp}/missing-key" \
VIRTDEV_RESTORE_MAX_BYTES="${logical_bytes}" \
VIRTDEV_RESTORE_MAX_ENTRIES=100 \
VIRTDEV_RESTORE_TIMEOUT=10 \
VIRTDEV_RESTORE_KILL_AFTER=1 \
RESTORE_GUEST_ROOT="${preflight_guest}" \
  "${repository}/bin/virtdev-restore" --preflight \
    probe 2026-08-28/12-00-00 \
    >"${test_tmp}/preflight.output" 2>&1 || status=$?
if (( status != 0 )) \
    || find "${preflight_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore preflight required transport or modified the guest (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/preflight.output" >&2
  exit 1
fi

printf 'probe\nextra\n' > "${snapshot}/project"
status=0
run_restore "${test_tmp}/oversized-marker-guest" "${logical_bytes}" 100 10 \
  >"${test_tmp}/oversized-marker.output" 2>&1 || status=$?
if (( status != 12 )); then
  printf 'restore accepted an inexact project marker (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/oversized-marker.output" >&2
  exit 1
fi
printf 'probe\n' > "${snapshot}/project"

truncate -s 1048577 "${snapshot}/manifest"
status=0
run_restore "${test_tmp}/oversized-manifest-guest" "${logical_bytes}" 100 10 \
  >"${test_tmp}/oversized-manifest.output" 2>&1 || status=$?
if (( status != 19 )); then
  printf 'restore accepted an oversized manifest (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/oversized-manifest.output" >&2
  exit 1
fi
printf '%s\n' 'real/' 'link/' 'link-two/' hard-one hard-two sparse \
  > "${snapshot}/manifest"

budget_guest="${test_tmp}/budget-guest"
status=0
run_restore "${budget_guest}" 1048576 100 10 \
  >"${test_tmp}/budget.output" 2>&1 || status=$?
if (( status != 19 )) \
    || find "${budget_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore apparent-byte budget failed open (status %d)\n' \
    "${status}" >&2
  exit 1
fi

boundary_guest="${test_tmp}/boundary-guest"
status=0
run_restore "${boundary_guest}" "$(( logical_bytes - 1 ))" 100 10 \
  >"${test_tmp}/boundary.output" 2>&1 || status=$?
if (( status != 19 )) \
    || find "${boundary_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore accepted a snapshot one byte over budget (status %d)\n' \
    "${status}" >&2
  exit 1
fi

mkdir "${snapshot}/tree/many"
: > "${snapshot}/tree/many/empty"
for entry in 1 2 3 4 5; do
  ln "${snapshot}/tree/many/empty" "${snapshot}/tree/many/hard-${entry}"
done
printf 'many/\n' >> "${snapshot}/manifest"

entry_guest="${test_tmp}/entry-guest"
entry_ssh_started="${test_tmp}/entry-ssh-started"
status=0
run_restore "${entry_guest}" "${logical_bytes}" 10 10 \
  env RESTORE_SSH_STARTED_FILE="${entry_ssh_started}" \
  >"${test_tmp}/entry.output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${entry_ssh_started}" ]] \
    || find "${entry_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore entry budget failed before guest transfer (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/entry.output" >&2
  exit 1
fi

outside="${test_tmp}/outside"
mkdir "${outside}"
printf 'host secret\n' > "${outside}/secret"
ln -s "${outside}" "${snapshot}/tree/escape"
printf 'escape/secret\n' >> "${snapshot}/manifest"
symlink_guest="${test_tmp}/symlink-guest"
symlink_ssh_started="${test_tmp}/symlink-ssh-started"
status=0
run_restore "${symlink_guest}" "${logical_bytes}" 100 10 \
  env RESTORE_SSH_STARTED_FILE="${symlink_ssh_started}" \
  >"${test_tmp}/symlink.output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${symlink_ssh_started}" ]] \
    || ! grep -Fq 'symlinked source path' "${test_tmp}/symlink.output" \
    || find "${symlink_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore followed an intermediate snapshot symlink (status %d)\n' \
    "${status}" >&2
  exit 1
fi
sed -i '\|^escape/secret$|d' "${snapshot}/manifest"
unlink "${snapshot}/tree/escape"

mount_source="${test_tmp}/mount-source"
mount_target="${snapshot}/tree/mounted"
mount_guest="${test_tmp}/mount-guest"
mount_ssh_started="${test_tmp}/mount-ssh-started"
mount_copy_parent="${test_tmp}/mount-copy-parent"
mkdir "${mount_source}" "${mount_target}" "${mount_guest}" \
  "${mount_copy_parent}"
printf 'mounted payload\n' > "${mount_source}/payload"
printf 'mounted/\n' >> "${snapshot}/manifest"
status=0
PATH="${fixture_bin}:${PATH}" \
HOME="${test_tmp}" \
XDG_CONFIG_HOME="${test_tmp}/config" \
NO_COLOR=1 \
SYSTEMCTL_ACTIVE_STATE=active \
VIRTDEV_HOME="${virtdev_home}" \
VIRTDEV_SSH_KEY="${ssh_key}" \
VIRTDEV_RESTORE_MAX_BYTES="${logical_bytes}" \
VIRTDEV_RESTORE_MAX_ENTRIES=100 \
VIRTDEV_RESTORE_TIMEOUT=10 \
VIRTDEV_RESTORE_KILL_AFTER=1 \
RESTORE_GUEST_ROOT="${mount_guest}" \
RESTORE_SSH_STARTED_FILE="${mount_ssh_started}" \
  unshare --user --map-root-user --mount bash -c '
    set -euo pipefail
    mount --bind "${1}" "${2}"
    helper_status=0
    "${5}" "${3}" "${4}" "${6}" 100 0 0 \
      || helper_status=$?
    [[ "${helper_status}" == 1 && ! -e "${4}/tree" ]]
    exec "${7}" probe 2026-08-28/12-00-00
  ' _ "${mount_source}" "${mount_target}" "${snapshot}/tree" \
    "${mount_copy_parent}" "${copy_helper}" "${logical_bytes}" \
    "${repository}/bin/virtdev-restore" \
    >"${test_tmp}/mount.output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${mount_ssh_started}" ]] \
    || ! grep -Fq 'mounted filesystem' "${test_tmp}/mount.output" \
    || ! grep -Fq 'mount boundary' "${test_tmp}/mount.output" \
    || find "${mount_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore crossed a nested snapshot mount (status %d)\n' \
    "${status}" >&2
  exit 1
fi
sed -i '\|^mounted/$|d' "${snapshot}/manifest"

timeout_guest="${test_tmp}/timeout-guest"
timeout_pid_file="${test_tmp}/timeout.pid"
status=0
run_restore "${timeout_guest}" "${logical_bytes}" 100 2 \
  env RESTORE_SSH_DELAY=5 RESTORE_SSH_PID_FILE="${timeout_pid_file}" \
  >"${test_tmp}/timeout.output" 2>&1 || status=$?
if (( status != 20 )) || [[ ! -s "${timeout_pid_file}" ]] \
    || kill -0 "$(< "${timeout_pid_file}")" 2>/dev/null \
    || find "${timeout_guest}" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore deadline failed to contain transport (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/timeout.output" >&2
  exit 1
fi

copy_source="${test_tmp}/copy-source"
copy_parent="${test_tmp}/copy-parent"
mkdir -p "${copy_source}/mutable" "${copy_parent}"
printf 'seed\n' > "${copy_source}/mutable/seed"
"${copy_helper}" "${copy_source}" "${copy_parent}" 5 2 0 0 \
  > "${test_tmp}/copy-summary"
truncate -s 6 "${copy_source}/mutable/seed"
printf 'late\n' > "${copy_source}/mutable/late"
if [[ "$(< "${copy_parent}/tree/mutable/seed")" != seed \
      || -e "${copy_parent}/tree/mutable/late" ]]; then
  printf 'bounded copy did not produce an independent stable tree\n' >&2
  exit 1
fi

byte_source="${test_tmp}/byte-source"
byte_parent="${test_tmp}/byte-parent"
mkdir "${byte_source}" "${byte_parent}"
truncate -s 8192 "${byte_source}/large"
status=0
"${copy_helper}" "${byte_source}" "${byte_parent}" 4096 1 0 0 \
  > "${test_tmp}/byte-copy.output" 2>&1 || status=$?
if (( status != 44 )); then
  printf 'bounded copy exceeded its logical-byte ceiling (status %d)\n' \
    "${status}" >&2
  exit 1
fi

entry_source="${test_tmp}/entry-source"
entry_parent="${test_tmp}/entry-parent"
mkdir "${entry_source}" "${entry_parent}"
: > "${entry_source}/one"
: > "${entry_source}/two"
status=0
"${copy_helper}" "${entry_source}" "${entry_parent}" 1 1 0 0 \
  > "${test_tmp}/entry-copy.output" 2>&1 || status=$?
if (( status != 42 )) \
    || { [[ -d "${entry_parent}/tree" ]] \
         && (( $(find "${entry_parent}/tree" -mindepth 1 | wc -l) > 1 )); }; then
  printf 'bounded copy exceeded its entry ceiling (status %d)\n' \
    "${status}" >&2
  exit 1
fi

capacity_parent="${test_tmp}/capacity-parent"
mkdir "${capacity_parent}"
status=0
"${copy_helper}" "${copy_source}" "${capacity_parent}" 6 3 \
  18446744073709551615 0 \
  > "${test_tmp}/capacity-copy.output" 2>&1 || status=$?
if (( status != 45 )) || [[ -e "${capacity_parent}/tree" ]]; then
  printf 'bounded copy crossed its capacity reserve (status %d)\n' \
    "${status}" >&2
  exit 1
fi

shallow_source="${test_tmp}/shallow-source"
shallow_parent="${test_tmp}/shallow-parent"
mkdir "${shallow_source}" "${shallow_parent}"
cursor="${shallow_source}"
for _ in {1..4}; do
  cursor+='/d'
  mkdir "${cursor}"
done
printf x > "${cursor}/leaf"
status=0
(ulimit -n 64; "${copy_helper}" "${shallow_source}" "${shallow_parent}" \
  1 5 0 0) > "${test_tmp}/shallow-copy.output" 2>&1 || status=$?
if (( status != 0 )) \
    || [[ "$(< "${test_tmp}/shallow-copy.output")" != '5 1' \
          || "$(< "${shallow_parent}/tree/d/d/d/d/leaf")" != x ]]; then
  printf 'bounded copy rejected a shallow low-descriptor tree (status %d)\n' \
    "${status}" >&2
  exit 1
fi

deep_source="${test_tmp}/deep-source"
deep_parent="${test_tmp}/deep-parent"
mkdir "${deep_source}" "${deep_parent}"
cursor="${deep_source}"
for _ in {1..64}; do
  cursor+='/d'
  mkdir "${cursor}"
done
printf x > "${cursor}/leaf"
status=0
(ulimit -n 64; "${copy_helper}" "${deep_source}" "${deep_parent}" \
  1 65 0 0) > "${test_tmp}/deep-copy.output" 2>&1 || status=$?
if (( status != 46 )) || [[ -e "${deep_parent}/tree" ]] \
    || ! grep -Fq 'nesting-depth limit' "${test_tmp}/deep-copy.output" \
    || grep -Fq 'Too many open files' "${test_tmp}/deep-copy.output"; then
  printf 'bounded copy did not reject deep input explicitly (status %d)\n' \
    "${status}" >&2
  exit 1
fi

cap_source="${test_tmp}/cap-source"
cap_parent="${test_tmp}/cap-parent"
cap_over_parent="${test_tmp}/cap-over-parent"
mkdir "${cap_source}" "${cap_parent}" "${cap_over_parent}"
cursor="${cap_source}"
for _ in {1..127}; do
  cursor+='/d'
  mkdir "${cursor}"
done
printf x > "${cursor}/leaf"
hard_descriptor_limit="$(ulimit -Hn)"
if [[ "${hard_descriptor_limit}" == unlimited ]] \
    || (( hard_descriptor_limit >= 512 )); then
  (ulimit -Sn 512; "${copy_helper}" "${cap_source}" "${cap_parent}" \
    1 129 0 0) > "${test_tmp}/cap-copy.output"
  if [[ "$(< "${test_tmp}/cap-copy.output")" != '128 1' \
        || "$(< "${cap_parent}/tree${cursor#"${cap_source}"}/leaf")" != x ]]; then
    printf 'bounded copy rejected the supported depth boundary\n' >&2
    exit 1
  fi
  mkdir "${cursor}/d"
  printf x > "${cursor}/d/deep-leaf"
  status=0
  (ulimit -Sn 512; "${copy_helper}" "${cap_source}" "${cap_over_parent}" \
    2 131 0 0) > "${test_tmp}/cap-over-copy.output" 2>&1 || status=$?
  if (( status != 46 )) || [[ -e "${cap_over_parent}/tree" ]]; then
    printf 'bounded copy accepted a tree beyond depth 128 (status %d)\n' \
      "${status}" >&2
    exit 1
  fi
else
  printf 'skip - hard descriptor limit cannot exercise 128 components\n' >&2
fi

printf -v long_component '%255s' ''
long_component="${long_component// /x}"
path_source="${test_tmp}/path-source"
path_parent="${test_tmp}/path-parent"
path_over_source="${test_tmp}/path-over-source"
path_over_parent="${test_tmp}/path-over-parent"
mkdir "${path_source}" "${path_parent}" "${path_over_source}" \
  "${path_over_parent}"
(
  cd "${path_source}"
  for _ in {1..15}; do
    mkdir -- "${long_component}"
    cd -- "${long_component}"
  done
  printf x > "${long_component}"
)
"${copy_helper}" "${path_source}" "${path_parent}" 1 16 0 0 \
  > "${test_tmp}/path-copy.output"
if [[ "$(< "${test_tmp}/path-copy.output")" != '16 1' ]]; then
  printf 'bounded copy rejected a 4095-byte relative path\n' >&2
  exit 1
fi
(
  cd "${path_parent}/tree"
  for _ in {1..15}; do
    cd -- "${long_component}"
  done
  [[ "$(< "${long_component}")" == x ]]
) || {
  printf 'bounded copy damaged a 4095-byte relative path\n' >&2
  exit 1
}
(
  cd "${path_over_source}"
  for _ in {1..16}; do
    mkdir -- "${long_component}"
    cd -- "${long_component}"
  done
  printf x > x
)
status=0
"${copy_helper}" "${path_over_source}" "${path_over_parent}" 1 17 0 0 \
  > "${test_tmp}/path-over-copy.output" 2>&1 || status=$?
if (( status != 46 )) || [[ -e "${path_over_parent}/tree" ]] \
    || ! grep -Fq 'relative-path limit' "${test_tmp}/path-over-copy.output"; then
  printf 'bounded copy accepted a relative path beyond 4095 bytes (status %d)\n' \
    "${status}" >&2
  exit 1
fi

gate_library="${test_tmp}/copy-tree-gate.so"
cc -std=c99 -Wall -Wextra -Wpedantic -O2 -Werror -fPIC -shared \
  -o "${gate_library}" "${repository}/tests/support/copy-tree-gate.c"
mmap_helper="${test_tmp}/mmap-dirty"
cc -std=c99 -Wall -Wextra -Wpedantic -O2 -Werror \
  -o "${mmap_helper}" "${repository}/tests/support/mmap-dirty.c"
state_helper="${test_tmp}/copy-tree-state-limit"
cc -std=c99 -Wall -Wextra -Wpedantic -O2 -Werror \
  -DSOURCE_STATE_MAX_BYTES=4198400ULL \
  -DSOURCE_STATE_CHUNK_BYTES=4096ULL \
  -o "${state_helper}" "${repository}/source/virtdev/copy-tree.c"
state_source="${test_tmp}/state-source"
state_parent="${test_tmp}/state-parent"
mkdir "${state_source}" "${state_parent}"
for index in {1..100}; do
  : > "${state_source}/${index}"
done
status=0
"${state_helper}" "${state_source}" "${state_parent}" 0 100 0 0 \
  > "${test_tmp}/state-copy.output" 2>&1 || status=$?
if (( status != 48 )) || [[ -e "${state_parent}/tree" ]] \
    || ! grep -Fq 'source-state memory limit' \
      "${test_tmp}/state-copy.output"; then
  printf 'bounded copy did not enforce its retained-state limit (status %d)\n' \
    "${status}" >&2
  exit 1
fi

run_gated_copy() {
  local -r source="${1}" parent="${2}" output="${3}"
  local -r first="${4}" ready="${5}" release="${6}"
  LD_PRELOAD="${gate_library}" \
  COPY_TREE_GATE_FIRST="${first}" \
  COPY_TREE_GATE_READY="${ready}" \
  COPY_TREE_GATE_RELEASE="${release}" \
  COPY_TREE_GATE_SKIP=2 \
    "${copy_helper}" "${source}" "${parent}" 16 2 0 0 \
      > "${output}" 2>&1
}

epoch_source="${test_tmp}/epoch-source"
epoch_parent="${test_tmp}/epoch-parent"
epoch_first="${test_tmp}/epoch-first"
epoch_ready="${test_tmp}/epoch-ready"
epoch_release="${test_tmp}/epoch-release"
mkdir "${epoch_source}" "${epoch_parent}"
printf 'epoch-A\n' > "${epoch_source}/one"
printf 'epoch-A\n' > "${epoch_source}/two"
gate_release="${epoch_release}"
run_gated_copy "${epoch_source}" "${epoch_parent}" \
  "${test_tmp}/epoch-copy.output" "${epoch_first}" "${epoch_ready}" \
  "${epoch_release}" &
gate_pid=$!
for _ in {1..1000}; do
  [[ -e "${epoch_ready}" ]] && break
  kill -0 "${gate_pid}" 2>/dev/null || break
  sleep 0.01
done
if [[ ! -e "${epoch_ready}" || ! -s "${epoch_first}" ]]; then
  printf 'copy mutation gate did not reach its hold point\n' >&2
  exit 1
fi
first_name="$(< "${epoch_first}")"
case "${first_name}" in
  one) second_name=two ;;
  two) second_name=one ;;
  *) printf 'copy mutation gate recorded an unexpected path: %s\n' \
       "${first_name}" >&2; exit 1 ;;
esac
printf 'epoch-B\n' > "${epoch_source}/${first_name}"
printf 'epoch-B\n' > "${epoch_source}/${second_name}"
: > "${epoch_release}"
status=0
wait "${gate_pid}" || status=$?
gate_pid=''
gate_release=''
if (( status != 47 )) || ! grep -Fq 'source changed' \
    "${test_tmp}/epoch-copy.output"; then
  printf 'bounded copy accepted a cross-epoch tree (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/epoch-copy.output" >&2
  exit 1
fi

delete_source="${test_tmp}/delete-source"
delete_parent="${test_tmp}/delete-parent"
delete_first="${test_tmp}/delete-first"
delete_ready="${test_tmp}/delete-ready"
delete_release="${test_tmp}/delete-release"
mkdir "${delete_source}" "${delete_parent}"
printf 'epoch-A\n' > "${delete_source}/one"
printf 'epoch-A\n' > "${delete_source}/two"
gate_release="${delete_release}"
run_gated_copy "${delete_source}" "${delete_parent}" \
  "${test_tmp}/delete-copy.output" "${delete_first}" "${delete_ready}" \
  "${delete_release}" &
gate_pid=$!
for _ in {1..1000}; do
  [[ -e "${delete_ready}" ]] && break
  kill -0 "${gate_pid}" 2>/dev/null || break
  sleep 0.01
done
if [[ ! -e "${delete_ready}" || ! -s "${delete_first}" ]]; then
  printf 'copy deletion gate did not reach its hold point\n' >&2
  exit 1
fi
case "$(< "${delete_first}")" in
  one) second_name=two ;;
  two) second_name=one ;;
  *) printf 'copy deletion gate recorded an unexpected path\n' >&2; exit 1 ;;
esac
rm -- "${delete_source}/${second_name}"
: > "${delete_release}"
status=0
wait "${gate_pid}" || status=$?
gate_pid=''
gate_release=''
if (( status != 47 )) \
    || ! grep -Fq 'source changed before copy' \
      "${test_tmp}/delete-copy.output"; then
  printf 'bounded copy misclassified a deleted captured path (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/delete-copy.output" >&2
  exit 1
fi

mmap_source="${test_tmp}/mmap-source"
mmap_parent="${test_tmp}/mmap-parent"
mmap_mapped="${test_tmp}/mmap-mapped"
mmap_trigger="${test_tmp}/mmap-trigger"
mmap_mutated="${test_tmp}/mmap-mutated"
mmap_release="${test_tmp}/mmap-release"
mmap_first="${test_tmp}/mmap-first"
mmap_ready="${test_tmp}/mmap-ready"
mmap_gate_release="${test_tmp}/mmap-gate-release"
mkdir "${mmap_source}" "${mmap_parent}"
printf 'epoch-A\n' > "${mmap_source}/one"
printf 'epoch-A\n' > "${mmap_source}/two"
"${mmap_helper}" "${mmap_source}/one" "${mmap_source}/two" \
  "${mmap_mapped}" "${mmap_trigger}" "${mmap_mutated}" "${mmap_release}" \
  $'epoch-B\n' > "${test_tmp}/mmap-helper.output" 2>&1 &
mmap_pid=$!
for _ in {1..1000}; do
  [[ -e "${mmap_mapped}" ]] && break
  kill -0 "${mmap_pid}" 2>/dev/null || break
  sleep 0.01
done
if [[ ! -e "${mmap_mapped}" ]]; then
  printf 'mmap mutation fixture did not establish its mappings\n' >&2
  cat "${test_tmp}/mmap-helper.output" >&2
  exit 1
fi
mmap_metadata_before="$(stat -c '%y|%z' \
  "${mmap_source}/one" "${mmap_source}/two")"
gate_release="${mmap_gate_release}"
run_gated_copy "${mmap_source}" "${mmap_parent}" \
  "${test_tmp}/mmap-copy.output" "${mmap_first}" "${mmap_ready}" \
  "${mmap_gate_release}" &
gate_pid=$!
for _ in {1..1000}; do
  [[ -e "${mmap_ready}" ]] && break
  kill -0 "${gate_pid}" 2>/dev/null || break
  sleep 0.01
done
if [[ ! -e "${mmap_ready}" || ! -s "${mmap_first}" ]]; then
  printf 'mmap copy gate did not reach its hold point\n' >&2
  exit 1
fi
: > "${mmap_trigger}"
for _ in {1..1000}; do
  [[ -e "${mmap_mutated}" ]] && break
  kill -0 "${mmap_pid}" 2>/dev/null || break
  sleep 0.01
done
if [[ ! -e "${mmap_mutated}" ]]; then
  printf 'mmap mutation fixture did not publish its update\n' >&2
  exit 1
fi
mmap_metadata_after="$(stat -c '%y|%z' \
  "${mmap_source}/one" "${mmap_source}/two")"
if [[ "${mmap_metadata_after}" != "${mmap_metadata_before}" ]]; then
  printf 'mmap fixture changed metadata and did not exercise content validation\n' >&2
  exit 1
fi
: > "${mmap_gate_release}"
status=0
wait "${gate_pid}" || status=$?
gate_pid=''
gate_release=''
: > "${mmap_release}"
wait "${mmap_pid}"
mmap_pid=''
mmap_trigger=''
mmap_release=''
if (( status != 47 )) \
    || ! grep -Fq 'copied data differs from captured source' \
      "${test_tmp}/mmap-copy.output"; then
  printf 'bounded copy accepted metadata-invisible source edits (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/mmap-copy.output" >&2
  exit 1
fi

rm -rf --one-file-system -- "${snapshot}/tree"
mkdir "${snapshot}/tree"
printf 'epoch-A\n' > "${snapshot}/tree/one"
printf 'epoch-A\n' > "${snapshot}/tree/two"
printf '%s\n' one two > "${snapshot}/manifest"
restore_first="${test_tmp}/restore-first"
restore_ready="${test_tmp}/restore-ready"
restore_release="${test_tmp}/restore-release"
restore_ssh_started="${test_tmp}/restore-mutation-ssh-started"
mutation_guest="${test_tmp}/mutation-guest"
gate_release="${restore_release}"
run_restore "${mutation_guest}" 16 2 10 env \
  LD_PRELOAD="${gate_library}" \
  COPY_TREE_GATE_FIRST="${restore_first}" \
  COPY_TREE_GATE_READY="${restore_ready}" \
  COPY_TREE_GATE_RELEASE="${restore_release}" \
  COPY_TREE_GATE_SKIP=2 \
  RESTORE_SSH_STARTED_FILE="${restore_ssh_started}" \
  > "${test_tmp}/restore-mutation.output" 2>&1 &
gate_pid=$!
for _ in {1..1000}; do
  [[ -e "${restore_ready}" ]] && break
  kill -0 "${gate_pid}" 2>/dev/null || break
  sleep 0.01
done
if [[ ! -e "${restore_ready}" || ! -s "${restore_first}" ]]; then
  printf 'restore mutation gate did not reach its hold point\n' >&2
  exit 1
fi
first_name="$(< "${restore_first}")"
case "${first_name}" in
  one) second_name=two ;;
  two) second_name=one ;;
  *) printf 'restore mutation gate recorded an unexpected path: %s\n' \
       "${first_name}" >&2; exit 1 ;;
esac
printf 'epoch-B\n' > "${snapshot}/tree/${first_name}"
printf 'epoch-B\n' > "${snapshot}/tree/${second_name}"
: > "${restore_release}"
status=0
wait "${gate_pid}" || status=$?
gate_pid=''
gate_release=''
if (( status != 19 )) || [[ -e "${restore_ssh_started}" ]] \
    || find "${mutation_guest}" -mindepth 1 -print -quit | grep -q . \
    || ! grep -Fq 'Snapshot changed while constructing its stable stage' \
      "${test_tmp}/restore-mutation.output"; then
  printf 'restore accepted a cross-epoch stage (status %d)\n' "${status}" >&2
  cat "${test_tmp}/restore-mutation.output" >&2
  exit 1
fi

rm -rf --one-file-system -- "${snapshot}/tree"
mkdir "${snapshot}/tree"
cursor="${snapshot}/tree"
for _ in {1..64}; do
  cursor+='/d'
  mkdir "${cursor}"
done
printf x > "${cursor}/leaf"
printf 'd/\n' > "${snapshot}/manifest"
depth_guest="${test_tmp}/depth-guest"
depth_ssh_started="${test_tmp}/depth-ssh-started"
status=0
(ulimit -n 64; run_restore "${depth_guest}" 1 65 10 \
  env RESTORE_SSH_STARTED_FILE="${depth_ssh_started}") \
  > "${test_tmp}/depth-restore.output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${depth_ssh_started}" ]] \
    || find "${depth_guest}" -mindepth 1 -print -quit | grep -q . \
    || ! grep -Fq 'safe staging limit' "${test_tmp}/depth-restore.output"; then
  printf 'restore did not map deep staging refusal safely (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/depth-restore.output" >&2
  exit 1
fi

rm -rf --one-file-system -- "${snapshot}/tree"
mkdir "${snapshot}/tree"
printf x > "${snapshot}/tree/file"
printf 'file\n' > "${snapshot}/manifest"
state_bin="${test_tmp}/state-bin"
state_guest="${test_tmp}/state-guest"
state_ssh_started="${test_tmp}/state-ssh-started"
mkdir "${state_bin}"
cp "${repository}/tests/fixtures/timeout-copy-tree-status" \
  "${state_bin}/timeout"

manifest_timeout_guest="${test_tmp}/manifest-timeout-guest"
status=0
PATH="${state_bin}:${PATH}" run_restore \
  "${manifest_timeout_guest}" 1 1 10 env \
  RESTORE_TIMEOUT_COMMAND=head \
  > "${test_tmp}/manifest-timeout.output" 2>&1 || status=$?
if (( status != 20 )) \
    || ! grep -Fq 'manifest preflight exceeded' \
      "${test_tmp}/manifest-timeout.output"; then
  printf 'restore lost its manifest deadline (status %d)\n' "${status}" >&2
  cat "${test_tmp}/manifest-timeout.output" >&2
  exit 1
fi

bounded_summary_guest="${test_tmp}/bounded-summary-guest"
status=0
PATH="${state_bin}:${PATH}" run_restore "${bounded_summary_guest}" 1 1 10 env \
  RESTORE_DF_AVAILABLE=550000000 \
  > "${test_tmp}/bounded-summary.output" 2>&1 || status=$?
if (( status != 0 )) \
    || [[ "$(< "${bounded_summary_guest}/file")" != x ]]; then
  printf 'restore reserved summary state from the configured ceiling (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/bounded-summary.output" >&2
  exit 1
fi

unavailable_inode_guest="${test_tmp}/unavailable-inode-guest"
status=0
PATH="${state_bin}:${PATH}" run_restore \
  "${unavailable_inode_guest}" 1 1 10 env \
  RESTORE_DF_AVAILABLE=550000000 \
  RESTORE_DF_IAVAILABLE=- \
  > "${test_tmp}/unavailable-inode.output" 2>&1 || status=$?
if (( status != 0 )) \
    || [[ "$(< "${unavailable_inode_guest}/file")" != x ]]; then
  printf 'restore rejected an unavailable inode count (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/unavailable-inode.output" >&2
  exit 1
fi

df_timeout_guest="${test_tmp}/df-timeout-guest"
status=0
PATH="${state_bin}:${PATH}" run_restore "${df_timeout_guest}" 1 1 10 env \
  RESTORE_TIMEOUT_COMMAND=df \
  > "${test_tmp}/df-timeout.output" 2>&1 || status=$?
if (( status != 20 )) \
    || ! grep -Fq 'exceeded its wall-clock deadline' \
      "${test_tmp}/df-timeout.output"; then
  printf 'restore did not classify a df timeout as a deadline (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/df-timeout.output" >&2
  exit 1
fi

sort_timeout_guest="${test_tmp}/sort-timeout-guest"
status=0
PATH="${state_bin}:${PATH}" run_restore "${sort_timeout_guest}" 1 1 10 env \
  RESTORE_TIMEOUT_COMMAND=sort \
  > "${test_tmp}/sort-timeout.output" 2>&1 || status=$?
if (( status != 20 )) \
    || ! grep -Fq 'exceeded its wall-clock deadline' \
      "${test_tmp}/sort-timeout.output"; then
  printf 'restore did not classify a sort timeout as a deadline (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/sort-timeout.output" >&2
  exit 1
fi

status=0
PATH="${state_bin}:${PATH}" run_restore "${state_guest}" 1 1 10 env \
  RESTORE_COPY_TREE_STATUS=48 \
  RESTORE_SSH_STARTED_FILE="${state_ssh_started}" \
  > "${test_tmp}/state-restore.output" 2>&1 || status=$?
if (( status != 19 )) || [[ -e "${state_ssh_started}" ]] \
    || find "${state_guest}" -mindepth 1 -print -quit | grep -q . \
    || ! grep -Fq 'bounded staging-state budget' \
      "${test_tmp}/state-restore.output"; then
  printf 'restore did not map staging-state exhaustion safely (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/state-restore.output" >&2
  exit 1
fi

printf 'ok - restore uses a compatible manifest file and preserves inode fidelity\n'
printf 'ok - restore bounds regular logical bytes, entry count, and total time\n'
printf 'ok - restore stages and validates one independently bounded tree\n'
printf 'ok - stable staging rejects deep and cross-epoch source trees\n'
