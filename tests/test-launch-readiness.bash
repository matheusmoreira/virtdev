#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

# Construct the smallest PATH needed to parse and reject the request. The host
# has socat installed, so inheriting its PATH would not exercise the mandatory
# dependency boundary. A systemd-run marker makes an accidental fall-through
# observable rather than merely ending in "command not found" later.
fixture_bin="${test_tmp}/bin"
mkdir "${fixture_bin}"
for command_name in bash cat dirname readlink; do
  ln -s "$(command -v "${command_name}")" "${fixture_bin}/${command_name}"
done
# shellcheck disable=SC2016  # expanded by the generated fixture at execution
printf '#!/usr/bin/env bash\n: > "${SYSTEMD_RUN_MARKER:?}"\n' \
  > "${fixture_bin}/systemd-run"
chmod +x "${fixture_bin}/systemd-run"

virtdev_home="${test_tmp}/virtdev"
marker="${test_tmp}/systemd-run.called"
output="${test_tmp}/output"

status=0
PATH="${fixture_bin}" \
  HOME="${test_tmp}" \
  VIRTDEV_HOME="${virtdev_home}" \
  SYSTEMD_RUN_MARKER="${marker}" \
  NO_COLOR=1 \
  "${repository}/bin/virtdev-start" --unfiltered probe \
    >"${output}" 2>&1 || status=$?

if (( status != 23 )); then
  printf 'expected missing-socat exit 23, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ -e "${marker}" ]]; then
  printf 'start submitted a unit without its authoritative QMP client\n' >&2
  exit 1
fi
if [[ -e "${virtdev_home}/projects/probe/port" ]]; then
  printf 'start published a running signal without QMP readiness\n' >&2
  exit 1
fi
if ! grep -Fq 'socat is required for authoritative QMP launch confirmation.' \
    "${output}"; then
  printf 'missing-socat diagnostic did not explain the readiness invariant\n' >&2
  cat "${output}" >&2
  exit 1
fi

maintain_home="${test_tmp}/maintain-home"
maintain_marker="${test_tmp}/maintenance-systemd-run.called"
status=0
PATH="${fixture_bin}" \
  HOME="${test_tmp}" \
  VIRTDEV_HOME="${maintain_home}" \
  SYSTEMD_RUN_MARKER="${maintain_marker}" \
  NO_COLOR=1 \
  "${repository}/bin/virtdev-maintain" \
    --unfiltered --no-provision --no-inventory \
    >"${output}" 2>&1 || status=$?

if (( status != 32 )); then
  printf 'expected maintenance missing-socat exit 32, got %d\n' "${status}" >&2
  cat "${output}" >&2
  exit 1
fi
if [[ -e "${maintain_marker}" || -e "${maintain_home}/maintenance" ]]; then
  printf 'maintenance mutated state without its QMP shutdown client\n' >&2
  exit 1
fi

printf 'ok - start refuses before submission when QMP readiness cannot be probed\n'
printf 'ok - maintenance refuses before staging when shutdown proof is unavailable\n'
