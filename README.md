# virtdev

Isolated virtual development machines on KVM/QEMU.

virtdev automates the creation and management of lightweight Arch Linux VMs
for software development. Each project gets its own VM backed by qcow2 delta
images over a shared sealed base, providing hypervisor-level isolation between
projects with minimal disk overhead.

## Motivation

The primary motivation is defense against npm supply chain attacks. Language
package registries routinely serve compromised packages that exfiltrate
credentials, read source trees, and establish persistence. OS-level sandboxing
shares the same kernel and user session as the host. Running each project in a
separate KVM virtual machine raises the bar to a hardware-assisted hypervisor
escape, which is a qualitatively different and much harder attack.

virtdev reduces the operational overhead of managing per-project VMs to the
point where the isolation is practical for day-to-day development.

## How It Works

1. **Generate SSH keys** for VM authentication
2. **Build an ISO** — an automated Arch Linux installer
3. **Install a base system** — headless Arch Linux on qcow2 disks
4. **Seal the base** — mark it read-only
5. **Create project VMs** — thin qcow2 delta layers over the sealed base
6. **SSH in and develop** — each VM is an independent, isolated environment

```
virtdev-key                          # Generate SSH key pair
virtdev-iso                          # Build installation ISO
virtdev-install                      # Install base system
virtdev-seal                         # Seal as read-only base

virtdev-create myproject             # Derive a project VM
virtdev-start myproject              # Start the VM
virtdev-wait myproject               # Wait for SSH to come up
virtdev-ssh myproject                # SSH into the VM
virtdev-ssh myproject ./provision.sh # Run a provisioning script
virtdev-stop myproject               # Clean shutdown
```

## Backing up and restoring project state

When a base system update forces delta-mode project VMs to be
recreated (see `DESIGN.md`), `virtdev-backup` and `virtdev-restore`
preserve state that the provision script cannot reproduce —
Claude Code project memories, untracked files in git working
trees, hand-edited dotfiles, shell history.

Write a manifest. The canonical location is
`~/.config/virtdev/projects/<project>/backup.list` — dotfile-friendly
and survives `virtdev-nuke`. A project-local copy at
`${VIRTDEV_HOME}/projects/<project>/backup.list` takes precedence
when present (handy for one-off experiments; discarded with the VM).

```
# Claude Code project memories
.claude/

# Untracked files in git working trees
project-a/notes.md
project-a/.env.local

# Shell config
.bashrc
.config/nvim/
```

Snapshot, recreate, restore:

```
virtdev-backup myproject               # snapshot the running VM
virtdev-backup --list myproject        # see snapshots
virtdev-stop myproject
virtdev-destroy myproject              # type project name to confirm
virtdev-create myproject               # rebuild on current base
virtdev-start myproject
virtdev-wait myproject
virtdev-ssh myproject ./provision.sh   # re-run provisioning
virtdev-restore myproject              # restore latest snapshot
```

Backups live under `${VIRTDEV_HOME}/backups/<project>/<date>/<time>/`
and are preserved across `virtdev-destroy` but removed by
`virtdev-nuke`.

## Requirements

- Arch Linux host
- bash 5.2 or later (the scripts use `source -p` for the shared library system)
- KVM-capable CPU (`lscpu | grep Virtualization`)
- QEMU with x86_64 system emulation (`qemu-system-x86`)
- OVMF UEFI firmware (`edk2-ovmf`)
- OpenSSH client and server (`openssh`)
- socat (`socat`) — for monitor/console socket interaction
- rsync (`rsync`) — for file transfer between host and VM; must also be installed in the guest
- jq (`jq`) — for ISO building
- archiso (`archiso`) — for ISO building

### Installation from AUR

```
yay -S virtdev
```

### Installation from Source

```
git clone https://github.com/matheusmoreira/virtdev.git
cd virtdev
```

When running from a git checkout, the scripts auto-detect the ISO profile
directory adjacent to the `bin/` directory. No installation step is required.

To install system-wide:

```
sudo install -Dm755 bin/virtdev-* -t /usr/bin/
sudo install -Dm644 lib/virtdev/* -t /usr/lib/virtdev/
sudo install -Dm644 iso/* -Dt /usr/share/virtdev/profile/
# Repeat for subdirectories under iso/
```

The `bin/` and `lib/virtdev/` directories must end up as siblings under
the install prefix (e.g., `/usr/bin/` and `/usr/lib/virtdev/`); the
scripts resolve the library directory relative to their own location and
will not find it otherwise.

## Quick Start

```bash
# 1. Generate SSH keys
virtdev-key

# 2. Build the installation ISO (requires archiso, jq, sudo)
virtdev-iso

# 3. Install the base system (runs QEMU, waits for auto-install)
virtdev-install

# 4. Seal the base images (marks them read-only)
virtdev-seal

# 5. Create and start a project VM
virtdev-create myproject
virtdev-start myproject
virtdev-wait myproject

# 6. Connect
virtdev-ssh myproject
```

## Commands

| Command | Description |
|---------|-------------|
| `virtdev-key` | Generate ed25519 SSH key pair for VM authentication |
| `virtdev-iso` | Build the Arch Linux installation ISO |
| `virtdev-install [iso]` | Install base system to fresh qcow2 disks |
| `virtdev-seal` | Seal installation as read-only base images |
| `virtdev-maintain` | Boot sealed base for maintenance, reseal on exit |
| `virtdev-create <project>` | Derive a project VM from the sealed base |
| `virtdev-start <project> [port]` | Start a project VM as a systemd user service; assigns SSH port |
| `virtdev-stop <project>` | Clean ACPI shutdown with SIGTERM fallback |
| `virtdev-ssh <project> [args...]` | SSH into a running project VM |
| `virtdev-transfer <project> <src> <dest>` | Copy files between host and VM (prefix remote path with `:`) |
| `virtdev-console <project>` | Attach to the serial console (detach: Ctrl-]) |
| `virtdev-wait <project>` | Poll until SSH is accepting connections |
| `virtdev-list` | List all projects with port and running status |
| `virtdev-destroy <project>` | Delete a project VM (requires confirmation) |
| `virtdev-nuke` | Delete all virtdev data (requires confirmation) |

## Configuration

All commands respect these environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `VIRTDEV_HOME` | `${XDG_DATA_HOME}/virtdev` | Base directory for all virtdev data |
| `VIRTDEV_SSH_KEY` | `${VIRTDEV_HOME}/ssh/id` | Path to the ed25519 private key |
| `VIRTDEV_TIMEZONE` | `UTC` | Timezone for the installed system |
| `VIRTDEV_ISO_PROFILE` | Auto-detected | Path to the ISO profile directory |
| `VIRTDEV_ISO` | `${XDG_CACHE_HOME}/virtdev/virtdev.iso` | Path to the built ISO |
| `VIRTDEV_SYSTEM_DISK_SIZE` | `24G` | System disk qcow2 size |
| `VIRTDEV_HOME_DISK_SIZE` | `48G` | Home disk qcow2 size |
| `VIRTDEV_VM_MEMORY` | `4096` | VM RAM in megabytes |
| `VIRTDEV_VM_CPUS` | `4` | Number of VM CPU cores |
| `VIRTDEV_STOP_TIMEOUT` | `60` | Seconds to wait for ACPI shutdown |
| `VIRTDEV_WAIT_TIMEOUT` | `120` | Seconds to wait for SSH availability |
| `OVMF_CODE` | `/usr/share/edk2/x64/OVMF_CODE.4m.fd` | UEFI firmware code |
| `OVMF_VARS` | `/usr/share/edk2/x64/OVMF_VARS.4m.fd` | UEFI firmware variables |

## Architecture

### Two-Disk Design

Every VM uses two separate qcow2 disks:

- **vda** (system) — OS, bootloader, installed packages
- **vdb** (home) — `/home/dev` and all project work

This enables independent lifecycle management: the system disk can be updated
or replaced without touching project state.

### Image Hierarchy

```
system/                          (sealed, read-only, mode 444)
  system.qcow2                  base system disk
  home.qcow2                    base home disk
  nvram                         base UEFI variable store
  version                       monotonic counter, bumped by each reseal

projects/<name>/                 (per-project, writable)
  system.qcow2  ---backing-->   system/system.qcow2
  home.qcow2    ---backing-->   system/home.qcow2
  nvram                         per-project UEFI variable store copy
  version                       copy of system/version at create time
  port                          SSH forwarding port (present while running)
```

Project VMs are thin delta layers. Only writes that differ from the sealed base
consume disk space. Creating a new project VM is nearly instantaneous.

The `version` counter guards against a subtle corruption scenario:
`virtdev-maintain` replaces the sealed base, but existing project deltas hold
absolute paths to `system/*.qcow2` and would silently compose against the new
content. `virtdev-start` compares versions and refuses to boot a project whose
delta was created against an older base.

### Partition Layout

**System disk (vda):**

| Partition | Size | Filesystem | Mount | Purpose |
|-----------|------|------------|-------|---------|
| vda1 | 512 MiB | fat32 | `/efi` | EFI System Partition |
| vda2 | 1024 MiB | fat32 | `/boot` | XBOOTLDR (systemd-boot) |
| vda3 | remainder | ext4 | `/` | Root filesystem |

**Home disk (vdb):**

| Partition | Size | Filesystem | Mount | Purpose |
|-----------|------|------------|-------|---------|
| vdb1 | 100% | ext4 | `/home` | Home directory (LABEL=home) |

### Networking

VMs use QEMU user-mode networking with SSH port forwarding bound to
`127.0.0.1`. DNS is configured to use Quad9 (9.9.9.9) directly, bypassing
QEMU's DNS proxy.

### SSH Security

The installed system runs a hardened `sshd`:

- ed25519 host key only
- Public key authentication only
- All password-based authentication disabled
- All accounts locked (`passwd -l`)
- CBC ciphers removed, NIST ECDH kex removed, weak MACs removed
- `AllowUsers dev`, `PermitRootLogin no`

### VM Runtime

Project VMs run as transient systemd user services:

```
systemd-run --user --unit=virtdev-<project> -- qemu-system-x86_64 ...
```

Standard systemd tools work for inspection:

```
systemctl --user status virtdev-myproject
journalctl --user -u virtdev-myproject
```

`virtdev-stop` sends ACPI power-down via the QEMU monitor socket and waits
for the unit to exit, with `VIRTDEV_STOP_TIMEOUT` bounding the wait. On
timeout — or if the monitor is unreachable — it falls back to SIGTERM via
`systemctl stop`. It reports the QEMU exit status alongside the confirmation
(`0` for a clean guest poweroff, `143` for a SIGTERM fallback).

### Concurrency

Commands that mutate virtdev state take an exclusive `flock(2)` on
`${VIRTDEV_HOME}/lock` for their duration and fail fast on contention
with exit code 75 (BSD `EX_TEMPFAIL` — temporary failure, retry possible):

- Locking: `virtdev-install`, `virtdev-seal`, `virtdev-maintain`,
  `virtdev-create`, `virtdev-start`, `virtdev-stop`, `virtdev-destroy`,
  `virtdev-nuke`
- Not locking: `virtdev-list`, `virtdev-ssh`, `virtdev-wait`,
  `virtdev-console`, `virtdev-transfer`, `virtdev-key`, `virtdev-iso`,
  `virtdev-backup`, `virtdev-restore`

The lock file is visible and contains the current holder's PID, so
`cat ${VIRTDEV_HOME}/lock` during a contention error shows which process
to wait on. If the holder is `virtdev-maintain`, the error message points
at the maintenance VM specifically, since a maintenance session can hold
the lock for hours.

## Base System Maintenance

```bash
virtdev-maintain
```

This copies the sealed base to a staging area, boots it as a writable VM,
and waits for you to perform maintenance (system updates, dotfile changes,
etc.). On clean `sudo poweroff`, it offers to reseal the updated images as the
new base.

After resealing, existing project VMs in delta mode do not inherit changes
automatically. `virtdev-start` will refuse to boot such a project because its
recorded base version no longer matches `system/version`. Recreate the
project with `virtdev-destroy` + `virtdev-create` and re-provision.

## Provisioning

Project VMs are designed to be expendable. The intended workflow:

1. `virtdev-create <project>` — derive a fresh VM
2. `virtdev-start <project>` — start it
3. `virtdev-ssh <project> ./provision.sh` — install tools, clone repos
4. Develop

When the VM accumulates unwanted state or the base is updated, destroy and
recreate. The provision script makes this fast and repeatable.

## Data Layout

```
${VIRTDEV_HOME}/                         (~/.local/share/virtdev)
  lock                                   flock(2) target; holder PID inside
  ssh/
    id                                   ed25519 private key (mode 600)
    id.pub                               ed25519 public key
  system/                                sealed base (mode 444)
    system.qcow2
    home.qcow2
    nvram
    version                              base generation counter
  maintenance/                           transient; present while virtdev-maintain is active
    system.qcow2
    home.qcow2
    nvram
  projects/
    <name>/
      system.qcow2                       delta over system/system.qcow2
      home.qcow2                         delta over system/home.qcow2
      nvram                              per-project UEFI variable store
      version                            base generation this project was derived from
      port                               SSH forwarding port (present while running)
      monitor.sock                       QEMU monitor (while running)
      console.sock                       serial console (while running)

${XDG_CACHE_HOME}/virtdev/               (~/.cache/virtdev)
  virtdev.iso                            built installation ISO
  work/                                  mkarchiso work tree
  profile/                               assembled ISO profile
```

## License

GNU Affero General Public License v3.0 — see [LICENSE.AGPLv3](LICENSE.AGPLv3).
