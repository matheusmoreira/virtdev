#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # nameref arrays and imported constants

set -euo pipefail

repository="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
test_tmp="$(mktemp -d)"
sshd_pid=''
cleanup() {
  if [[ -n "${sshd_pid}" ]]; then
    kill -TERM "${sshd_pid}" 2>/dev/null || true
    wait "${sshd_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_tmp}"
}
trap cleanup EXIT

export VIRTDEV_HOME="${test_tmp}/store with spaces"
export VIRTDEV_SSH_KEY="${test_tmp}/client key"
mkdir -p "${VIRTDEV_HOME}/projects/alpha" \
  "${VIRTDEV_HOME}/projects/beta" \
  "${VIRTDEV_HOME}/projects/-alpha"
printf 'ssh-host-identity=1\n' > "${VIRTDEV_HOME}/projects/alpha/guest-contract"
printf 'ssh-host-identity=1\n' > "${VIRTDEV_HOME}/projects/beta/guest-contract"
printf 'ssh-host-identity=1\n' > "${VIRTDEV_HOME}/projects/-alpha/guest-contract"
/usr/bin/ssh-keygen -q -t ed25519 -N '' -C '' -f "${VIRTDEV_SSH_KEY}"
certificate_authority="${test_tmp}/certificate-authority"
/usr/bin/ssh-keygen -q -t ed25519 -N '' -C '' -f "${certificate_authority}"
/usr/bin/ssh-keygen -q -s "${certificate_authority}" -I adjacent-test \
  -n dev -V +5m "${VIRTDEV_SSH_KEY}.pub"
[[ -f "${VIRTDEV_SSH_KEY}-cert.pub" ]]

# shellcheck disable=SC1090
source "${repository}/lib/virtdev/import"
import ssh
ssh_host_identity_ensure alpha
ssh_host_identity_ensure beta
ssh_host_identity_ensure -alpha

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
  ssh -F /dev/null -i "${VIRTDEV_SSH_KEY}" -o CertificateFile=none -p 2222
  -o HostName=127.0.0.1
  -o AddressFamily=inet
  -o CanonicalizeHostname=no
  -o ProxyCommand=none
  -o ProxyJump=none
  -o IdentitiesOnly=yes
  -o IdentityAgent=none
  -o PKCS11Provider=none
  -o SecurityKeyProvider=internal
  -o PubkeyAuthentication=yes
  -o PreferredAuthentications=publickey
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o GSSAPIAuthentication=no
  -o HostbasedAuthentication=no
  -o ForwardAgent=no
  -o GSSAPIDelegateCredentials=no
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=\"${alpha_known}\""
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
  "${expected_base[@]}" -n -o BatchMode=yes -o ConnectTimeout=3
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

encoded_dollar='$'
declare -a encoded_arguments=(
  plain 'two words' '' "single'quote" 'double"quote' 'back\slash'
  $'line\nbreak' '*?[abc]' '; command' "${encoded_dollar}(command)" -leading
)
encoded_command=''
ssh_remote_command_encode encoded_command printf '%s\0' \
  "${encoded_arguments[@]}"
encoded_output="${test_tmp}/encoded-output"
expected_encoded_output="${test_tmp}/expected-encoded-output"
/bin/sh -c "${encoded_command}" > "${encoded_output}"
printf '%s\0' "${encoded_arguments[@]}" > "${expected_encoded_output}"
if ! cmp -s -- "${expected_encoded_output}" "${encoded_output}"; then
  printf 'remote-command encoding did not preserve argv boundaries\n' >&2
  exit 1
fi

effective="$({
  "${actual[@]}" -G dev@127.0.0.1
} 2>/dev/null)"
grep -Fqx 'stricthostkeychecking true' <<< "${effective}"
grep -Fqx "hostkeyalias ${alpha_alias}" <<< "${effective}"
grep -Fqx "userknownhostsfile ${alpha_known}" <<< "${effective}"
grep -Fqx 'globalknownhostsfile /dev/null' <<< "${effective}"
grep -Fqx 'hostkeyalgorithms ssh-ed25519' <<< "${effective}"
grep -Fqx 'pubkeyauthentication true' <<< "${effective}"
grep -Fqx 'preferredauthentications publickey' <<< "${effective}"
grep -Fqx 'passwordauthentication no' <<< "${effective}"
grep -Fqx 'kbdinteractiveauthentication no' <<< "${effective}"
grep -Fqx 'gssapiauthentication no' <<< "${effective}"
grep -Fqx 'hostbasedauthentication no' <<< "${effective}"
grep -Fqx 'identityagent none' <<< "${effective}"
grep -Fqx 'securitykeyprovider internal' <<< "${effective}"
mapfile -t effective_identities \
  < <(sed -n 's/^identityfile //p' <<< "${effective}")
mapfile -t effective_certificates \
  < <(sed -n 's/^certificatefile //p' <<< "${effective}")
if (( ${#effective_identities[@]} != 1 )) \
    || [[ "${effective_identities[0]}" != "${VIRTDEV_SSH_KEY}" ]] \
    || (( ${#effective_certificates[@]} != 1 )) \
    || [[ "${effective_certificates[0]}" != none ]] \
    || grep -Eq '^pkcs11provider ' <<< "${effective}"; then
  printf 'effective SSH policy exposed an extra credential source\n' >&2
  exit 1
fi
grep -Fqx 'controlmaster false' <<< "${effective}"
grep -Fqx 'controlpersist no' <<< "${effective}"

live_port=$(( 40000 + BASHPID % 20000 ))
while /usr/bin/ss -H -ltn "sport = :${live_port}" | grep -q .; do
  (( live_port++ ))
  (( live_port <= 65535 )) || {
    printf 'could not reserve a local SSH test port\n' >&2
    exit 1
  }
done
sshd_config="${test_tmp}/sshd_config"
sshd_log="${test_tmp}/sshd.log"
client_log="${test_tmp}/client.log"
alpha_host_key="$(ssh_host_identity_key alpha)"
printf '%s\n' \
  "Port ${live_port}" \
  'ListenAddress 127.0.0.1' \
  "HostKey \"${alpha_host_key}\"" \
  "PidFile \"${test_tmp}/sshd.pid\"" \
  "AuthorizedKeysFile \"${VIRTDEV_SSH_KEY}.pub\"" \
  "TrustedUserCAKeys \"${certificate_authority}.pub\"" \
  'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' \
  'UsePAM no' \
  'StrictModes no' \
  "AllowUsers $(id -un)" > "${sshd_config}"
/usr/bin/sshd -D -e -f "${sshd_config}" >"${sshd_log}" 2>&1 &
sshd_pid=$!
sshd_ready=0
for _ in {1..100}; do
  if /usr/bin/ss -H -ltn "sport = :${live_port}" | grep -q .; then
    sshd_ready=1
    break
  fi
  kill -0 "${sshd_pid}" 2>/dev/null || break
  sleep 0.02
done
if (( ! sshd_ready )); then
  printf 'local sshd did not become ready\n' >&2
  cat "${sshd_log}" >&2
  exit 1
fi

declare -a live_argv=()
ssh_transport_argv live_argv batch alpha "${VIRTDEV_SSH_KEY}" \
  "${live_port}" /dev/null
status=0
"${live_argv[@]}" -vvv "$(id -un)@127.0.0.1" true \
  >/dev/null 2>"${client_log}" || status=$?
if (( status != 0 )) \
    || grep -Eq 'ED25519-CERT|-cert\.pub' "${client_log}" \
    || ! grep -Eq 'Offering public key: .* ED25519 ' "${client_log}"; then
  printf 'SSH offered an adjacent certificate or failed raw-key authentication\n' >&2
  cat "${client_log}" >&2
  cat "${sshd_log}" >&2
  exit 1
fi

poll_input="${test_tmp}/poll-input"
printf 'preserved\n' > "${poll_input}"
exec {poll_input_fd}< "${poll_input}"
ssh_transport_argv live_argv poll alpha "${VIRTDEV_SSH_KEY}" \
  "${live_port}" /dev/null 3
status=0
"${live_argv[@]}" "$(id -un)@127.0.0.1" 'cat >/dev/null' \
  <&"${poll_input_fd}" >/dev/null 2>>"${client_log}" || status=$?
poll_input_record=''
IFS= read -r poll_input_record <&"${poll_input_fd}" || true
exec {poll_input_fd}<&-
if (( status != 0 )) || [[ "${poll_input_record}" != preserved ]]; then
  printf 'poll-mode SSH consumed caller stdin\n' >&2
  cat "${client_log}" >&2
  exit 1
fi

printf '%s\n' "${live_port}" > "${VIRTDEV_HOME}/projects/alpha/port"
live_config_home="${test_tmp}/live-config"
mkdir -p "${live_config_home}"
remote_marker="${test_tmp}/remote-command-executed"
remote_injection="\$(touch -- '${remote_marker}')"
declare -a boundary_arguments=(
  "${remote_injection}" 'two words' '' "single'quote" 'double"quote'
  'back\slash' $'line\nbreak' '*?[abc]' '; :' -leading
)
boundary_output="${test_tmp}/boundary-output"
boundary_expected="${test_tmp}/boundary-expected"
boundary_stderr="${test_tmp}/boundary-stderr"
printf '%s\0' "${boundary_arguments[@]}" > "${boundary_expected}"
status=0
PATH="${repository}/tests/fixtures:${PATH}" \
  SYSTEMCTL_ACTIVE_STATE=active XDG_CONFIG_HOME="${live_config_home}" \
  "${repository}/bin/virtdev-ssh" alpha -- /usr/bin/bash -c \
    'printf '\''%s\0'\'' "$@"' argv0 "${boundary_arguments[@]}" \
    > "${boundary_output}" 2> "${boundary_stderr}" || status=$?
if (( status != 0 )) || [[ -e "${remote_marker}" ]] \
    || ! cmp -s -- "${boundary_expected}" "${boundary_output}"; then
  printf 'live SSH did not preserve exact remote argv (status %d)\n' \
    "${status}" >&2
  cat "${boundary_stderr}" >&2
  exit 1
fi

stdin_script="${test_tmp}/stdin-script"
stdin_output="${test_tmp}/stdin-output"
stdin_expected="${test_tmp}/stdin-expected"
printf 'printf '\''%%s\\0'\'' "$@"\nprintf '\''stdin-ok\\n'\''\n' \
  > "${stdin_script}"
{
  printf '%s\0' 'two words' ''
  printf 'stdin-ok\n'
} > "${stdin_expected}"
status=0
PATH="${repository}/tests/fixtures:${PATH}" \
  SYSTEMCTL_ACTIVE_STATE=active XDG_CONFIG_HOME="${live_config_home}" \
  "${repository}/bin/virtdev-ssh" alpha -- /usr/bin/bash -s -- \
    'two words' '' < "${stdin_script}" > "${stdin_output}" \
    2> "${test_tmp}/stdin-stderr" || status=$?
if (( status != 0 )) || ! cmp -s -- "${stdin_expected}" "${stdin_output}"; then
  printf 'live SSH did not preserve remote argv with script stdin (status %d)\n' \
    "${status}" >&2
  cat "${test_tmp}/stdin-stderr" >&2
  exit 1
fi

kill -TERM "${sshd_pid}"
wait "${sshd_pid}" 2>/dev/null || true
sshd_pid=''

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
  '  PubkeyAuthentication no' \
  '  PreferredAuthentications password,keyboard-interactive,gssapi-with-mic,hostbased' \
  '  PasswordAuthentication yes' \
  '  KbdInteractiveAuthentication yes' \
  '  GSSAPIAuthentication yes' \
  '  HostbasedAuthentication yes' \
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
grep -Fqx 'pubkeyauthentication true' <<< "${effective}"
grep -Fqx 'preferredauthentications publickey' <<< "${effective}"
grep -Fqx 'passwordauthentication no' <<< "${effective}"
grep -Fqx 'kbdinteractiveauthentication no' <<< "${effective}"
grep -Fqx 'gssapiauthentication no' <<< "${effective}"
grep -Fqx 'hostbasedauthentication no' <<< "${effective}"
if grep -Eq '^proxy(command|jump) ' <<< "${effective}"; then
  printf 'configured proxy escaped the fixed loopback transport\n' >&2
  exit 1
fi

unsafe_config="${test_tmp}/unsafe-config"
for unsafe_directive in \
    'IdentityFile /tmp/extra-key' \
    'certificatefile=/tmp/extra-cert' \
    'IDENTITYAGENT /tmp/extra-agent' \
    'PKCS11Provider /tmp/extra-provider' \
    'SecurityKeyProvider=/tmp/extra-provider' \
    'Include /tmp/extra-config'; do
  printf 'Host *\n  %s\n' "${unsafe_directive}" > "${unsafe_config}"
  status=0
  (
    declare -a rejected=()
    ssh_transport_argv rejected interactive alpha "${VIRTDEV_SSH_KEY}" \
      2222 "${unsafe_config}"
  ) >"${test_tmp}/unsafe.output" 2>&1 || status=$?
  if (( status != ssh_config_policy_exit_code )); then
    printf 'unsafe SSH directive was accepted: %s (status %d)\n' \
      "${unsafe_directive}" "${status}" >&2
    cat "${test_tmp}/unsafe.output" >&2
    exit 1
  fi
done

ssh_transport_argv actual interactive beta "${VIRTDEV_SSH_KEY}" 2222 /dev/null
beta_known="$(ssh_host_identity_known_hosts beta)"
[[ "${alpha_known}" != "${beta_known}" ]]
[[ "$(< "${VIRTDEV_HOME}/projects/alpha/ssh-host/host_key.pub")" \
      != "$(< "${VIRTDEV_HOME}/projects/beta/ssh-host/host_key.pub")" ]]
[[ " ${actual[*]} " == *" UserKnownHostsFile=\"${beta_known}\" "* ]]
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
config_home="${test_tmp}/config"
mkdir -p "${config_home}/virtdev/projects/alpha"
printf 'Host *\n    SendEnv PROJECT' \
  > "${config_home}/virtdev/projects/alpha/ssh_config"
printf '    SendEnv SYSTEM\n' > "${config_home}/virtdev/ssh_config"
export SSH_CONFIG_COPY="${test_tmp}/generated-ssh-config"
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
  XDG_CONFIG_HOME="${config_home}" \
  "${repository}/bin/virtdev-ssh" --color=no alpha \
    --client-option=-L3000:localhost:3000 \
    --client-option=-N -- --help -h --color=yes -dash 'two words' '' \
    >/dev/null 2>"${test_tmp}/cli.stderr" || status=$?
(( status == 42 ))
mapfile -d '' -t cli_argv < "${SSH_ARGV_FILE}"
grep -Fqx '    SendEnv PROJECT' "${SSH_CONFIG_COPY}"
grep -Fqx '    SendEnv SYSTEM' "${SSH_CONFIG_COPY}"

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
expected_cli_remote=''
ssh_remote_command_encode expected_cli_remote \
  --help -h --color=yes -dash 'two words' ''
expected_cli+=(
  -L3000:localhost:3000 -N dev@127.0.0.1 "${expected_cli_remote}"
)
assert_argv cli_argv expected_cli

printf '2222\n' > "${VIRTDEV_HOME}/projects/-alpha/port"
SSH_ARGV_FILE="${test_tmp}/leading-cli.argv"
status=0
PATH="${fixture_bin}:${repository}/tests/fixtures:${PATH}" \
  XDG_CONFIG_HOME="${config_home}" \
  "${repository}/bin/virtdev-ssh" -- -alpha -- printf '%s' ok \
    >/dev/null 2>"${test_tmp}/leading-cli.stderr" || status=$?
if (( status != 42 )); then
  printf 'SSH rejected a leading-hyphen project (status %d)\n' "${status}" >&2
  cat "${test_tmp}/leading-cli.stderr" >&2
  exit 1
fi
mapfile -d '' -t leading_cli_argv < "${SSH_ARGV_FILE}"
leading_count=${#leading_cli_argv[@]}
leading_remote=''
ssh_remote_command_encode leading_remote printf '%s' ok
if (( leading_count < 2 )) \
    || [[ "${leading_cli_argv[leading_count - 2]}" != dev@127.0.0.1 \
      || "${leading_cli_argv[leading_count - 1]}" != "${leading_remote}" ]]; then
  printf 'SSH changed the leading-hyphen project command\n' >&2
  exit 1
fi

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
