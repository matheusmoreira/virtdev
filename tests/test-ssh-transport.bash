#!/usr/bin/env bash
# shellcheck disable=SC2034  # expected arrays are consumed through namerefs

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT

export VIRTDEV_HOME="${test_tmp}/store with spaces"
export VIRTDEV_SSH_KEY="${test_tmp}/client key"
mkdir -p "${VIRTDEV_HOME}/projects/alpha" \
  "${VIRTDEV_HOME}/projects/beta"
printf 'ssh-host-identity=1\n' > "${VIRTDEV_HOME}/projects/alpha/guest-contract"
printf 'ssh-host-identity=1\n' > "${VIRTDEV_HOME}/projects/beta/guest-contract"
/usr/bin/ssh-keygen -q -t ed25519 -N '' -C '' -f "${VIRTDEV_SSH_KEY}"

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import ssh
ssh_host_identity_ensure alpha
ssh_host_identity_ensure beta

assert_argv() {
  local -n actual_ref="${1}" expected_ref="${2}"
  local index
  if (( ${#actual_ref[@]} != ${#expected_ref[@]} )); then
    printf 'argv length mismatch: expected %d, got %d\n' \
      "${#expected_ref[@]}" "${#actual_ref[@]}" >&2
    return 1
  fi
  for (( index = 0; index < ${#expected_ref[@]}; index++ )); do
    if [[ "${actual_ref[index]}" != "${expected_ref[index]}" ]]; then
      printf 'argv[%d] mismatch: expected %q, got %q\n' \
        "${index}" "${expected_ref[index]}" "${actual_ref[index]}" >&2
      return 1
    fi
  done
}

alpha_known="$(ssh_host_identity_known_hosts alpha)"
alpha_alias="$(ssh_host_identity_alias alpha)"
declare -a expected_base=(
  ssh -F /dev/null -i "${VIRTDEV_SSH_KEY}" -p 2222
  -o HostName=127.0.0.1
  -o AddressFamily=inet
  -o CanonicalizeHostname=no
  -o ProxyCommand=none
  -o ProxyJump=none
  -o IdentitiesOnly=yes
  -o ForwardAgent=no
  -o GSSAPIDelegateCredentials=no
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="${alpha_known}"
  -o GlobalKnownHostsFile=/dev/null
  -o HostKeyAlias="${alpha_alias}"
  -o CheckHostIP=no
  -o NoHostAuthenticationForLocalhost=no
  -o HostKeyAlgorithms=ssh-ed25519
  -o UpdateHostKeys=no
  -o KnownHostsCommand=none
  -o VerifyHostKeyDNS=no
  -o ControlMaster=no
  -o ControlPath=none
  -o ControlPersist=no
  -o LogLevel=ERROR
)

declare -a actual=()
ssh_transport_argv actual interactive alpha "${VIRTDEV_SSH_KEY}" 2222 /dev/null
assert_argv actual expected_base

declare -a expected_batch=("${expected_base[@]}" -o BatchMode=yes)
ssh_transport_argv actual batch alpha "${VIRTDEV_SSH_KEY}" 2222 /dev/null
assert_argv actual expected_batch

declare -a expected_poll=(
  "${expected_base[@]}" -o BatchMode=yes -o ConnectTimeout=3
)
ssh_transport_argv actual poll alpha "${VIRTDEV_SSH_KEY}" 2222 /dev/null 3
assert_argv actual expected_poll

for invalid in '' -- -o -L target -A -K -f -G -V -vvf -Zvalue -F/dev/null \
    -i/tmp/key -p22 -oStrictHostKeyChecking=no -S/tmp/socket -M; do
  if ssh_client_option_valid "${invalid}"; then
    printf 'unsafe client option token accepted: %q\n' "${invalid}" >&2
    exit 1
  fi
done
for valid in -N -NT -vvv -L3000:localhost:3000 -R8022:localhost:22 \
    -D1080 '-Elog file'; do
  ssh_client_option_valid "${valid}" || {
    printf 'self-contained client option rejected: %q\n' "${valid}" >&2
    exit 1
  }
done

effective="$({
  "${actual[@]}" -G dev@127.0.0.1
} 2>/dev/null)"
grep -Fqx 'stricthostkeychecking true' <<< "${effective}"
grep -Fqx "hostkeyalias ${alpha_alias}" <<< "${effective}"
grep -Fqx "userknownhostsfile ${alpha_known}" <<< "${effective}"
grep -Fqx 'globalknownhostsfile /dev/null' <<< "${effective}"
grep -Fqx 'hostkeyalgorithms ssh-ed25519' <<< "${effective}"
grep -Fqx 'controlmaster false' <<< "${effective}"
grep -Fqx 'controlpersist no' <<< "${effective}"

weak_config="${test_tmp}/weak-config"
printf '%s\n' \
  'Host *' \
  '  StrictHostKeyChecking no' \
  '  UserKnownHostsFile /tmp/wrong-known-hosts' \
  '  HostKeyAlias wrong-alias' \
  '  HostKeyAlgorithms ssh-rsa' \
  '  ForwardAgent yes' \
  '  GSSAPIDelegateCredentials yes' \
  '  HostName 203.0.113.9' \
  '  AddressFamily any' \
  '  CanonicalizeHostname always' \
  '  ProxyCommand /usr/bin/false' \
  '  ProxyJump attacker.example' \
  '  ControlMaster yes' > "${weak_config}"
ssh_transport_argv actual interactive alpha "${VIRTDEV_SSH_KEY}" 2222 \
  "${weak_config}"
effective="$({ "${actual[@]}" -G dev@127.0.0.1; } 2>/dev/null)"
grep -Fqx 'stricthostkeychecking true' <<< "${effective}"
grep -Fqx "userknownhostsfile ${alpha_known}" <<< "${effective}"
grep -Fqx "hostkeyalias ${alpha_alias}" <<< "${effective}"
grep -Fqx 'hostkeyalgorithms ssh-ed25519' <<< "${effective}"
grep -Fqx 'forwardagent no' <<< "${effective}"
grep -Fqx 'gssapidelegatecredentials no' <<< "${effective}"
grep -Fqx 'controlmaster false' <<< "${effective}"
grep -Fqx 'hostname 127.0.0.1' <<< "${effective}"
grep -Fqx 'addressfamily inet' <<< "${effective}"
grep -Fqx 'canonicalizehostname false' <<< "${effective}"
if grep -Eq '^proxy(command|jump) ' <<< "${effective}"; then
  printf 'configured proxy escaped the fixed loopback transport\n' >&2
  exit 1
fi

ssh_transport_argv actual interactive beta "${VIRTDEV_SSH_KEY}" 2222 /dev/null
beta_known="$(ssh_host_identity_known_hosts beta)"
[[ "${alpha_known}" != "${beta_known}" ]]
[[ "$(< "${VIRTDEV_HOME}/projects/alpha/ssh-host/host_key.pub")" \
      != "$(< "${VIRTDEV_HOME}/projects/beta/ssh-host/host_key.pub")" ]]
[[ " ${actual[*]} " == *" UserKnownHostsFile=${beta_known} "* ]]
[[ " ${actual[*]} " == *' HostKeyAlias=virtdev-beta '* ]]
if ssh-keygen -F virtdev-alpha -f "${beta_known}" >/dev/null; then
  printf 'beta host state accepted alpha alias\n' >&2
  exit 1
fi

fixture_bin="${test_tmp}/bin"
mkdir "${fixture_bin}"
ln -s "${repository}/tests/fixtures/ssh-argv" "${fixture_bin}/ssh"
export SSH_ARGV_FILE="${test_tmp}/rsync.argv"
ssh_command=''
rsync_wrapper=''
ssh_rsync_command ssh_command rsync_wrapper alpha \
  "${VIRTDEV_SSH_KEY}" 2222
PATH="${fixture_bin}:${PATH}" "${ssh_command}" \
  dev@127.0.0.1 rsync --server 'path with spaces'
mapfile -d '' -t wrapper_argv < "${SSH_ARGV_FILE}"
declare -a expected_wrapper=(
  "${expected_batch[@]:1}" dev@127.0.0.1 rsync --server 'path with spaces'
)
assert_argv wrapper_argv expected_wrapper
rm -f -- "${rsync_wrapper}"

printf '2222\n' > "${VIRTDEV_HOME}/projects/alpha/port"
export SYSTEMCTL_ACTIVE_STATE=active
export SSH_ARGV_FILE="${test_tmp}/cli.argv"
export SSH_ARGV_STATUS=42
for help_args in '--help' '-h' 'alpha --help'; do
  read -r -a help_argv <<< "${help_args}"
  status=0
  PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
    "${repository}/bin/virtdev-ssh" "${help_argv[@]}" \
      >"${test_tmp}/help.stdout" 2>"${test_tmp}/help.stderr" || status=$?
  if (( status != 0 )) \
      || ! grep -Fqx 'usage: virtdev-ssh <project> [--client-option=<option>]... [-- [command...]]' \
        "${test_tmp}/help.stdout" \
      || [[ -s "${test_tmp}/help.stderr" ]]; then
    printf 'universal help failed for: %s\n' "${help_args}" >&2
    exit 1
  fi
done

status=0
PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-ssh" --color=no alpha \
    --client-option=-L3000:localhost:3000 \
    --client-option=-N -- --help -h --color=yes -dash 'two words' '' \
    >/dev/null 2>"${test_tmp}/cli.stderr" || status=$?
(( status == 42 ))
mapfile -d '' -t cli_argv < "${SSH_ARGV_FILE}"

config_path=''
for (( index = 0; index < ${#cli_argv[@]}; index++ )); do
  if [[ "${cli_argv[index]}" == -F ]]; then
    config_path="${cli_argv[index + 1]}"
    break
  fi
done
[[ -n "${config_path}" && ! -e "${config_path}" ]]
expected_cli=("${expected_base[@]:1}")
expected_cli[1]="${config_path}"
expected_cli+=(
  -L3000:localhost:3000 -N dev@127.0.0.1 --help -h --color=yes -dash 'two words' ''
)
assert_argv cli_argv expected_cli

for invalid_cli in \
    'alpha uname' \
    'alpha --client-option=-L --' \
    'alpha --client-option=target --' \
    'alpha --client-option=-F/dev/null --' \
    'alpha --client-option=-i/tmp/key --' \
    'alpha --client-option=-p22 --' \
    'alpha --client-option=-f --' \
    'alpha --client-option=-A --' \
    'alpha --client-option=-K --' \
    'alpha --client-option=-G --' \
    'alpha --client-option=-V --' \
    'alpha --color=bogus --' \
    'alpha --client-option=-oStrictHostKeyChecking=no --'; do
  read -r -a invalid_argv <<< "${invalid_cli}"
  status=0
  PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
    "${repository}/bin/virtdev-ssh" "${invalid_argv[@]}" \
      >/dev/null 2>/dev/null || status=$?
  (( status == 64 )) || {
    printf 'ambiguous SSH CLI was accepted: %s (status %d)\n' \
      "${invalid_cli}" "${status}" >&2
    exit 1
  }
done

too_many=(alpha)
for (( index = 0; index <= 64; index++ )); do
  too_many+=(--client-option=-v)
done
status=0
PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
  "${repository}/bin/virtdev-ssh" "${too_many[@]}" \
    >/dev/null 2>/dev/null || status=$?
(( status == 64 )) || {
  printf 'client-option bound was not enforced (status %d)\n' "${status}" >&2
  exit 1
}

printf 'ok - SSH policy argv is shared, strict, and project-bound\n'
printf 'ok - loopback port reuse selects distinct project host identities\n'
printf 'ok - client options and arbitrary remote argv stay on their sides\n'
