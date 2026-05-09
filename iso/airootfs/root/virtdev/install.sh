#!/usr/bin/env bash
#
# virtdev base system installer
#
# Installs and configures Arch Linux for virtdev virtual machines.
# Runs unattended inside the live ISO, invoked by virtdev-install.service.
# On success, the systemd service powers off the virtual machine.
#
# Assumes two virtio disks:
#
#   /dev/vda = system (ESP + XBOOTLDR + root)
#   /dev/vdb = home
#
# Reads from QEMU fw_cfg:
#
#   opt/virtdev/ssh_key     SSH public key for the dev user (required)
#   opt/virtdev/timezone    Timezone identifier (optional, defaults to UTC)
#   opt/virtdev/locale      Locale (optional, defaults to en_US.UTF-8)
#   opt/virtdev/keymap      Console keymap (optional, defaults to us)
#   opt/virtdev/dns         DNS server (optional, defaults to 9.9.9.9)
#   opt/virtdev/packages    Additional packages, one per line (optional)
#   opt/virtdev/script      Custom script to run after install (optional)
#   opt/virtdev/inventory   User inventory script (optional)
#

set -euo pipefail

fw_cfg_dir=/sys/firmware/qemu_fw_cfg/by_name/opt/virtdev
target=/mnt
progress=/dev/virtio-ports/org.virtdev.install

progress_report() {
  [[ -e "${progress}" ]] && printf '%s\n' "${1}" > "${progress}"
}

# ---------------------------------------------------------------------------
# 1. Partition
# ---------------------------------------------------------------------------
#
#   /dev/vda layout:
#
#      0 MiB -    1 MiB   alignment gap
#      1 MiB -  513 MiB   ESP              512 MiB fat32  vda1  ef00
#    513 MiB - 1537 MiB   XBOOTLDR        1024 MiB fat32  vda2  ea00
#   1537 MiB -  END       root             rest     ext4   vda3  8304
#
#   /dev/vdb layout:
#
#      0 MiB -    1 MiB   alignment gap
#      1 MiB -  END       home             rest     ext4   vdb1  8302
#

progress_report partitioning
printf 'virtdev: partitioning disks\n'

progress_report partitioning:vda
sgdisk --zap-all /dev/vda
sgdisk --new=1:1M:+512M    --typecode=1:ef00 /dev/vda
sgdisk --new=2:513M:+1024M --typecode=2:ea00 /dev/vda
sgdisk --new=3:1537M:0     --typecode=3:8304 /dev/vda

progress_report partitioning:vdb
sgdisk --zap-all /dev/vdb
sgdisk --new=1:1M:0        --typecode=1:8302 /dev/vdb

udevadm settle
progress_report udevadm_settle

# ---------------------------------------------------------------------------
# 2. Format
# ---------------------------------------------------------------------------

progress_report formatting
printf 'virtdev: formatting filesystems\n'

progress_report formatting:vda1
mkfs.fat  -F 32       /dev/vda1
progress_report formatting:vda2
mkfs.fat  -F 32       /dev/vda2
progress_report formatting:vda3
mkfs.ext4 -F          /dev/vda3
progress_report formatting:vdb1
mkfs.ext4 -F -L home  /dev/vdb1

# ---------------------------------------------------------------------------
# 3. Mount
# ---------------------------------------------------------------------------

progress_report mounting
printf 'virtdev: mounting filesystems\n'

progress_report mounting:root
mount          /dev/vda3 "${target}"
progress_report mounting:boot
mount --mkdir  /dev/vda2 "${target}"/boot
progress_report mounting:efi
mount --mkdir  /dev/vda1 "${target}"/efi
progress_report mounting:home
mount --mkdir  /dev/vdb1 "${target}"/home

# ---------------------------------------------------------------------------
# 4. Pre-pacstrap configuration
# ---------------------------------------------------------------------------

progress_report pre_pacstrap
mkdir -p "${target}"/etc
printf 'KEYMAP=us\n' > "${target}"/etc/vconsole.conf

# ---------------------------------------------------------------------------
# 5. Pacstrap
# ---------------------------------------------------------------------------

progress_report pacstrap
printf 'virtdev: installing base system and packages\n'

pacstrap -K "${target}" \
    base linux linux-firmware sudo mkinitcpio efibootmgr \
    base-devel git openssh \
    vim less man-db man-pages curl wget which tree unzip zip htop rsync socat \
    kitty-terminfo foot-terminfo rxvt-unicode-terminfo ghostty-terminfo \
    ripgrep fd fzf bat jq eza \
    tmux strace gdb lsof inetutils openbsd-netcat entr diffutils patch \
    bash-completion shellcheck time github-cli ncdu hyperfine 7zip tokei direnv \
    python python-pip python-virtualenv \
    nodejs npm \
    rustup

# ---------------------------------------------------------------------------
# 6. Configure pacman on target
# ---------------------------------------------------------------------------

progress_report pacman_config
sed -i 's/^#Color$/Color/' "${target}"/etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 5/' "${target}"/etc/pacman.conf

printf 'virtdev: pacman configured\n'

# ---------------------------------------------------------------------------
# 7. Generate fstab
# ---------------------------------------------------------------------------

progress_report fstab
genfstab -U "${target}" >> "${target}"/etc/fstab

home_uuid="$(blkid -s UUID -o value /dev/vdb1)"
sed -i "s|^UUID=${home_uuid}|LABEL=home|" "${target}"/etc/fstab

printf 'virtdev: fstab generated\n'

# ---------------------------------------------------------------------------
# 8. Locale
# ---------------------------------------------------------------------------

progress_report locale

progress_report locale:gen
sed -i 's/^#en_US.UTF-8 UTF-8$/en_US.UTF-8 UTF-8/' "${target}"/etc/locale.gen
arch-chroot "${target}" locale-gen

progress_report locale:conf
printf 'LANG=en_US.UTF-8\n' > "${target}"/etc/locale.conf

printf 'virtdev: locale configured\n'

# ---------------------------------------------------------------------------
# 9. Timezone
# ---------------------------------------------------------------------------

progress_report timezone

if [[ -f "${fw_cfg_dir}"/timezone/raw ]]; then
  timezone="$(< "${fw_cfg_dir}"/timezone/raw)"
else
  timezone=UTC
fi

if [[ ! -f "${target}/usr/share/zoneinfo/${timezone}" ]]; then
  printf >&2 'virtdev: timezone not found: %s, falling back to UTC\n' "${timezone}"
  timezone=UTC
fi

arch-chroot "${target}" ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime

printf 'virtdev: timezone set to %s\n' "${timezone}"

# ---------------------------------------------------------------------------
# 10. Hostname
# ---------------------------------------------------------------------------

progress_report hostname
printf 'virtdev\n' > "${target}"/etc/hostname

cp /root/virtdev/virtdev-hostname.service "${target}"/etc/systemd/system/

printf 'virtdev: hostname configured\n'

# ---------------------------------------------------------------------------
# 11. mkinitcpio
# ---------------------------------------------------------------------------

progress_report initramfs
sed -i 's/^HOOKS=(.*)$/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)/' \
    "${target}"/etc/mkinitcpio.conf

arch-chroot "${target}" mkinitcpio -P

printf 'virtdev: initramfs rebuilt\n'

# ---------------------------------------------------------------------------
# 12. Bootloader
# ---------------------------------------------------------------------------

progress_report bootloader

progress_report bootloader:install
arch-chroot "${target}" bootctl install

root_uuid="$(blkid -s UUID -o value /dev/vda3)"
if [[ -z "${root_uuid}" ]]; then
  >&2 printf 'virtdev: failed to read UUID of root partition\n'
  exit 1
fi

progress_report bootloader:entry
mkdir -p "${target}"/boot/loader/entries
cat > "${target}"/boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=${root_uuid} rw rootfstype=ext4 console=tty0 console=ttyS0
ENTRY

progress_report bootloader:config
cat > "${target}"/efi/loader/loader.conf <<CONF
default arch.conf
timeout 0
editor  no
CONF

printf 'virtdev: bootloader installed\n'

# ---------------------------------------------------------------------------
# 13. Network
# ---------------------------------------------------------------------------

progress_report network

progress_report network:wired
cat > "${target}"/etc/systemd/network/20-wired.network <<CONF
[Match]
Name=en*

[Network]
DHCP=yes

[DHCPv4]
UseDNS=false
CONF

progress_report network:dns
install -d "${target}"/etc/systemd/resolved.conf.d
cat > "${target}"/etc/systemd/resolved.conf.d/dns.conf <<CONF
[Resolve]
DNS=9.9.9.9
CONF

progress_report network:resolv
ln -sf /run/systemd/resolve/stub-resolv.conf "${target}"/etc/resolv.conf

progress_report network:mirrorlist
cp /etc/pacman.d/mirrorlist "${target}"/etc/pacman.d/mirrorlist

printf 'virtdev: network configured\n'

# ---------------------------------------------------------------------------
# 14. User
# ---------------------------------------------------------------------------

progress_report user

progress_report user:create
arch-chroot "${target}" useradd -m -G wheel dev

progress_report user:ssh
if [[ ! -f "${fw_cfg_dir}"/ssh_key/raw ]]; then
  >&2 printf 'virtdev: SSH public key not found in fw_cfg\n'
  exit 2
fi

dev_uid="$(arch-chroot "${target}" id -u dev)"
dev_gid="$(arch-chroot "${target}" id -g dev)"
install -d -m 700 -o "${dev_uid}" -g "${dev_gid}" "${target}"/home/dev/.ssh
install    -m 600 -o "${dev_uid}" -g "${dev_gid}" \
    /dev/stdin "${target}"/home/dev/.ssh/authorized_keys \
    < "${fw_cfg_dir}"/ssh_key/raw

progress_report user:lock
arch-chroot "${target}" passwd -l root
arch-chroot "${target}" passwd -l dev

progress_report user:sudo
printf 'dev ALL=(ALL:ALL) NOPASSWD: ALL\n' > "${target}"/etc/sudoers.d/dev
chmod 440 "${target}"/etc/sudoers.d/dev

progress_report user:sshd
cp /etc/ssh/sshd_config "${target}"/etc/ssh/sshd_config

printf 'virtdev: user and SSH configured\n'

# ---------------------------------------------------------------------------
# 15. Serial console autologin
# ---------------------------------------------------------------------------

progress_report autologin
install -d "${target}"/etc/systemd/system/serial-getty@ttyS0.service.d
cat > "${target}"/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<CONF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin dev --noclear %I 115200 linux
CONF

printf 'virtdev: serial console autologin configured\n'

# ---------------------------------------------------------------------------
# 16. Enable services
# ---------------------------------------------------------------------------

progress_report services
arch-chroot "${target}" systemctl enable \
    sshd \
    serial-getty@ttyS0 \
    systemd-networkd \
    systemd-resolved \
    systemd-timesyncd \
    fstrim.timer \
    virtdev-hostname

printf 'virtdev: services enabled\n'

# ---------------------------------------------------------------------------
# 17. Finalize
# ---------------------------------------------------------------------------

progress_report sync
sync

progress_report complete
printf 'virtdev: installation complete\n'
