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
sentinel="${test_tmp}/sentinel"
output="${test_tmp}/output"
printf 'preserved\n' > "${sentinel}"

exec {sentinel_fd}< "${sentinel}"
RUNNER_FIRST_MARKER="${first_marker}" \
RUNNER_TAIL_MARKER="${tail_marker}" \
  bash "${runner_directory}/run" <&"${sentinel_fd}" > "${output}"

remaining=''
IFS= read -r remaining <&"${sentinel_fd}" || true
exec {sentinel_fd}<&-

if [[ ! -e "${first_marker}" || ! -e "${tail_marker}" ]] \
    || [[ "${remaining}" != preserved ]] \
    || ! grep -Fxq 'TEST test-00-drain.bash' "${output}" \
    || ! grep -Fxq 'TEST test-01-tail.bash' "${output}"; then
  printf 'test runner did not isolate its test list and caller input\n' >&2
  cat "${output}" >&2
  exit 1
fi

printf 'ok - test runner isolates discovery and child stdin\n'
