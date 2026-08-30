#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

fixture_bin="${test_tmp}/bin"
virtdev_home="${test_tmp}/virtdev"
system_directory="${virtdev_home}/system"
external="${test_tmp}/external"
output="${test_tmp}/output"
mkdir -p -- "${fixture_bin}" "${external}"

cat > "${fixture_bin}/qemu-img" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "${CREATE_QEMU_COUNT:?}" ]] || count="$(< "${CREATE_QEMU_COUNT}")"
count=$(( count + 1 ))
printf '%s\n' "${count}" > "${CREATE_QEMU_COUNT}"
if [[ "${CREATE_MUTATE_ON_CALL:-}" == "${count}" ]]; then
  rm -f -- "${CREATE_MUTATE_TARGET:?}"
  ln -s -- "${CREATE_MUTATE_SOURCE:?}" "${CREATE_MUTATE_TARGET}"
fi
FIXTURE

cat > "${fixture_bin}/mkdir" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/mkdir "$@"
if [[ "${!#}" == "${CREATE_MUTATE_ON_MKDIR:-}" ]]; then
  rm -f -- "${CREATE_MUTATE_TARGET:?}"
  ln -s -- "${CREATE_MUTATE_SOURCE:?}" "${CREATE_MUTATE_TARGET}"
fi
FIXTURE
chmod 0755 -- "${fixture_bin}/qemu-img" "${fixture_bin}/mkdir"

reset_base() {
  rm -rf -- "${system_directory}"
  mkdir -p -- "${system_directory}"
  printf 'system\n' > "${system_directory}/system.qcow2"
  printf 'home\n' > "${system_directory}/home.qcow2"
  printf 'nvram\n' > "${system_directory}/nvram"
  printf '1\n' > "${system_directory}/generation"
  printf 'ssh-host-identity=1\n' > "${system_directory}/guest-contract"
  rm -f -- "${test_tmp}/qemu-count"
}

run_create() {
  local -r project="${1}"
  status=0
  PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
  HOME="${test_tmp}" \
  NO_COLOR=1 \
  VIRTDEV_HOME="${virtdev_home}" \
  VIRTDEV_LOCK_DIRECTORY="${test_tmp}/locks" \
  CREATE_QEMU_COUNT="${test_tmp}/qemu-count" \
  CREATE_MUTATE_ON_CALL="${mutate_call:-}" \
  CREATE_MUTATE_ON_MKDIR="${mutate_mkdir:-}" \
  CREATE_MUTATE_TARGET="${mutate_target:-}" \
  CREATE_MUTATE_SOURCE="${mutate_source:-}" \
    "${repository}/bin/virtdev-create" "${project}" > "${output}" 2>&1 \
    || status=$?
}

expect_rejected() {
  local -r expected="${1}" project="${2}"
  run_create "${project}"
  if (( status != expected )) \
      || [[ -e "${virtdev_home}/projects/${project}" ]]; then
    printf 'create accepted unsafe sealed base for %s (status %d)\n' \
      "${project}" "${status}" >&2
    cat -- "${output}" >&2
    exit 1
  fi
}

reset_base
mv -- "${system_directory}" "${external}/base"
ln -s -- "${external}/base" "${system_directory}"
expect_rejected 4 base-directory-symlink
rm -f -- "${system_directory}"
mv -- "${external}/base" "${system_directory}"

for input in system.qcow2 home.qcow2 nvram; do
  reset_base
  mv -- "${system_directory}/${input}" "${external}/${input}"
  ln -s -- "${external}/${input}" "${system_directory}/${input}"
  expect_rejected 5 "${input%.qcow2}-symlink"
done

reset_base
mv -- "${system_directory}/generation" "${external}/generation"
ln -s -- "${external}/generation" "${system_directory}/generation"
expect_rejected 7 generation-symlink

reset_base
mv -- "${system_directory}/guest-contract" "${external}/guest-contract"
ln -s -- "${external}/guest-contract" "${system_directory}/guest-contract"
expect_rejected 8 contract-symlink

reset_base
mutate_mkdir="${virtdev_home}/projects/system-race"
mutate_target="${system_directory}/system.qcow2"
mutate_source="${external}/system.qcow2"
printf 'replacement\n' > "${mutate_source}"
expect_rejected 5 system-race
unset mutate_mkdir mutate_target mutate_source

reset_base
mutate_call=1
mutate_target="${system_directory}/home.qcow2"
mutate_source="${external}/home.qcow2"
printf 'replacement\n' > "${mutate_source}"
expect_rejected 5 home-race
unset mutate_call mutate_target mutate_source

reset_base
mutate_call=2
mutate_target="${system_directory}/nvram"
mutate_source="${external}/nvram"
printf 'replacement\n' > "${mutate_source}"
expect_rejected 5 nvram-race
unset mutate_call mutate_target mutate_source

reset_base
mutate_call=2
mutate_target="${system_directory}/guest-contract"
mutate_source="${external}/guest-contract"
printf 'ssh-host-identity=1\n' > "${mutate_source}"
expect_rejected 8 contract-race

printf 'ok - create rejects symlinked sealed-base inputs\n'
printf 'ok - create revalidates sealed-base inputs immediately before use\n'
