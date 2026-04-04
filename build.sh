#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${0}")" && pwd)"

if [[ ! -f "${repository_root}/user.conf" ]]; then
  echo 'user.conf not found' >&2
  exit 1
fi

# shellcheck source=user.conf
source "${repository_root}/user.conf"

build_directory="${repository_root}"/build
output_directory="${build_directory}"/output
work_directory="${build_directory}"/work
profile_directory="${build_directory}"/profile
packages_file="${profile_directory}"/packages.x86_64

profile=/usr/share/archiso/configs/releng
image_name=virtdev
image_version="$(date +%Y-%m-%d)"
image_application='Arch Linux automated installer for virtual development machines'

if ! command -v mkarchiso &>/dev/null; then
  echo 'mkarchiso not found, install archiso' >&2
  exit 2
fi

if ! command -v jq &>/dev/null; then
  echo 'jq not found, install jq' >&2
  exit 3
fi

if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
  echo "SSH public key not found: '${SSH_KEY_PATH}.pub'" >&2
  echo 'Run setup-ssh-key.sh first' >&2
  exit 4
fi

if [[ ! -d "${profile}" ]]; then
  echo "missing archiso profile: '${profile}'" >&2
  exit 5
fi

public_key="$(< "${SSH_KEY_PATH}.pub")"

echo 'Clearing build tree...'
sudo rm -rf "${output_directory:?}" "${work_directory:?}" "${profile_directory:?}"
mkdir -p "${output_directory}" "${work_directory}" "${profile_directory}"

echo "Copying profile: '${profile}'"
cp -r "${profile}/." "${profile_directory}/"
rm -rf "${profile_directory}"/grub \
       "${profile_directory}"/syslinux \
       "${profile_directory}"/efiboot/loader/entries/*.conf

echo 'Overlaying ISO configuration files...'
cp -r iso/. "${profile_directory}/"

echo 'Injecting SSH public key into installation image...'
config_json="${profile_directory}/airootfs/root/archinstall/config.json"
jq --arg key "${public_key}"                      \
   '.users[0].ssh_authorized_keys = [$key]'       \
   "${config_json}" > "${config_json}.tmp"
mv "${config_json}.tmp" "${config_json}"

echo 'Creating Arch Linux installation media...'
sudo mkarchiso -v -w "${work_directory}" -o "${output_directory}" "${profile_directory}"

iso="${output_directory}"/"${image_name}"-"${image_version}"-x86_64.iso

if [[ ! -r "${iso}" ]]; then
  echo "Failed to create Arch Linux installation media: '${iso}'" >&2
  exit 6
fi

echo "Created Arch Linux installation media: '${iso}'"
