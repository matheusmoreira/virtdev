#!/usr/bin/env bash

set -euo pipefail

repository_root="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d --tmpdir virtdev-test-runner.XXXXXXXXXX)"

cleanup() {
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

runner_directory="${test_tmp}/runner"
mkdir -- "${runner_directory}"
cp -- "${repository_root}/tests/run" "${runner_directory}/run"

cat > "${runner_directory}/test-00-drain.bash" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
: > "${RUNNER_FIRST_MARKER}"
EOF

cat > "${runner_directory}/test-01-tail.bash" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "${RUNNER_TAIL_MARKER}"
EOF

first_marker="${test_tmp}/first-ran"
tail_marker="${test_tmp}/tail-ran"
newline_marker="${test_tmp}/newline-ran"
newline_test="${runner_directory}/"$'test-02-line\nbreak.bash'
cat > "${newline_test}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "${RUNNER_NEWLINE_MARKER}"
EOF
sentinel="${test_tmp}/sentinel"
output="${test_tmp}/output"
printf 'preserved\n' > "${sentinel}"

exec {sentinel_fd}< "${sentinel}"
RUNNER_FIRST_MARKER="${first_marker}" \
RUNNER_TAIL_MARKER="${tail_marker}" \
RUNNER_NEWLINE_MARKER="${newline_marker}" \
  bash "${runner_directory}/run" <&"${sentinel_fd}" > "${output}"

remaining=''
IFS= read -r remaining <&"${sentinel_fd}" || true
exec {sentinel_fd}<&-

if [[ ! -e "${first_marker}" || ! -e "${tail_marker}" \
      || ! -e "${newline_marker}" ]] \
    || [[ "${remaining}" != preserved ]] \
    || ! grep -Fxq 'TEST test-00-drain.bash' "${output}" \
    || ! grep -Fxq 'TEST test-01-tail.bash' "${output}"; then
  printf 'test runner did not isolate its test list and caller input\n' >&2
  cat "${output}" >&2
  exit 1
fi

empty_directory="${test_tmp}/empty"
mkdir -- "${empty_directory}"
cp -- "${repository_root}/tests/run" "${empty_directory}/run"
empty_output="${test_tmp}/empty.output"
status=0
bash "${empty_directory}/run" > "${empty_output}" 2>&1 || status=$?
if (( status == 0 )) || ! grep -Fq 'No tests found under:' "${empty_output}"; then
  printf 'test runner accepted an empty suite (status %d)\n' "${status}" >&2
  cat "${empty_output}" >&2
  exit 1
fi

failure_bin="${test_tmp}/failure-bin"
mkdir -- "${failure_bin}"
for discovery_command in find sort; do
  cat > "${failure_bin}/${discovery_command}" <<'EOF'
#!/usr/bin/env bash
exit 73
EOF
  chmod 755 "${failure_bin}/${discovery_command}"
  failure_output="${test_tmp}/${discovery_command}-failure.output"
  status=0
  PATH="${failure_bin}:${PATH}" bash "${runner_directory}/run" \
    > "${failure_output}" 2>&1 || status=$?
  if (( status == 0 )) \
      || ! grep -Fq 'Could not discover tests under:' "${failure_output}"; then
    printf 'test runner ignored %s failure (status %d)\n' \
      "${discovery_command}" "${status}" >&2
    cat "${failure_output}" >&2
    exit 1
  fi
  rm -f -- "${failure_bin}/${discovery_command}"
done

printf 'ok - test runner isolates discovery and child stdin\n'
printf 'ok - test runner rejects empty or incomplete discovery\n'
