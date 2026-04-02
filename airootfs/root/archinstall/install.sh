#!/usr/bin/env bash

# Automatically installs the virtdev system using archinstall
# then sets up any remaining configuration.
#
# This script will:
#
#   1. Assume two disks exist
#       a. /dev/vda = root
#       b. /dev/vdb = home
#   2. Compute actual virtual disk sizes
#   3. Patch sentinel values in config.json
#   3. Run archinstall
#   4. Run post-install steps
#
# config.json stores 0 B as a sentinel for dynamic partition lengths.
# Bypassing this script and running archinstall directly
# should fail during partition creation. This is intentional.
#
# The installed system is left mounted at /mnt by archinstall.
# Post-install steps run via arch-chroot against /mnt.
#

set -euo pipefail

config=/root/archinstall/config.json
creds=/root/archinstall/creds.json

# Patch sentinel partition lengths with real disk geometry

disk_size() {
  lsblk --bytes --nodeps --noheadings --output SIZE "${1}" | tr -d ' '
}

sector_size() {
  lsblk --bytes --nodeps --noheadings --output PHY-SEC "${1}" | tr -d ' '
}

vda_bytes="$(disk_size /dev/vda)"
vdb_bytes="$(disk_size /dev/vdb)"

vda_sector_size="$(sector_size /dev/vda)"
vdb_sector_size="$(sector_size /dev/vdb)"

mib=$(( 1024 * 1024 ))

# /dev/vda layout:
#
#   0 MiB -         1 MiB    alignment gap
#   1 MiB -       513 MiB    ESP (512 MiB, fixed)
# 513 MiB - END -   1 MiB    root
#
esp_start=$((1 * mib))
esp_length=$((512 * mib))

root_start=$((513 * mib))
root_length=$((vda_bytes - root_start - mib))

# /dev/vdb layout:
#
#   0 MiB -       1 MiB    alignment gap
#   1 MiB - END - 1 MiB    home
#
home_start=$((1 * mib))
home_length=$((vdb_bytes - home_start - mib))

if ((root_length <= 0 || home_length <= 0)); then
  >&2 printf 'virtdev: disk too small: root_length=%d home_length=%d\n' \
             "${root_length}" "${home_length}"
  exit 1
fi

tmp=$(mktemp)
jq                                                          \
    --argjson esp_start       "${esp_start}"                \
    --argjson esp_length      "${esp_length}"               \
    --argjson root_start      "${root_start}"               \
    --argjson root_length     "${root_length}"              \
    --argjson home_start      "${home_start}"               \
    --argjson home_length     "${home_length}"              \
    --argjson vda_sector_size "${vda_sector_size}"          \
    --argjson vdb_sector_size "${vdb_sector_size}"          \
    '
    (.disk_config.device_modifications[0].partitions[].start.sector_size,
     .disk_config.device_modifications[0].partitions[].size.sector_size) |= {"value": $vda_sector_size, "unit": "B"} |
    (.disk_config.device_modifications[1].partitions[].start.sector_size,
     .disk_config.device_modifications[1].partitions[].size.sector_size) |= {"value": $vdb_sector_size, "unit": "B"} |
    .disk_config.device_modifications[0].partitions[0].start |= (.value = $esp_start   | .unit = "B") |
    .disk_config.device_modifications[0].partitions[0].size  |= (.value = $esp_length  | .unit = "B") |
    .disk_config.device_modifications[0].partitions[1].start |= (.value = $root_start  | .unit = "B") |
    .disk_config.device_modifications[0].partitions[1].size  |= (.value = $root_length | .unit = "B") |
    .disk_config.device_modifications[1].partitions[0].start |= (.value = $home_start  | .unit = "B") |
    .disk_config.device_modifications[1].partitions[0].size  |= (.value = $home_length | .unit = "B")
    ' "${config}" > "${tmp}" && mv "${tmp}" "${config}"

printf 'virtdev: disk layout patched\n'
printf 'virtdev: vda(esp=%d root=%d sector_size=%d)\n' \
       "${esp_length}" "${root_length}" "${vda_sector_size}"
printf 'virtdev: vdb(home=%d sector_size=%d)\n' \
       "${home_length}" "${vdb_sector_size}"

# Run archinstall

archinstall                 \
    --config "${config}"    \
    --creds  "${creds}"     \
    --silent

# Post-install steps

arch-chroot /mnt systemctl enable systemd-networkd systemd-resolved sshd
arch-chroot /mnt ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Lock password-based login on all accounts
arch-chroot /mnt passwd -l root
arch-chroot /mnt passwd -l dev

# Set up sudo for the dev user
printf 'dev ALL=(ALL:ALL) NOPASSWD: ALL\n' > /mnt/etc/sudoers.d/dev
chmod 440 /mnt/etc/sudoers.d/dev
