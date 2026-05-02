# virtdev

Per-project KVM/QEMU virtual machines for isolated development.

Each project gets its own Arch Linux VM backed by a thin qcow2 delta
over a shared sealed base. The isolation boundary is a hardware-assisted
hypervisor, not a namespace or permission system.

## Getting started

### Requirements

- Arch Linux host, bash >= 5.2
- KVM-capable CPU, QEMU (`qemu-system-x86`), OVMF (`edk2-ovmf`)
- OpenSSH (`openssh`), socat, rsync, jq, archiso

### Install

From the AUR (`virtdev-git`):

```
yay -S virtdev-git
```

From source (no install step needed — scripts auto-detect the layout):

```
git clone https://github.com/matheusmoreira/virtdev.git
cd virtdev
```

### One-time setup

Build the base system that all project VMs derive from:

```bash
virtdev key                       # generate SSH key pair
virtdev iso                       # build Arch Linux installer ISO
virtdev install                   # install base system to qcow2 disks
virtdev seal                      # mark base read-only
```

### Create a project

```bash
virtdev create myproject          # derive a thin delta VM
virtdev start myproject           # boot it (systemd user service)
virtdev wait myproject            # wait for SSH
virtdev ssh myproject             # connect
```

### Day-to-day

```bash
virtdev ssh myproject             # develop
virtdev stop myproject            # shut down (ACPI, SIGTERM fallback)
virtdev start myproject           # boot again later
```

### Provisioning

Project VMs are expendable. Automate setup with a provision script:

```bash
# ~/.config/virtdev/projects/myproject/provision
sudo pacman -S --noconfirm --needed neovim ripgrep fd
git clone https://github.com/me/dotfiles ~/dotfiles
make -C ~/dotfiles install
```

Run it manually on a fresh VM:

```bash
virtdev ssh myproject bash -s < ~/.config/virtdev/projects/myproject/provision
```

Or let `virtdev-recreate` run it automatically (see below).

### Backup and restore

Preserve state that provisioning cannot reproduce (project memories,
untracked files, dotfiles, shell history).

Write a backup manifest at `~/.config/virtdev/projects/myproject/manifest`:

```
.claude/
project-a/notes.md
project-a/.env.local
.bashrc
.config/nvim/
```

Paths are relative to `/home/dev/` in the guest. Then:

```bash
virtdev backup myproject          # snapshot listed paths to host
virtdev backup --list myproject   # list existing snapshots
virtdev restore myproject         # restore latest snapshot
virtdev restore myproject 2026-04-25/14-30-22  # restore a specific one
```

Backups survive `virtdev-destroy` but are removed by `virtdev-nuke`.
A project-local manifest at `${VIRTDEV_HOME}/projects/myproject/manifest`
takes precedence when present (for one-off experiments; discarded with the VM).

### Recreate

Rebuild a project VM on the current sealed base without losing state:

```bash
virtdev recreate myproject
```

This chains: backup, stop, destroy, create, start, wait, provision, restore.
It prompts once (type the project name), then drives each step. On failure,
it prints the command to resume from the failed step.

If there is a provision script at
`~/.config/virtdev/projects/myproject/provision`, recreate discovers and
runs it automatically between start and restore.

Flags: `--no-backup`, `--no-restore`, `--no-provision`, `--provision <path>`,
`--yes`/`-y`, `--verbose`/`-v`.

### Base system maintenance

Update the sealed base (system packages, dotfiles, etc.):

```bash
virtdev maintain                  # copies base to staging, boots writable VM
# ... perform maintenance inside the VM ...
sudo poweroff                     # triggers reseal prompt
```

After resealing, existing project VMs refuse to boot (version mismatch).
Recreate them:

```bash
virtdev recreate myproject
```

Or use `virtdev upgrade` to do everything in one command — back up all
projects, maintain the base, and rebuild them all on the new base:

```bash
virtdev upgrade
```

Flags: `--only=a,b`, `--except=c,d`, `--skip-outdated`, `--yes`/`-y`,
`--verbose`/`-v`.

## Commands

All commands are available as `virtdev <command>` (dispatcher) or
`virtdev-<command>` (direct). `virtdev help <command>` shows usage.

### Setup

| Command | Description |
|---------|-------------|
| `virtdev-key` | Generate ed25519 SSH key pair |
| `virtdev-iso` | Build the Arch Linux installation ISO |
| `virtdev-install [iso]` | Install base system to qcow2 disks |
| `virtdev-seal` | Seal installation as read-only base |
| `virtdev-maintain` | Boot sealed base for maintenance, reseal on exit |

### Project lifecycle

| Command | Description |
|---------|-------------|
| `virtdev-create <project>` | Derive a project VM from the sealed base |
| `virtdev-start <project> [port]` | Start VM as a systemd user service |
| `virtdev-stop <project>` | ACPI shutdown with SIGTERM fallback |
| `virtdev-destroy [-y] <project>` | Delete a project VM (confirmation required) |
| `virtdev-recreate [flags] <project>` | Backup, destroy, rebuild, provision, restore |
| `virtdev-upgrade [flags]` | Back up, maintain base, rebuild all projects |
| `virtdev-nuke` | Delete all virtdev data (confirmation required) |

### Access

| Command | Description |
|---------|-------------|
| `virtdev-ssh <project> [args...]` | SSH into a running VM |
| `virtdev-console <project>` | Serial console (detach: Ctrl-]) |
| `virtdev-wait <project>` | Poll until SSH is available |
| `virtdev-transfer <project> <src> <dest>` | rsync files (prefix remote path with `:`) |
| `virtdev-list` | List projects with port and status |

### Backup

| Command | Description |
|---------|-------------|
| `virtdev-backup [--list] [--verbose] <project>` | Snapshot guest paths to host |
| `virtdev-restore [--verbose] <project> [snapshot]` | Restore a snapshot into a running VM |

## Configuration

Environment variables (defaults shown):

| Variable | Default |
|----------|---------|
| `VIRTDEV_HOME` | `~/.local/share/virtdev` |
| `VIRTDEV_SSH_KEY` | `${VIRTDEV_HOME}/ssh/id` |
| `VIRTDEV_CACHE` | `~/.cache/virtdev` |
| `VIRTDEV_TIMEZONE` | `UTC` |
| `VIRTDEV_ISO_PROFILE` | auto-detected |
| `VIRTDEV_ISO` | `${VIRTDEV_CACHE}/virtdev.iso` |
| `VIRTDEV_SYSTEM_DISK_SIZE` | `24G` |
| `VIRTDEV_HOME_DISK_SIZE` | `48G` |
| `VIRTDEV_VM_MEMORY` | `4096` (MB) |
| `VIRTDEV_VM_CPUS` | `4` |
| `VIRTDEV_STOP_TIMEOUT` | `60` (seconds) |
| `VIRTDEV_WAIT_TIMEOUT` | `120` (seconds) |
| `OVMF_CODE` | `/usr/share/edk2/x64/OVMF_CODE.4m.fd` |
| `OVMF_VARS` | `/usr/share/edk2/x64/OVMF_VARS.4m.fd` |

`VIRTDEV_HOME` and `VIRTDEV_CACHE` follow XDG defaults
(`${XDG_DATA_HOME}` and `${XDG_CACHE_HOME}` respectively).

## Architecture

See `DESIGN.md` for the full architecture, threat model, locking model,
SSH hardening, and known limitations.

### Image hierarchy

```
system/                    sealed base (mode 444)
  system.qcow2             OS, bootloader, packages
  home.qcow2               /home/dev template
  nvram                    UEFI variable store
  version                  monotonic counter, bumped on reseal

projects/<name>/           per-project (writable deltas)
  system.qcow2  --backs--> system/system.qcow2
  home.qcow2    --backs--> system/home.qcow2
  nvram                    copy of system/nvram
  version                  must match system/version to boot
```

Project VMs are thin deltas. Only divergent writes consume disk space.

### Two-disk design

- **vda** (system) — OS, bootloader, installed packages
- **vdb** (home) — `/home/dev` and all project work

The system disk can be updated or replaced without touching project state.

### Runtime

VMs run as transient systemd user services (`virtdev-<project>.service`):

```bash
systemctl --user status virtdev-myproject
journalctl --user -u virtdev-myproject
```

### Concurrency

Mutating commands take an exclusive `flock(2)` on `${VIRTDEV_HOME}/lock`
and fail fast on contention (exit 75). `cat ${VIRTDEV_HOME}/lock` shows
the holder's PID.

## Data layout

```
${VIRTDEV_HOME}/                    (~/.local/share/virtdev)
  lock                              flock(2) target; holder PID
  ssh/id, ssh/id.pub                SSH key pair
  system/                           sealed base (mode 444)
  maintenance/                      transient staging for virtdev-maintain
  projects/<name>/
    system.qcow2, home.qcow2       delta disks
    nvram, version                  UEFI state, base version
    port, monitor.sock, console.sock  runtime (while running)
    manifest                     optional project-local manifest
  backups/<project>/<date>/<time>/
    project, manifest, version   metadata
    tree/                           user content

${VIRTDEV_CACHE}/                   (~/.cache/virtdev)
  virtdev.iso                       built ISO
  work/, profile/                   mkarchiso artifacts

~/.config/virtdev/projects/<name>/
  manifest                       canonical backup manifest (survives nuke)
  provision                         auto-run by virtdev-recreate
```

## License

GNU Affero General Public License v3.0 — see [LICENSE.AGPLv3](LICENSE.AGPLv3).
