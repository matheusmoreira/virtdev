# Maintainer: Matheus Afonso Martins Moreira <matheus@matheusmoreira.com>
pkgname=virtdev-git
pkgver=r221.5ff934b
pkgrel=1
pkgdesc='Isolated virtual development machines on KVM/QEMU'
arch=('any')
url='https://github.com/matheusmoreira/virtdev'
license=('AGPL-3.0-or-later')
depends=(
  'bash>=5.2'
  'qemu-img'
  'qemu-system-x86'
  'edk2-ovmf'
  'openssh'
  'socat'
)
optdepends=(
  'archiso: required for building the installation ISO (virtdev-iso)'
  'jq: required for building the installation ISO (virtdev-iso)'
  'rsync: required for backup, restore, transfer, and recreate'
)
makedepends=('git')
provides=("${pkgname%-git}")
conflicts=("${pkgname%-git}")
source=("${pkgname}::git+${url}.git")
sha256sums=('SKIP')

pkgver() {
  cd "${pkgname}"

  if git describe --long --tags 2>/dev/null | grep -q .; then
    git describe --long --tags | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g'
  else
    printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
  fi
}

package() {
  cd "${pkgname}"

  # Install commands
  install -Dm755 -t "${pkgdir}/usr/bin/" bin/virtdev bin/virtdev-*

  # Install shared bash libraries (sourced via the bin/ scripts'
  # bootstrap; not executable).
  install -Dm644 -t "${pkgdir}/usr/lib/${pkgname%-git}/" lib/virtdev/*

  # Install ISO profile
  local _profiledir="${pkgdir}/usr/share/${pkgname%-git}/profile"

  install -Dm644 iso/packages.x86_64    "${_profiledir}/packages.x86_64"
  install -Dm644 iso/profiledef.sh      "${_profiledir}/profiledef.sh"
  install -Dm644 iso/VERSION            "${_profiledir}/VERSION"

  install -Dm644 iso/efiboot/loader/loader.conf         "${_profiledir}/efiboot/loader/loader.conf"
  install -Dm644 iso/efiboot/loader/entries/virtdev.conf "${_profiledir}/efiboot/loader/entries/virtdev.conf"

  install -Dm644 iso/airootfs/etc/pacman.d/mirrorlist                     "${_profiledir}/airootfs/etc/pacman.d/mirrorlist"
  install -Dm644 iso/airootfs/etc/ssh/sshd_config                        "${_profiledir}/airootfs/etc/ssh/sshd_config"
  install -Dm644 iso/airootfs/etc/systemd/network/20-wired.network       "${_profiledir}/airootfs/etc/systemd/network/20-wired.network"
  install -Dm644 iso/airootfs/etc/systemd/resolved.conf.d/dns.conf       "${_profiledir}/airootfs/etc/systemd/resolved.conf.d/dns.conf"
  install -Dm644 iso/airootfs/etc/systemd/system/archinstall-auto.service "${_profiledir}/airootfs/etc/systemd/system/archinstall-auto.service"

  install -dm755 "${_profiledir}/airootfs/etc/systemd/system/multi-user.target.wants"
  ln -s ../archinstall-auto.service "${_profiledir}/airootfs/etc/systemd/system/multi-user.target.wants/archinstall-auto.service"

  install -Dm644 iso/airootfs/root/archinstall/config.json "${_profiledir}/airootfs/root/archinstall/config.json"
  install -Dm644 iso/airootfs/root/archinstall/creds.json  "${_profiledir}/airootfs/root/archinstall/creds.json"
  install -Dm755 iso/airootfs/root/archinstall/install.sh  "${_profiledir}/airootfs/root/archinstall/install.sh"

  # Install documentation
  install -Dm644 README.md  "${pkgdir}/usr/share/doc/${pkgname%-git}/README.md"
  install -Dm644 DESIGN.md  "${pkgdir}/usr/share/doc/${pkgname%-git}/DESIGN.md"
  install -Dm644 LICENSE.AGPLv3 "${pkgdir}/usr/share/licenses/${pkgname%-git}/LICENSE"
}
