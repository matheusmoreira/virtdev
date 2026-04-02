#!/usr/bin/env bash

set -euo pipefail

build_directory="$(dirname "${0}")"/build
output_directory="${build_directory}"/output
work_directory="${build_directory}"/work
profile_directory="${build_directory}"/profile

profile=/usr/share/archiso/configs/releng
image_name=virtdev
image_version="$(date +%Y-%m-%d)"
image_application='Arch Linux automated installer for virtual development machines'

if ! command -v mkarchiso &>/dev/null; then
  echo 'mkarchiso not found, install archiso' >&2
  exit 1
fi

if [[ ! -d "${profile}" ]]; then
  echo "missing archiso profile: '${profile}'" >&2
  exit 3
fi

echo 'Clearing build tree...'
rm -rf "${output_directory:?}" "${work_directory:?}" "${profile_directory:?}"
mkdir -p "${output_directory}" "${work_directory}" "${profile_directory}"

echo "Copying profile: '${profile}'"
cp -r "${profile}/." "${profile_directory}/"

echo 'Overlaying airootfs...'
cp -r airootfs/. "${profile_directory}/airootfs/"

patch-profile-definition() {
  sed -i \
    "s/^${1}=.*/${1}=\"${2}\"/" \
    "${profile_directory}"/profiledef.sh
}

echo 'Patching profile definition...'
patch-profile-definition iso_name "${image_name}"
patch-profile-definition iso_version "${image_version}"
patch-profile-definition iso_application "${image_application}"

chmod 644 "${profile_directory}"/airootfs/etc/systemd/system/archinstall-auto.service
chmod 600 "${profile_directory}"/airootfs/root/archinstall/*.json

echo "Creating Arch Linux installation media..."
sudo mkarchiso -v -w "${work_directory}" -o "${output_directory}" "${profile_directory}"

iso="${output_directory}"/"${image_name}"-"${image_version}"-x86_64.iso

if [[ ! -r "${iso}" ]]; then
  echo "Failed to create Arch Linux installation media: '${iso}'" >&2
  exit 4
fi

echo "Created Arch Linux installation media: '${iso}'"
