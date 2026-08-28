#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${repo_root}/lib/virtdev/import"
import validate runtime

repeat() {
  local -r count="${1}" character="${2}"
  local value
  printf -v value '%*s' "${count}" ''
  printf '%s' "${value// /${character}}"
}

long_root="/$(repeat 120 r)"
( export VIRTDEV_HOME="${long_root}"; validate_project_name probe )
validate_project_name "$(repeat 64 p)"
if ( validate_project_name "$(repeat 65 p)" ) >/dev/null 2>&1; then
  printf '65-byte project name was accepted\n' >&2
  exit 1
fi

for name in none wan lan full; do
  if validate_project_name_reserved "${name}" >/dev/null; then
    printf 'network zone remained reserved as a project name: %s\n' "${name}" >&2
    exit 1
  fi
done
for name in maintenance base firewall; do
  validate_project_name_reserved "${name}" >/dev/null
done

socket_name=monitor.sock
# shellcheck disable=SC2154  # imported readonly runtime constant
exact_dir="/$(repeat $((runtime_socket_path_max - ${#socket_name} - 2)) d)"
overlong_dir="${exact_dir}x"
runtime_socket_paths_fit "${exact_dir}"
if runtime_socket_paths_fit "${overlong_dir}"; then
  printf 'overlong runtime socket directory was accepted\n' >&2
  exit 1
fi

if grep -Eq 'import .*firewall|firewall_zone_known' "${repo_root}/lib/virtdev/validate"; then
  printf 'project validation still depends on firewall vocabulary\n' >&2
  exit 1
fi

printf 'ok - project identity is stable and socket feasibility is operation-specific\n'
