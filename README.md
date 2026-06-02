# virtdev

Per-project KVM/QEMU virtual machines for isolated development.

Each project gets its own Arch Linux virtual machine backed by a thin qcow2
delta over a shared sealed base. The isolation boundary is a hardware-assisted
hypervisor, not a namespace or permission system.

**Isolation scope:** guest→host via the host-loopback path (passt
`--map-host-loopback none`, which closes what the old SLIRP gateway
address exposed) and via passt's host-global-address mapping
(`--map-guest-addr none`) are blocked for project and maintenance virtual
machines. Guest→host via the host's real LAN IP (including `0.0.0.0`-bound
services such as `sshd`) remains reachable in Phase 1 — closing that path
requires a host-side nftables egress filter (a planned fast-follow).
Outbound internet access is unrestricted (package managers, Claude Code, etc.).

## Getting started

### Requirements

- Arch Linux host, bash >= 5.2
- KVM-capable CPU, QEMU (`qemu-system-x86`), OVMF (`edk2-ovmf`)
- OpenSSH (`openssh`), passt, socat, rsync, archiso

### Install

From the AUR (`virtdev-git`):

```
yay -S virtdev-git
```

From source — scripts auto-detect the layout, and `make` builds the
small C helper `virtdev-exchange` that `virtdev-maintain` requires
(needs a C toolchain, e.g. `base-devel`):

```
git clone https://github.com/matheusmoreira/virtdev.git
cd virtdev
make
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
virtdev ssh myproject -- bash -s < ~/.config/virtdev/projects/myproject/provision
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
virtdev ssh maintenance           # connect from another terminal
# ... perform maintenance inside the VM ...
sudo poweroff                     # triggers reseal prompt
```

Optional hooks in `~/.config/virtdev/maintenance/`:

- **`provision`** — runs inside the guest after SSH is up (dotfiles, tools)
- **`inventory`** — captures system state before and after; diff shown before reseal

Flags: `--yes`/`-y`, `--no-provision`, `--no-inventory`.

After resealing, existing project VMs refuse to boot (generation mismatch).
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

### Detaching a project

A project can be detached from the sealed base, converting its delta images
into standalone images. Detached projects boot without a generation check, are
skipped by `virtdev upgrade`, and must be updated independently:

```bash
virtdev stop myproject
virtdev detach myproject
virtdev start myproject
```

Use `--in-place` to modify images directly instead of convert-then-swap
(less disk usage, no rollback on interruption). Recreating a detached
project reattaches it to the current base.

## Commands

All commands are available as `virtdev <command>` (dispatcher) or
`virtdev-<command>` (direct). `virtdev help <command>` shows usage.

### Setup

| Command | Description |
|---------|-------------|
| `virtdev-key` | Generate ed25519 SSH key pair |
| `virtdev-iso` | Build the Arch Linux installation ISO |
| `virtdev-install [flags] [iso]` | Install base system to qcow2 disks |
| `virtdev-seal` | Seal installation as read-only base |
| `virtdev-maintain [flags]` | Boot sealed base for maintenance, reseal on exit |

### Project lifecycle

| Command | Description |
|---------|-------------|
| `virtdev-create <project>` | Derive a project VM from the sealed base |
| `virtdev-start <project> [port]` | Start VM as a systemd user service |
| `virtdev-stop <project>` | ACPI shutdown with SIGTERM fallback |
| `virtdev-move <old-name> <new-name>` | Rename a project (must be stopped) |
| `virtdev-destroy [-y] <project>` | Delete a project VM (confirmation required) |
| `virtdev-detach [--in-place] [-y] <project>` | Convert delta images to standalone, removing base dependency |
| `virtdev-recreate [flags] <project>` | Backup, destroy, rebuild, provision, restore |
| `virtdev-upgrade [flags]` | Back up, maintain base, rebuild all projects |
| `virtdev-nuke` | Delete all virtdev data (confirmation required) |

### Access

| Command | Description |
|---------|-------------|
| `virtdev-ssh <project> [args...]` | SSH into a running virtual machine (fires pre/post-ssh triggers) |
| `virtdev-console <project>` | Serial console (detach: Ctrl-]) |
| `virtdev-wait <project>` | Poll until SSH is available |
| `virtdev-transfer <project> <src> <dest>` | rsync files (prefix remote path with `:`) |
| `virtdev-list` | List projects with port, status, and generation (colored) |

### Inspection

| Command | Description |
|---------|-------------|
| `virtdev-status <project>` | Print `running` or `stopped` |
| `virtdev-port <project>` | Print SSH port of a running virtual machine |
| `virtdev-pid <project>` | Print QEMU process ID |
| `virtdev-path <project> [resource]` | Print path to project resource |
| `virtdev-disk <project>` | Show disk usage info |
| `virtdev-log [-f] <project>` | Show journal logs (shorthand for journalctl) |
| `virtdev-monitor <project>` | Attach to QEMU monitor |
| `virtdev-generation [project]` | Print base or project generation |
| `virtdev-stale` | List projects with stale base generation |

### Backup

| Command | Description |
|---------|-------------|
| `virtdev-backup [--list] [--latest] [--verbose] <project>` | Snapshot guest paths to host |
| `virtdev-restore [--verbose] <project> [snapshot]` | Restore a snapshot into a running VM |

## Configuration

Environment variables (defaults shown):

| Variable | Default |
|----------|---------|
| `VIRTDEV_HOME` | `~/.local/share/virtdev` |
| `VIRTDEV_SSH_KEY` | `${VIRTDEV_HOME}/ssh/id` |
| `VIRTDEV_CACHE` | `~/.cache/virtdev` |
| `VIRTDEV_TIMEZONE` | host timezone (UTC fallback) |
| `VIRTDEV_LOCALE` | host locale (`en_US.UTF-8` fallback) |
| `VIRTDEV_KEYMAP` | host keymap (`us` fallback) |
| `VIRTDEV_DNS` | `9.9.9.9` |
| `VIRTDEV_PACKAGES` | (none) |
| `VIRTDEV_SCRIPT` | (none) |
| `VIRTDEV_INVENTORY` | (none) |
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

All commands support `--color=yes|no|auto` (default: auto). Auto enables
color when stderr is a terminal, `NO_COLOR` is unset, and `TERM` is not
`dumb`. Colors come from terminfo via `tput`, not hardcoded ANSI escapes.

Output convention: user-facing messages go to stderr, machine-readable
output (ports, paths, PIDs, status words) goes to stdout.

## Triggers

Triggers are user-supplied scripts that run at defined points in a
command's lifecycle. Currently supported events: `pre-ssh` and `post-ssh`.

```
~/.config/virtdev/triggers/pre-ssh                     # system (all projects)
~/.config/virtdev/projects/myproject/triggers/pre-ssh   # per-project
```

System triggers fire first, then per-project. Each must be an executable
file. Triggers inherit the calling process's environment. virtdev exports
`VIRTDEV_PROJECT`, `VIRTDEV_PORT`, and `VIRTDEV_SSH_KEY` before firing
pre-ssh triggers; post-ssh triggers also receive `VIRTDEV_SSH_EXIT`.

For pre-ssh, stdout is treated as SSH config lines and incorporated into
the SSH config assembly (see below). A non-zero exit aborts the
connection (exit code 80). For post-ssh, stdout is ignored and a non-zero
exit produces a warning.

## SSH configuration

`virtdev-ssh` assembles its SSH configuration from four sources (highest
priority first):

1. Per-project pre-ssh trigger output
2. System pre-ssh trigger output
3. `~/.config/virtdev/projects/<name>/ssh_config`
4. `~/.config/virtdev/ssh_config`

The assembled config is written to a temporary file and passed via
`ssh -F`. The user's `~/.ssh/config` is intentionally excluded — virtdev
connects to untrusted virtual machines and dangerous global settings
(`ForwardAgent`, `ControlMaster`) should not leak in.

## Architecture

See `DESIGN.md` for the full architecture, threat model, locking model,
SSH hardening, and known limitations.

### Image hierarchy

```
system/                    sealed base (mode 444)
  system.qcow2             OS, bootloader, packages
  home.qcow2               /home/dev template
  nvram                    UEFI variable store
  generation               monotonic counter, bumped on reseal

projects/<name>/           per-project (writable deltas)
  system.qcow2  --backs--> system/system.qcow2
  home.qcow2    --backs--> system/home.qcow2
  nvram                    copy of system/nvram
  generation               must match system/generation to boot
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

Each virtual machine's hostname is set to the project name at boot
(via QEMU `fw_cfg`), so the guest prompt shows `dev@myproject`.

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
    nvram, generation               UEFI state, base generation
    port, monitor.sock, console.sock, passt.sock  runtime (while running)
    manifest                     optional project-local manifest
  backups/<project>/<date>/<time>/
    project, manifest, generation   metadata
    tree/                           user content

${VIRTDEV_CACHE}/                   (~/.cache/virtdev)
  virtdev.iso                       built ISO
  work/, profile/                   mkarchiso artifacts

~/.config/virtdev/
  ssh_config                          system-level SSH config for all projects
  triggers/
    pre-ssh, post-ssh                 system-level trigger scripts
  maintenance/
    provision                       auto-run by virtdev-maintain (dotfiles, tools)
    inventory                       before/after diff by virtdev-maintain
  projects/<name>/
    ssh_config                        per-project SSH config (overrides system)
    triggers/
      pre-ssh, post-ssh              per-project trigger scripts (override system)
    manifest                       canonical backup manifest (survives nuke)
    provision                         auto-run by virtdev-recreate
```

## License

GNU Affero General Public License v3.0 — see [LICENSE.AGPLv3](LICENSE.AGPLv3).
