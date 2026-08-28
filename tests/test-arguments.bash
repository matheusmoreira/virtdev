#!/usr/bin/env bash
# shellcheck disable=SC2034  # parser fixtures are consumed through namerefs

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
  declare -a color_spec_positionals=("args*")
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

parse_cardinality() {
  declare -A cardinality_spec=()
  declare -a cardinality_spec_positionals=(project "port?")
  declare -A cardinality_flags=()
  declare -a cardinality_positional=()
  arguments_parse cardinality_spec cardinality_flags cardinality_positional "$@"
  printf '%s\n' "${#cardinality_positional[@]}"
}

[[ "$(parse_cardinality project)" == 1 ]]
[[ "$(parse_cardinality project 2222)" == 2 ]]
for invocation in '' 'project 2222 extra'; do
  status=0
  # Word splitting is intentional for these plain cardinality fixtures.
  # shellcheck disable=SC2086
  ( parse_cardinality ${invocation} ) >"${test_tmp}/output" 2>&1 || status=$?
  if (( status != 64 )); then
    printf 'positional cardinality accepted invalid argv: %s\n' "${invocation}" >&2
    exit 1
  fi
done

parse_variadic() {
  declare -A variadic_spec=()
  declare -a variadic_spec_positionals=("command+")
  declare -A variadic_flags=()
  declare -a variadic_positional=()
  arguments_parse variadic_spec variadic_flags variadic_positional "$@"
  printf '%s\n' "${#variadic_positional[@]}"
}
[[ "$(parse_variadic one two three)" == 3 ]]
status=0
( parse_variadic ) >"${test_tmp}/output" 2>&1 || status=$?
(( status == 64 )) || exit 1

parse_bad_schema() {
  declare -A bad_spec=()
  declare -a bad_spec_positionals=("optional?" required)
  declare -A bad_flags=()
  declare -a bad_positional=()
  arguments_parse bad_spec bad_flags bad_positional "$@"
}
status=0
( parse_bad_schema value ) >"${test_tmp}/output" 2>&1 || status=$?
if (( status != 64 )) || ! grep -Fq 'required positional follows' "${test_tmp}/output"; then
  printf 'invalid positional schema was accepted\n' >&2
  exit 1
fi

printf 'ok - universal color forms share one strict enum parser\n'
printf 'ok - positional schemas enforce cardinality and ordering\n'
