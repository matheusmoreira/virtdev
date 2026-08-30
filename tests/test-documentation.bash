#!/usr/bin/env bash
# shellcheck disable=SC2016  # documentation assertions are literal Markdown

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"

actual_libraries="$(
  find "${repository}/lib/virtdev" -maxdepth 1 -type f -printf '%f\n' \
    | LC_ALL=C sort
)"
documented_libraries="$(
  awk '
    /^### Current libraries$/ { in_table = 1; next }
    in_table && /^Libraries are self-contained:/ { exit }
    in_table && /^\| `/ { print }
  ' "${repository}/DESIGN.md" \
    | sed -n 's/^| `\([^`]*\)` |.*/\1/p' \
    | LC_ALL=C sort
)"
if [[ "${documented_libraries}" != "${actual_libraries}" ]]; then
  printf 'DESIGN.md library inventory does not match lib/virtdev\n' >&2
  printf 'documented:\n%s\nactual:\n%s\n' \
    "${documented_libraries}" "${actual_libraries}" >&2
  exit 1
fi

layout_section() {
  awk '
    /^## Data [Ll]ayout$/ { in_layout = 1 }
    in_layout && /^## / && $0 !~ /^## Data [Ll]ayout$/ { exit }
    in_layout { print }
  ' "${1}"
}

for document in README.md DESIGN.md; do
  layout="$(layout_section "${repository}/${document}")"
  layout_flat="${layout//$'\n'/ }"
  for artifact in move.transaction move.transaction.tmp. transactions/ \
    'recreate.<project>.<random>/' 'upgrade.<random>/' 'maintain.<random>/' \
    .detach.transaction .detach.transaction.tmp system.qcow2.bak \
    home.qcow2.bak system.qcow2.detach home.qcow2.detach \
    generation.detach.tmp; do
    if [[ "${layout}" != *"${artifact}"* ]]; then
      printf '%s Data Layout does not document %s\n' \
        "${document}" "${artifact}" >&2
      exit 1
    fi
  done
  if [[ "${layout_flat}" != *'bare `.bak` file has no recovery authority'* ]]; then
    printf '%s Data Layout does not deny recovery authority to bare .bak files\n' \
      "${document}" >&2
    exit 1
  fi
done

color_contract="$(sed -n '/All commands support `--color=/,/^$/p' \
  "${repository}/README.md")"
for contract in 'stream receiving styled output' '`virtdev-list`' \
  '`virtdev-disk`' 'probe stdout'; do
  if [[ "${color_contract}" != *"${contract}"* ]]; then
    printf 'README.md auto-color contract does not mention %s\n' \
      "${contract}" >&2
    exit 1
  fi
done
if [[ "${color_contract}" == *'when stderr is a terminal'* ]]; then
  printf 'README.md still describes auto-color as universally stderr-based\n' >&2
  exit 1
fi

printf 'ok - library, recovery-layout, and auto-color documentation is complete\n'
