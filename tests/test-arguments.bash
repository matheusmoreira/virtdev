#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import arguments

parse_color() {
  # shellcheck disable=SC2034  # consumed through namerefs by arguments_parse
  declare -A color_spec=()
  # shellcheck disable=SC2034
  declare -A color_flags=()
  declare -a color_positional=()
  _virtdev_color_mode=''
  arguments_parse color_spec color_flags color_positional "$@"
  printf '%s|' "${_virtdev_color_mode:-auto}"
  if (( ${#color_positional[@]} )); then
    printf '<%s>' "${color_positional[@]}"
  fi
  printf '\n'
}

for value in yes no auto; do
  if [[ "$(parse_color "--color=${value}" project)" != "${value}|<project>" ]]; then
    printf 'equals-form color parse failed for %s\n' "${value}" >&2
    exit 1
  fi
  if [[ "$(parse_color --color "${value}" project)" != "${value}|<project>" ]]; then
    printf 'space-form color parse failed for %s\n' "${value}" >&2
    exit 1
  fi
done

if [[ "$(parse_color --color)" != 'yes|' ]]; then
  printf 'bare --color did not mean yes\n' >&2
  exit 1
fi
if [[ "$(parse_color --color -- project)" != 'yes|<project>' ]]; then
  printf 'bare --color terminator did not preserve its positional\n' >&2
  exit 1
fi

for invocation in '--color=bogus' '--color=' '--color bogus'; do
  status=0
  # Word splitting is intentional: these fixtures contain no shell metacharacters.
  # shellcheck disable=SC2086
  ( parse_color ${invocation} ) >"${test_tmp}/output" 2>&1 || status=$?
  if (( status != 64 )); then
    printf 'invalid color invocation did not exit 64: %s (status %d)\n' \
      "${invocation}" "${status}" >&2
    exit 1
  fi
done

printf 'ok - universal color forms share one strict enum parser\n'
