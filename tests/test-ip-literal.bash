#!/usr/bin/env bash

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

# shellcheck disable=SC1091
source "${repository}/lib/virtdev/ip"

host_definition="$(sed -n '/^ip_literal_is_valid()/,/^}/p' \
  "${repository}/lib/virtdev/ip")"
guest_definition="$(sed -n '/^ip_literal_is_valid()/,/^}/p' \
  "${repository}/iso/airootfs/root/virtdev/install.sh")"
if [[ "${host_definition}" != "${guest_definition}" ]]; then
  printf 'host and installer IP parsers differ\n' >&2
  exit 1
fi

valid=(
  0.0.0.0
  9.9.9.9
  255.255.255.255
  ::
  ::1
  2001:4860:4860::8888
  ::ffff:192.0.2.1
)
invalid=(
  ''
  1.2.3
  01.2.3.4
  256.1.1.1
  999.999.999.999
  2001:::1
  2001:db8::1/64
  fe80::1%eth0
  resolver.example
  ١.٢.٣.٤
  １.２.３.４
  $'9.9.9.9\nDNS=1.1.1.1'
)

for address in "${valid[@]}"; do
  if ! ip_literal_is_valid "${address}"; then
    printf 'valid IP literal rejected: %q\n' "${address}" >&2
    exit 1
  fi
done
for address in "${invalid[@]}"; do
  if ip_literal_is_valid "${address}"; then
    printf 'invalid IP literal accepted: %q\n' "${address}" >&2
    exit 1
  fi
done

utf8_locale="$(locale -a | awk \
  'tolower($0) ~ /^en_us\.utf-?8$/ { print; exit }')"
utf8_available=0
if [[ -n "${utf8_locale}" ]]; then
  locale_diagnostic="$(LC_ALL="${utf8_locale}" bash -c : 2>&1 || true)"
  [[ -n "${locale_diagnostic}" ]] || utf8_available=1
fi
if (( utf8_available )); then
  unicode_diagnostic="${test_tmp}/unicode-diagnostic"
  status=0
  LC_ALL="${utf8_locale}" ip_literal_is_valid ١.٢.٣.٤ \
    2>"${unicode_diagnostic}" || status=$?
  if (( status == 0 )) || [[ -s "${unicode_diagnostic}" ]]; then
    printf 'non-ASCII digits were not rejected quietly under UTF-8\n' >&2
    cat "${unicode_diagnostic}" >&2
    exit 1
  fi
elif [[ "${host_definition}" != *$'\n  local LC_ALL=C\n'* ]]; then
  printf 'IP parser does not pin ASCII matching on minimal locale sets\n' >&2
  exit 1
fi

output="${test_tmp}/output"
status=0
VIRTDEV_HOME="${test_tmp}/invalid-home" \
NO_COLOR=1 \
  "${repository}/bin/virtdev-install" \
    --dns 999.1.1.1 >"${output}" 2>&1 || status=$?
if (( status != 15 )) \
    || [[ -e "${test_tmp}/invalid-home" ]] \
    || ! grep -Fq 'Invalid DNS address' "${output}"; then
  printf 'installer did not reject invalid explicit DNS before mutation\n' >&2
  cat "${output}" >&2
  exit 1
fi

status=0
NO_COLOR=1 \
  "${repository}/bin/virtdev-install" \
    --dns '' >"${output}" 2>&1 || status=$?
if (( status != 15 )); then
  printf 'installer accepted an explicitly empty DNS value\n' >&2
  cat "${output}" >&2
  exit 1
fi

status=0
VIRTDEV_INSTALL_DNS=999.1.1.1 \
NO_COLOR=1 \
  "${repository}/bin/virtdev-install" >"${output}" 2>&1 || status=$?
if (( status != 15 )); then
  printf 'installer accepted an invalid VIRTDEV_INSTALL_DNS value\n' >&2
  exit 1
fi

status=0
VIRTDEV_DNS=999.1.1.1 \
NO_COLOR=1 \
  "${repository}/bin/virtdev-install" >"${output}" 2>&1 || status=$?
if (( status != 15 )); then
  printf 'installer compatibility DNS alias is not validated\n' >&2
  exit 1
fi

status=0
VIRTDEV_PACKAGES="${test_tmp}/missing-packages" \
NO_COLOR=1 \
  "${repository}/bin/virtdev-install" \
    --dns 2001:4860:4860::8888 >"${output}" 2>&1 || status=$?
if (( status != 11 )); then
  printf 'installer rejected a valid explicit IPv6 DNS value\n' >&2
  cat "${output}" >&2
  exit 1
fi

if ! grep -Fq "if ! ip_literal_is_valid \"\${dns}\"; then" \
    "${repository}/iso/airootfs/root/virtdev/install.sh"; then
  printf 'guest installer does not validate the fw_cfg DNS value\n' >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/passt"
declare -a passt_argv=()
VIRTDEV_DNS=192.0.2.53 passt_command passt_argv "${test_tmp}/network.sock"
if [[ " ${passt_argv[*]} " == *' --dns '* \
      || " ${passt_argv[*]} " == *' 192.0.2.53 '* ]]; then
  printf 'install-time DNS leaked into the runtime backend argv\n' >&2
  exit 1
fi

printf 'ok - host and guest accept only IPv4 or IPv6 literals\n'
printf 'ok - installer DNS is validated and absent from runtime backend policy\n'
