#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${0}")" && pwd)"

if [[ ! -f "${repository_root}/user.conf" ]]; then
  echo 'user.conf not found' >&2
  exit 1
fi

# shellcheck source=user.conf
source "${repository_root}/user.conf"

key_directory="$(dirname "${SSH_KEY_PATH}")"
if [[ ! -d "${key_directory}" ]]; then
  echo "Creating directory for key pair at '${key_directory}'"
  mkdir -p "${key_directory}"
  chmod 700 "${key_directory}"
fi

if [[ -f "${SSH_KEY_PATH}" ]]; then
  echo "SSH key already exists: '${SSH_KEY_PATH}'"
else
  ssh-keygen -t ed25519 -N '' -C 'virtdev' -f "${SSH_KEY_PATH}"
fi
