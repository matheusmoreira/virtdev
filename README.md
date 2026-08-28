# virtdev

Per-project KVM/QEMU virtual machines for isolated development.

Each project gets its own Arch Linux virtual machine backed by a thin qcow2
delta over a shared sealed base. The isolation boundary is a hardware-assisted
hypervisor, not a namespace or permission system.

**Isolation scope:** project virtual machines **start fully
locked by default** — zone `none`, no network at all beyond your own SSH
session. passt blocks the guest→host-loopback path (`--map-host-loopback none`)
and its host-global-address mapping (`--map-guest-addr none`); a host-root
nftables egress filter, scoped to the machines' systemd slice cgroups, then
enforces a per-machine **zone**:

| zone   | guest can reach                        | host + LAN |
|--------|----------------------------------------|------------|
| `none` | nothing (just your SSH session)        | blocked    |
| `wan`  | the internet                           | blocked    |
| `lan`  | your local environment, no internet    | allowed    |
| `full` | the internet + your local environment  | allowed    |

`wan` is the usual working zone (package managers, Claude Code); `lan` is the
local-only zone (a LAN mirror or NAS, no internet); `full` is the explicit opt-out
of host isolation (host and LAN move together — the host is a LAN device). You can
also define **custom zones** that open a single host port — e.g. a host gdbserver
the guest drives — on top of a base, without opening the whole LAN/WAN (see
[Custom zones](#custom-zones)). The filter is **opt-in to install**: run `sudo
virtdev firewall apply` once (see One-time setup); until you do, `virtdev start`
refuses to launch (override with `--unfiltered`). A project's default zone comes
from its `zone` dotfile; `--zone` overrides it per launch.

## Getting started

### Requirements

- Arch Linux host, bash >= 5.3
- KVM-capable CPU, QEMU (`qemu-system-x86`), OVMF (`edk2-ovmf`)
- OpenSSH (`openssh`), passt, nftables, socat, jq, rsync, archiso

### Install

From the AUR (`virtdev-git`):

```
yay -S virtdev-git
```

From source — scripts auto-detect the layout, and `make` builds the
small private C helper `libexec/virtdev/virtdev-exchange` that `virtdev-maintain` requires
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

Install the host egress lockdown (root, once). Until this is applied,
`virtdev start` refuses to launch. It requires **lingering** enabled for your
user (`loginctl enable-linger "$USER"`) so the firewall's resident helpers run
boot-to-shutdown:

```bash
sudo virtdev firewall apply       # generate + load the nftables filter, install + start its units
virtdev firewall status           # 'active' once the lockdown is loaded (rootless)
```

`apply` derives the cgroup match from your own user, so run it as yourself, not as
bare root. Plain `virtdev firewall apply` (no `sudo`) **self-elevates** — it
re-runs itself under `sudo`, forwarding your `VIRTDEV_HOME` explicitly as
`--virtdev-home` (sudo strips the environment) — and is the simplest form; the
explicit `sudo virtdev firewall apply` above works too. The ruleset is
project-agnostic and the per-zone slices are shared,
so a project created later is covered immediately — no re-apply per project
(adding or editing a **custom zone** does need a re-apply, since its rules live in
the root ruleset). Set a project's default zone by writing a zone name — `none`,
`wan`, `lan`, `full`, or a custom zone — to
`~/.config/virtdev/projects/<name>/zone` (absent or invalid → `none`).

### Custom zones

Beyond the four built-ins you can define a **custom zone** that opens one or more
host ports on top of a base — to reach a service on the host (e.g. a gdbserver the
guest drives) without granting the whole LAN/WAN. Create a file at
`~/.config/virtdev/zones/<name>` (commit it to your dotfiles — solve once, reuse):

```
# ~/.config/virtdev/zones/gdb
base wan           # none | wan | lan | full
port 1234 tcp udp  # one or more; at least one protocol is required (tcp and/or udp)
```

The **base decides how much host the hole exposes.** Use `base none` or `base wan`
for a *per-port* hole: those bases deny the host by default, so the listed `port`s
are the only host access the guest gets. `base lan` and `base full` already grant
the host wholesale, so on those bases the `port` lines are redundant and the guest
reaches the **entire** host loopback, not just the listed ports — choose them only
when you intend full host access.

Then realize it (root — its rules live in the host ruleset) and launch into it:

```bash
sudo virtdev firewall apply        # validates + loads; re-run after any zone edit
virtdev start myproject --zone gdb
```

Inside the guest the host service is reachable at the default gateway (e.g.
`<gateway>:1234`, found with `ip route show default`). One exception: a `port 53`
hole won't reach the host's resolver when the host's resolver address is also the
guest's gateway — passt routes that address to its own DNS proxy instead of host
loopback. The zone is selected per launch (or as a project's `zone` default) and is
transient — start without `--zone gdb` and you are back to the project's zone. Zone names are lowercase
`[a-z0-9_]`, no dashes or dots. A custom zone is a **deliberate hole in host
isolation**: the untrusted guest gets whatever the host service permits (driving a
gdbserver is host code execution), so only open services you trust the project
with.

Removing a custom zone is the reverse: delete the file and re-`apply`. One caveat —
if you are removing the **last** host-hole zone while a machine is still running in
one, stop that machine first. `apply` refuses (exit 100) and names it, because the
guest's host-loopback access is opened at machine launch and only narrowed to the
declared port by the live ruleset; un-narrowing it under a running machine would
widen it to every host loopback port. Stop the named machine, then re-`apply`. (If
`apply` cannot reach your user manager to check for running machines, it fails closed
with exit 102 instead of guessing.)

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

Paths are lexical roots relative to `/home/dev/` in the guest. Absolute paths
and `..` components are rejected; trailing slashes are normalized. Blank lines
and lines beginning with `#` are ignored. Then:

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

Flags: `--no-backup`, `--snapshot <YYYY-MM-DD/HH-MM-SS>` (pin an existing
snapshot when resuming with `--no-backup`), `--no-restore`, `--no-provision`,
`--provision <path>`, `--yes`/`-y`, `--verbose`/`-v`.

### Base system maintenance

Update the sealed base (system packages, dotfiles, etc.):

```bash
virtdev maintain                  # copies base to staging, boots writable VM
virtdev ssh maintenance           # connect from another terminal
# ... perform maintenance inside the VM ...
sudo poweroff                     # triggers reseal prompt
```

The maintenance virtual machine runs in zone `wan`, not `none` — resealing runs
`pacman -Syu`, which needs the internet (the host and LAN stay blocked).

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

The host tools and guest control helpers are a matched contract. A base made by
an older installer lacks the strict SSH host-identity marker, so current
`start`, `maintain`, `recreate`, and `upgrade` refuse before launching or
changing data. There is no insecure bootstrap for this transition: make needed
backups with the previous virtdev version, then build the current ISO, install
and seal a new base, and recreate/restore projects. Detached projects carry
their own marker and must be migrated independently.

Because every coupled qcow2 delta depends on the exact current base bytes, a
reseal cannot safely leave a coupled project behind. Filtering options may
exclude detached projects only; otherwise `virtdev upgrade` fails before it
stops a VM or changes the base. Include and rebuild every coupled project, or
detach it before maintenance.

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
| `virtdev-maintain [flags]` | Boot sealed base for maintenance, reseal after confirmed guest poweroff (`--unfiltered` skips the egress lockdown) |
| `sudo virtdev-firewall apply` | Generate + load the host egress lockdown (root, one-time) |
| `virtdev-firewall status` | Print `active`/`inactive` for the lockdown (rootless) |

### Project lifecycle

| Command | Description |
|---------|-------------|
| `virtdev-create <project>` | Derive a project VM from the sealed base |
| `virtdev-start <project> [--zone <zone>] [--unfiltered] [port]` | Start VM as a systemd user service. `<zone>` is `none`/`wan`/`lan`/`full` or a custom zone; default is the project's `zone` file (else `none`); `--zone` overrides; `--unfiltered` skips the egress lockdown |
| `virtdev-stop <machine>` | ACPI shutdown with SIGTERM fallback (`machine` is a project or `maintenance`) |
| `virtdev-move <old-name> <new-name>` | Rename a project (must be stopped) |
| `virtdev-destroy [-y] <project>` | Delete a project VM (confirmation required) |
| `virtdev-detach [--in-place] [-y] <project>` | Convert delta images to standalone, removing base dependency |
| `virtdev-recreate [flags] <project>` | Backup, destroy, rebuild, provision, restore |
| `virtdev-upgrade [flags]` | Back up, maintain base, rebuild all projects |
| `virtdev-nuke` | Delete all virtdev data (confirmation required) |

### Access

| Command | Description |
|---------|-------------|
| `virtdev-ssh <project> [--client-option=<option>]... [-- [command...]]` | SSH into a running VM; client options and remote argv are separate |
| `virtdev-console <machine>` | Serial console (detach: Ctrl-]) |
| `virtdev-wait <project>` | Poll until SSH is available |
| `virtdev-transfer <project> <src> <dest>` | rsync files (prefix remote path with `:`) |
| `virtdev-list` | List projects with port, runtime state, zone, and generation (colored) |

### Inspection

| Command | Description |
|---------|-------------|
| `virtdev-status <machine>` | Print `running`, `stopped`, `starting`, `stopping`, or `unknown` |
| `virtdev-port <machine>` | Print SSH port of a running virtual machine |
| `virtdev-pid <machine>` | Print QEMU process ID |
| `virtdev-path <machine> [resource]` | Print a machine data/runtime resource path |
| `virtdev-disk <project>` | Show disk usage info |
| `virtdev-log [-f] <machine>` | Show journal logs (shorthand for journalctl) |
| `virtdev-monitor <machine>` | Attach to QEMU monitor |
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
| `VIRTDEV_INSTALL_DNS` | `9.9.9.9` (install-time IPv4 or IPv6 literal; `VIRTDEV_DNS` is a legacy alias) |
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
| `VIRTDEV_TRIGGER_TIMEOUT` | `10` (seconds per trigger) |
| `VIRTDEV_TRIGGER_KILL_AFTER` | `2` (seconds from TERM to KILL) |
| `VIRTDEV_BACKUP_MAX_BYTES` | `8589934592` (8 GiB archive and regular logical data; range 1–1099511627776) |
| `VIRTDEV_BACKUP_MAX_ENTRIES` | `200000` extracted paths, including implicit parents (range 1–10000000) |
| `VIRTDEV_BACKUP_TIMEOUT` | `3600` seconds total (range 1–86400) |
| `VIRTDEV_BACKUP_KILL_AFTER` | `5` seconds from TERM to KILL (range 1–60) |
| `VIRTDEV_RESTORE_MAX_BYTES` | `8589934592` (8 GiB regular logical data; range 1–1099511627776) |
| `VIRTDEV_RESTORE_MAX_ENTRIES` | `200000` snapshot-tree entries (range 1–10000000) |
| `VIRTDEV_RESTORE_TIMEOUT` | `3600` seconds total (range 1–86400) |
| `VIRTDEV_RESTORE_KILL_AFTER` | `5` seconds from TERM to KILL (range 1–60) |
| `VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES` | `65536` (per trigger) |
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
exit produces a warning. Each trigger has its own wall-clock and stdout
budget; timeout or overflow follows the same pre/post failure policy. Limits
are configurable within 1–3600 seconds, 1–60 seconds of TERM grace, and
1–1048576 output bytes. A trigger and its stdout reader share a supervised
process group; leaving background processes is a failure and terminates that
group. Triggers must not change process group, create a separate session, or
daemonize.

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

Every VM receives a host-generated, project-specific ed25519 host key through
QEMU fw_cfg. The guest uses it only from `/run`; disks retain no host private
key. The client pins the key to the exact alias `virtdev-<project>` in
project-local known-host state. Strict checking, alias, key algorithm,
public-key-only authentication, client identity, port, and disabled connection
sharing are fixed command-line policy shared by interactive ssh, polling,
rsync, backup, restore, and maintenance. Agent and GSSAPI credential forwarding
are disabled. User config cannot weaken those settings.

Use `virtdev ssh` for SSH connections. `virtdev-port` exposes the forwarded
number for integrations, but raw `ssh -p ...` omits project identity unless the
caller reproduces every fixed transport option.

Assembled config cannot set `IdentityFile`, `CertificateFile`, `IdentityAgent`,
`PKCS11Provider`, `SecurityKeyProvider`, or `Include`; these could add client
credentials outside `VIRTDEV_SSH_KEY` and are rejected before connection.

Repeatable client options use `--client-option=<one-token-option>` before the
remote delimiter. Remote command arguments follow `--` unchanged:

```bash
virtdev ssh myproject --client-option=-L3000:localhost:3000 --client-option=-N
virtdev ssh myproject -- printf '%s\n' '--literal-remote-argument'
```

Only bounded, self-contained forwarding/session options are accepted. Policy
options (`-F`, `-i`, `-p`, `-o`), credential forwarding (`-A`, `-K`),
backgrounding (`-f`), and connection-bypassing modes (`-G`, `-V`) are rejected.

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
  guest-contract           proven guest/host transport version

projects/<name>/           per-project (writable deltas)
  system.qcow2  --backs--> system/system.qcow2
  home.qcow2    --backs--> system/home.qcow2
  nvram                    copy of system/nvram
  generation               must match system/generation to boot
  guest-contract           retained when a project is detached
  ssh-host/                host key and exact-alias known-host state
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
(via QEMU `fw_cfg`), so the guest prompt shows `dev@myproject`. Project
names are restricted to `[a-zA-Z0-9_-]` and capped at the guest's 64-byte
`HOST_NAME_MAX`. Commands that create or launch a VM separately verify the
exact Unix-socket paths under the current `VIRTDEV_HOME`; relocating a store
cannot make its project identities invalid for management and recovery.

### Concurrency

Store mutations use a canonical-path-keyed lock outside `VIRTDEV_HOME`, so
`virtdev-nuke` cannot unlink the rendezvous it holds. ISO builds and nuke also
share a cache lock. Contention fails fast with exit 75 and prints the lock path
and holder PID.

## Data layout

```
${XDG_RUNTIME_DIR}/virtdev/locks/   (falls back to $XDG_STATE_HOME)
  store-<sha256>.lock                per-canonical-store rendezvous
  cache-<sha256>.lock                per-canonical-cache rendezvous

${VIRTDEV_HOME}/                    (~/.local/share/virtdev)
  lock                              compatibility lock for firewall coordination
  ssh/id, ssh/id.pub                SSH key pair
  system/                           sealed base (mode 444)
  maintenance/                      transient staging for virtdev-maintain
  projects/<name>/
    system.qcow2, home.qcow2       delta disks
    nvram, generation               UEFI state, base generation
    guest-contract                  guest/host SSH compatibility marker
    ssh-host/                        host-owned key and known-host state
    port, monitor.sock, qmp.sock, console.sock, network.sock  runtime (while running)
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
  zones/<name>                        custom firewall zone definition (base + port holes; needs `sudo virtdev firewall apply`)
  maintenance/
    provision                       auto-run by virtdev-maintain (dotfiles, tools)
    inventory                       before/after diff by virtdev-maintain
  projects/<name>/
    ssh_config                        per-project SSH config (overrides system)
    zone                              default network zone: none|wan|lan|full or a custom zone (default none)
    triggers/
      pre-ssh, post-ssh              per-project scripts (run after system hooks)
    manifest                       canonical backup manifest (survives nuke)
    provision                         auto-run by virtdev-recreate
```

An interrupted ISO build can leave privileged mounts below `work/`.
`virtdev iso` refuses to clean a mounted build tree; unmount the exact stale
path it reports, then rerun the command.

## License

GNU Affero General Public License v3.0 — see [LICENSE.AGPLv3](LICENSE.AGPLv3).
