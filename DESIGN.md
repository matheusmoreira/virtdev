# virtdev Design Document

## Purpose

`virtdev` is an automated Arch Linux ISO that installs a minimal headless
development VM on KVM/QEMU. The core motivation is hypervisor-level isolation
between JavaScript projects as a defense against npm supply chain attacks. Each
project gets its own thin qcow2 delta VM rather than relying on directory
separation or language-level sandboxing.

---

## Threat Model

The primary attack surface is npm (and similar language package registries).
Supply chain attacks in this space routinely exfiltrate credentials, read
source trees, and establish persistence. The mitigations available at the
language or OS level — sandboxed installs, permission systems, directory
separation — all share the same kernel and user session as the host. A
compromised package can break out of all of them.

Running each project in a separate KVM virtual machine raises the bar to a
hardware-assisted hypervisor escape, which is a qualitatively different and
much harder attack than escaping a namespace or a permission boundary.

The tradeoff accepted is operational overhead: virtual machines cost more to
create and manage than directories. `virtdev` exists to reduce that overhead to
the point where the isolation is practical for day-to-day development.

**Isolation scope:** the isolation virtdev provides is _host-and-inter-project_
— a compromised guest should not reach the host or other project guests.
**Exfiltration (outbound internet access) is not a goal.** Project guests
require internet egress (package managers, Claude Code's Anthropic API calls,
etc.), so outbound network access is intentionally unrestricted.

**Phase 1 residuals (documented openly):** virtdev uses passt as its network
backend (`start` and `maintain` paths) with both host-translation paths
disabled: `--map-host-loopback none` blocks the guest→host-loopback path
(the one the old SLIRP gateway address exposed), and `--map-guest-addr none`
blocks passt's host-global-address mapping. However, the following paths
remain reachable in Phase 1:

1. **guest→host via the host's real LAN IP / `0.0.0.0` bindings** (including
   the host's `sshd`, which binds `0.0.0.0:22`). This is plain NAT through
   passt — passt cannot filter by destination. Closing it requires a host-side
   nftables egress filter scoped to the virtual machine cgroup (a planned
   fast-follow; the passt/cgroup architecture here is explicitly designed to
   enable it). This applies to all protocols (TCP, UDP, ICMP) and both
   address families (IPv4 and IPv6).
2. **`install`-time guest→host**: the installer keeps SLIRP networking.
   Accepted: the installer runs only official Arch Linux signed packages
   (no AUR, no `makepkg`, no provisioning), so the threat window is very
   short and the network exposure is similar to any OS installation.
3. **Host-local-user access to socket files** (`passt.sock`, `monitor.sock`):
   mitigated by mode 0700 on the per-project directory; outside the primary
   hypervisor-escape threat model but documented for completeness.

---

## Architecture Overview

### Two-Disk Design

Every VM uses two separate qcow2 disk images:

- `vda` — system disk. Contains the OS, bootloader, and installed packages.
- `vdb` — home disk. Contains `/home/dev` and all project work.

Separating the disks enables independent lifecycle management: the system disk
can be updated or shared without touching project state, and the home disk can
be detached from one VM and attached to another. This split is foundational to
the inheritance and update strategies described below.

### Partition Layout

**vda (system)**

| Partition | Size     | Filesystem | Mount    | Notes                          |
|-----------|----------|------------|----------|--------------------------------|
| vda1      | 512 MiB  | fat32      | `/efi`   | ESP                            |
| vda2      | 1024 MiB | fat32      | `/boot`  | XBOOTLDR, GPT type EA00        |
| vda3      | remainder | ext4      | `/`      | Dynamic: 100% of remaining disk |

**vdb (home)**

| Partition | Size     | Filesystem | Mount    | Notes                          |
|-----------|----------|------------|----------|--------------------------------|
| vdb1      | remainder | ext4      | `/home`  | Dynamic: 100% of disk, LABEL=home |

The home partition is mounted by label (`LABEL=home`) rather than UUID. This
makes it portable: any qcow2 home disk labelled `home` can be attached to any
project VM without modifying fstab.

### Boot

- Bootloader: systemd-boot
- Boot entry is written to XBOOTLDR (`/boot/loader/entries/arch.conf`)
- XBOOTLDR partition type EA00 is set at partitioning time via `sgdisk`

### Networking

- Live environment (ISO): `systemd-networkd` + `systemd-resolved`, Quad9 DNS
- Installed system: same stack, with `UseDNS=false` in the `[DHCPv4]` section
  to suppress QEMU's broken DNS proxy; Quad9 configured explicitly via
  `systemd/resolved.conf.d/dns.conf`

### User

- Username: `dev`
- Passwordless sudo (`NOPASSWD: ALL`)
- All accounts locked (`passwd -l`) — no password-based login is possible
- SSH public key injected at install time via QEMU fw_cfg, installed to
  `/home/dev/.ssh/authorized_keys`

---

## Image Hierarchy and Inheritance

### Principle

qcow2 supports backing images: a child image records only the writes that
differ from its parent. This is the mechanism used to derive project VMs from
a sealed base without duplicating the full disk contents.

The architecture is intentionally flat: one sealed base, any number of project
VMs derived from it, no deeper chains. Each project VM is a single qcow2 delta
layer over the base on both disks.

**Note on backing file paths:** `qemu-img create -b` stores the absolute path
to the backing file inside the delta image. If `VIRTDEV_HOME` is moved or
renamed after project VMs have been created, all delta images will fail to
open. Recovery requires `qemu-img rebase` to update the stored paths.

**Note on backing file content:** qcow2 records only a path to the backing
file, not a checksum, generation counter, or any other integrity seal of its
content. At open time QEMU resolves the path, reads whatever file is there,
and serves the composed view. If the file behind the path has been replaced
between the delta's creation and its next open (the exact thing
`virtdev-maintain` does), QEMU will not detect it. The generation counter
described under "Base System Maintenance" is virtdev's own integrity seal
layered on top of qcow2 to close this gap.

### The Base Image

The base image is produced by `virtdev-install` followed by `virtdev-seal`.
After sealing, the images are marked read-only (mode 444) and live in
`${VIRTDEV_HOME}/system/`:

```
system/
  system.qcow2   (read-only)
  home.qcow2     (read-only)
  nvram          (read-only)
```

No project VM writes to these files. Project VMs hold delta images that record
divergences from the base.

### Project VMs

Each project VM created by `virtdev-create` holds:

```
projects/<name>/
  system.qcow2   (delta over system/system.qcow2)
  home.qcow2     (delta over system/home.qcow2)
  nvram          (per-project UEFI variable store copy)
  port           (SSH forwarding port, present while running)
  monitor.sock   (QEMU monitor socket, present while running)
  console.sock   (serial console socket, present while running)
  passt.sock     (passt network backend socket, present while running)
```

### System Disk Modes

The system disk can be operated in two modes, chosen per-VM at start time:

**Delta mode (default)**

The project's `system.qcow2` is a writable delta over the sealed base. The
guest can install packages, modify system files, and generally treat the system
disk as writable. Updates to the base image do not propagate to existing
project VMs automatically.

**Shared read-only mode**

The project VM opens the sealed `system/system.qcow2` directly, without a
writable delta layer. The guest mounts `/` read-only. Mutable system paths
(`/var`, `/tmp`, etc.) are handled via tmpfs, enabled by passing
`systemd.volatile=state` on the kernel command line.

In this mode:
- Writes to the system disk are not possible from within the VM
- An update to the base image is picked up on the next boot of any VM using
  this mode, with no migration or rebasing required
- The tradeoff is that `pacman -S` and similar operations cannot persist;
  all software provisioning must happen via the home disk or be baked into
  the base image

The base image is designed to support both modes without modification.
Shared read-only mode is opt-in; delta mode is the default.

**Note on `/etc/machine-id`:** in shared read-only mode, all VMs sharing the
same base will present the same machine ID. This is acceptable for development
use but worth knowing if any tool relies on it for namespacing.

**Note on unclean shutdown:** ext4 requires journal replay on unclean shutdown,
which needs write access. The base image must be cleanly shut down before
sealing. `virtdev-maintain` enforces this by requiring a clean
poweroff before resealing.

### Home Disk

The home disk always has a writable delta per project VM. The home disk is not
shared directly across VMs; home disk portability is achieved by the
`LABEL=home` fstab entry, which allows a home disk from one project to be
detached and attached to another.

---

## Base System Maintenance

`virtdev-maintain` boots the sealed base for maintenance:

1. Copies `system/` to a staging area, makes files writable
   (`cp --reflink=auto` for instant COW clones on btrfs/XFS)
2. Boots the staging images as a systemd user service
3. Runs the provision hook if present (non-fatal)
4. Takes inventory if present (captures diffable state for later comparison)
5. User performs maintenance in a separate terminal: `pacman -Syu`, etc.
6. User powers off the virtual machine: `sudo poweroff`
7. On clean exit, if inventory was captured: boots a second time,
   captures inventory again, shows a diff of what changed
8. User confirms reseal; `virtdev-exchange` atomically swaps `system/`
   and `maintenance/` via `renameat2(2)` with `RENAME_EXCHANGE`

The reseal commit point is the `renameat2` syscall — a single atomic
operation that swaps the two directory names. There is no intermediate
state where `system/` is missing or partially populated, not even under
SIGKILL or power loss. The generation counter increment and `chmod 444`
are applied to `maintenance/` *before* the exchange, so the swap is the
single commit point: a crash before it leaves the old `system/` intact,
and a crash after it leaves `system/` fully sealed — new images, correct
generation, and read-only permissions.

### Maintenance hooks

Two optional hooks live in `${XDG_CONFIG_HOME}/virtdev/maintenance/`:

- **`provision`** — runs inside the guest after SSH is up. Sets up
  dotfiles, tools, and other environment configuration that should be
  baked into the sealed base. Executed via `virtdev-ssh maintenance --
  bash -s < provision`. Non-fatal: a failure prints a warning and
  continues to the interactive session.

- **`inventory`** — runs inside the guest to capture diffable system
  state (e.g., `pacman -Q`, file trees). Executed twice: once before
  the interactive session (Boot 1) and once via a second boot after
  the user powers off. The diff of the two captures is shown before
  the reseal prompt. Non-fatal: if the hook is absent or fails, the
  second boot and diff are skipped entirely.

Both hooks can be suppressed per-invocation: `--no-provision`,
`--no-inventory`.

After resealing:
- Project VMs in shared read-only mode pick up changes on next boot automatically
- Project VMs in delta mode do not pick up changes; they can be rebuilt via
  `virtdev-destroy` + `virtdev-create` + provision script

**Warning:** after a reseal, existing delta-mode project VMs hold deltas
created against the old base content. qcow2 does not validate backing file
content identity — QEMU would silently compose the delta against the new
base, which may produce filesystem corruption. `virtdev-start` detects this
via a generation counter (`system/generation` vs `projects/<name>/generation`)
and refuses to boot a project VM whose generation does not match the current
base. Always destroy and recreate delta-mode project VMs after resealing.
Detached projects (see `virtdev-detach`) are exempt — their standalone
images have no backing file dependency and `virtdev-start` skips the
generation check for them.

**Note on NVRAM:** each project VM owns a copy of `nvram` taken from
`system/nvram` at `virtdev-create` time. A subsequent `virtdev-maintain`
can update `system/nvram`, but project NVRAMs are not refreshed — they
continue to hold their original copy. This is intentional for UEFI
variable state (boot entry selection, secure-boot variables on hosts that
use them), which should be per-VM rather than inherited; but it does
mean an NVRAM-level change made during maintenance (e.g. a new default
boot entry in systemd-boot) is only picked up by projects on
destroy-and-recreate, not by a plain restart. In practice this is a
non-issue for the current headless configuration, where nothing writes
to NVRAM after install.

---

## Provisioning

Project VMs are designed to be expendable. The intended workflow is:

1. `virtdev-create <project>` — derive a new VM from the sealed base
2. `virtdev-start <project>` — start the VM
3. Run a user-supplied provision script via `virtdev-ssh` — install
   project-specific tools, clone repos, set up dotfiles
4. Develop

If the VM accumulates unwanted state or needs to pick up a base system update,
the correct response is `virtdev-recreate <project>`, which orchestrates
backup → stop → destroy → create → start → wait → provision → restore in one
command. The provision script lives at
`~/.config/virtdev/projects/<name>/provision` (or is passed explicitly with
`virtdev-recreate --provision <path>`) and is invoked via
`virtdev-ssh <name> -- bash -s` on the fresh VM. The provision script makes the
destroy-recreate cycle fast and repeatable.

Dotfiles are not a special case in this model. A symlink farm applied by a
Makefile in the provision script is the recommended pattern. Intermediate qcow2
layers for dotfiles add chain depth for no meaningful benefit unless setup is
slow enough to be worth amortizing, which a symlink farm is not.

---

## SSH Configuration

The installed system runs a hardened `sshd`:

- ed25519 host key only
- Pubkey authentication only; password, keyboard-interactive, GSSAPI,
  Kerberos, and host-based authentication all disabled
- `AuthenticationMethods publickey`
- CBC ciphers disabled (`-*-cbc`)
- NIST ECDH kex algorithms removed
- Weak MACs removed
- `AllowUsers dev`
- `AcceptEnv VIRTDEV_*` — allows the host to set `VIRTDEV_*` environment
  variables in the guest session (used by pre-ssh triggers to pass
  per-session context like socket paths)
- `StreamLocalBindUnlink yes` — removes stale unix socket files before
  binding `RemoteForward` sockets (defense in depth for crash recovery)
- `PermitRootLogin no`
- `UsePAM yes` (required on Arch)
- Passes ssh-audit with all green (verified 2026-04-02; re-verify after
  adding `AcceptEnv` and `StreamLocalBindUnlink`)

The same `sshd_config` is used in both the live ISO environment and the
installed system.

Client-side, `virtdev-ssh` assembles an SSH config from up to four
sources (per-project trigger output, system trigger output, per-project
static config, system static config) and passes it via `ssh -F`. The
user's `~/.ssh/config` is intentionally excluded — virtdev connects to
untrusted virtual machines, and dangerous global settings
(`ForwardAgent`, `ControlMaster`) should not leak into the connection.

Other host-to-VM SSH invocations (`virtdev-wait`, `virtdev-maintain`,
`virtdev-transfer`, `virtdev-backup`, `virtdev-restore`) pass SSH
options directly via command-line flags.

All host-to-VM connections pass
`-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`. The
host key changes on every base reseal and every project recreate, so
a persistent `known_hosts` entry would produce a host-key-mismatch
warning on every legitimate operation. The SSH forward is bound to
loopback only (passt `-t 127.0.0.1/<port>:22`), so the man-in-the-middle
attacks that `StrictHostKeyChecking` defends against do not apply.

**Serial console autologin:** the serial console (`console.sock`)
auto-logs in as `dev` via a systemd drop-in on `serial-getty@ttyS0`.
This provides emergency access when SSH is unavailable (e.g., broken
networking or sshd misconfiguration inside the guest). The socket is
host-local and requires `socat` to attach, so autologin does not
weaken the security boundary.

---

## VM Runtime

Project VMs run as transient systemd user services:

```
systemd-run --user --unit=virtdev-<project> -- qemu-system-x86_64 ...
```

Because VMs are `--user` units, they live under the user's systemd manager.
Without lingering enabled (`loginctl enable-linger`), systemd tears down
the user manager — and every unit it owns — when the last login session
ends. An SSH disconnect, a closed terminal, or a network drop kills every
running VM. `virtdev-start` warns when lingering is not enabled.

QEMU flags of note:

- `-enable-kvm -cpu host` — hardware-assisted virtualisation
- `-machine q35` — modern PCIe machine type
- `-drive if=pflash ...` — OVMF firmware; OVMF_CODE read-only, per-project NVRAM copy writable
- `-netdev stream,id=net0,server=off,addr.type=unix,addr.path=<passt.sock>` — connects QEMU to the
  passt network backend via a UNIX socket. passt is started by `virtdev-netexec` (the exec-shim)
  before QEMU, with host-translation paths disabled (`--map-host-loopback none`,
  `--map-guest-addr none`) and a loopback-only SSH forward (`-t 127.0.0.1/<port>:22`).
  `virtdev-install` keeps the original `-netdev user` (SLIRP) backend.
- `-fw_cfg name=opt/virtdev/project,string=<name>` — injects the project name into the guest via QEMU firmware configuration; used for hostname setting
- `-fw_cfg name=opt/virtdev/ssh_key,file=<path>` — SSH public key (install time)
- `-fw_cfg name=opt/virtdev/timezone,string=<tz>` — timezone (install time)
- `-fw_cfg name=opt/virtdev/locale,string=<locale>` — locale (install time)
- `-fw_cfg name=opt/virtdev/keymap,string=<keymap>` — console keymap (install time)
- `-fw_cfg name=opt/virtdev/dns,string=<ip>` — DNS server (install time)
- `-fw_cfg name=opt/virtdev/packages,file=<path>` — extra packages (install time, optional)
- `-fw_cfg name=opt/virtdev/script,file=<path>` — custom install script (install time, optional)
- `-fw_cfg name=opt/virtdev/inventory,file=<path>` — user inventory script (install time, optional)
- `-device virtio-rng-pci` — entropy for the guest
- `-device virtio-serial` + `-device virtserialport` — progress channel (install time)
- `-virtfs local,...` — 9p pacman cache sharing (install and maintenance)
- `-display none` — headless
- `-chardev socket ... -monitor` — QEMU monitor via Unix socket
- `-chardev socket ... -serial` — serial console via Unix socket

Stopping a VM sends `system_powerdown` via the monitor socket (ACPI power
button), waits for the systemd unit to exit, and falls back to SIGTERM if the
guest does not halt within the configured timeout.

The monitor write is unidirectional (`socat -u`) so a guest that receives the
ACPI event but fails to act on it — wedged kernel, masked `poweroff.target` —
cannot cause `virtdev-stop` to hang waiting for QEMU to close the socket.
`VIRTDEV_STOP_TIMEOUT` bounds the is-active polling loop, and SIGTERM is
always reachable.

The paragraph above is the foreground `virtdev-stop` path. A virtual machine
can also stop without a foreground `virtdev-stop` — a guest-initiated
`poweroff`, or an external `systemctl --user stop virtdev-<project>`. In that
case systemd runs the unit's `ExecStop` hook, which is
`virtdev-stop --acpi-only <project>`: a lock-free, guard-free mode that sends
one best-effort ACPI `system_powerdown` and exits 0 without touching the port
file or sockets. It runs lock-free because the hook may fire while a foreground
`virtdev-stop` already holds the lock, and guard-free because systemd runs
`ExecStop` once the unit is already `deactivating`, where an is-active guard
would always fail. Escalation on this path is driven by systemd's own
`TimeoutStopSec` (`DefaultTimeoutStopSec`, ~90s) rather than
`VIRTDEV_STOP_TIMEOUT`, because the transient unit is created without an
explicit `TimeoutStopSec`. Port and socket cleanup is deferred to the next
`virtdev-start` sweep or a later foreground `virtdev-stop` (see Port
Allocation).

The transient unit is **not** launched with `--collect`. Leaving the default
`CollectMode=inactive` in place means that a failed unit persists until
`systemctl reset-failed` is called, so `virtdev-stop` can reliably query
`ExecMainStatus` and `ActiveState` after the wait completes. `virtdev-stop`
reports the QEMU exit status alongside the stop confirmation (`0` for a
clean guest poweroff, `143` for a SIGTERM fallback, etc.) and asserts that
the unit has reached a terminal state (`inactive` or `failed`) before
removing sockets. `virtdev-start` calls `reset-failed` before `systemd-run`
to clear any residual state from a previous failed start.

---

## Concurrency and Locking

Every mutating command takes an exclusive `flock(2)` on
`${VIRTDEV_HOME}/lock`, held for the lifetime of the script via fd 9 and
released automatically on exit. The lock is visible — intentionally not
hidden under a dotfile — and contains the PID of the current holder:

```
$ cat ${VIRTDEV_HOME}/lock
12345
```

On contention, `flock -n` fails immediately rather than queueing and the
script exits 75 (BSD `EX_TEMPFAIL` — temporary failure, retry possible);
this is uniform across every locking script. The user sees the lock-file
path and holder PID and can inspect with their own tools (`ps`,
`/proc/12345/cmdline`, `systemctl --user status`). If the holder's
`/proc/<pid>/cmdline` matches `virtdev-maintain`, the error message
specifically points at the maintenance VM, since a maintenance session can
hold the lock for the duration of a `pacman -Syu` or similar long
operation and a generic "operation in progress" is unhelpful in that case.

The lock acquisition logic is factored into `lib/virtdev/lock`. Two
public entry points cover the observed flavors:

- `lock_acquire` — used by every locking script except `virtdev-maintain`.
  When the holder is also `virtdev-maintain`, prints the "base system
  maintenance is in progress" diagnostic.
- `lock_acquire_for_maintain` — used only by `virtdev-maintain`. When
  the holder is also `virtdev-maintain`, prints "another virtdev-maintain
  is already running" instead, since the user invoked `maintain`
  expecting a fresh session.

`virtdev-stop`'s special case for the maintenance project (skip the
lock entirely so `virtdev-stop maintenance` can still abort a stuck
session) lives at the call site:

```bash
if [[ "${project}" != "maintenance" ]]; then
  lock_acquire
fi
```

The library does not reach into the consumer's `${project}` variable;
the guard is one line and depends on the script's own state.

**Commands that take the lock** (serialized against each other):

- `virtdev-install`, `virtdev-seal`, `virtdev-maintain`
- `virtdev-create`, `virtdev-start`, `virtdev-stop`, `virtdev-destroy`, `virtdev-detach`, `virtdev-move`
- `virtdev-nuke`

**Commands that do not take the lock** (read-only or ISO-level):

- `virtdev-list`, `virtdev-ssh`, `virtdev-wait`, `virtdev-console`
- `virtdev-transfer`, `virtdev-key`, `virtdev-iso`
- `virtdev-backup`, `virtdev-restore`, `virtdev-recreate`, `virtdev-upgrade`

`virtdev-start` is the one special case: it holds the lock until
`systemctl --user is-active <unit>` returns true for the transient unit,
with a 5-second deadline. `systemd-run` returns as soon as the unit is
queued, which is before systemd has transitioned it from `activating` to
`active`; if `virtdev-start` released the lock at that instant, another
virtdev command could take the lock and its own `is-active` check would
falsely conclude the VM was not running. Holding until the unit is
detectable to systemd makes the systemd unit state the authoritative
"is this VM running" signal once the lock is released.

`virtdev-maintain` holds the lock for the entire maintenance session,
which may last hours. This is intentional: during maintenance the base
images are being modified, and any concurrent `virtdev-create` or
`virtdev-start` would read an inconsistent view. The lock converts the
existing "refuse if any VMs are running" check into a genuine mutual
exclusion with all other mutating operations.

`virtdev-backup` and `virtdev-restore` take no lock, matching
`virtdev-transfer`'s precedent. Both operate as SSH-level read/write
into the running guest, produce only append-only output under
`${VIRTDEV_HOME}/backups/`, and never modify shared virtdev state
(base images, project trees, ports). Dangerous cross-project
interactions are prevented by existing preconditions elsewhere:
`virtdev-maintain` refuses when any VM is running, `virtdev-destroy`
and `virtdev-nuke` refuse when the target VM is running, and backup
requires a running VM — so backup and maintain are mutually exclusive
without the lock. Concurrent same-project backup at the same second
is blocked by `mkdir` EEXIST on the per-second partial directory.

`virtdev-recreate` also takes no top-level lock. It composes the
existing primitives — `virtdev-backup`, `virtdev-stop`,
`virtdev-destroy --yes`, `virtdev-create`, `virtdev-start`,
`virtdev-wait`, an optional provision script, and
`virtdev-restore` — and each subcommand it spawns acquires the
lock as it needs to. Holding a top-level lock for the chain's
full duration (potentially many minutes during the rsync transfers)
would block unrelated operations across all projects for no
benefit. The cost is small inter-step race windows where another
virtdev script could squeeze in; the snapshot taken in step 1 is
the durable artifact across all realistic failures, so a race that
breaks a later step still leaves the user with recoverable state.
The one scenario where recreate's no-lock model loses data is
concurrent `virtdev-nuke`, which wipes everything under
`${VIRTDEV_HOME}` including `backups/` — a documented "nuke means
nuke" outcome rather than a recreate bug. `virtdev-destroy`
exposes a `--yes` flag for recreate and other scripted callers
(bulk cleanup loops, pipelines); the type-the-name confirmation
is moved to the recreate top-level so the user is asked once.

---

## Implementation: Shared Library System

`bin/virtdev-*` are the entry points; cross-cutting helpers used by
more than one entry point live in `lib/virtdev/*` and are sourced
into the script's shell at start-up rather than reimplemented per-script.
This is mechanical deduplication of identical boilerplate, not an
extension point: the libraries are internal-only and have no stable API.

The mechanism is bash 5.2's `source -p <colon-search-path> <name>`,
which lets a script source a library by name without computing or
hardcoding its path. Each script in `bin/` opens with a 2-line
bootstrap that sources `lib/virtdev/import`, which provides
`virtdev_library_directory`, `virtdev_bin_directory`,
`virtdev_loaded_libraries`, and the `import()` function. The script
then issues `import` calls for the libraries it uses.

The same `<bin>/../lib/virtdev` relative path resolves correctly for
both the dev tree (`~/dev/virtdev/bin → ~/dev/virtdev/lib/virtdev`)
and the pacman-installed package (`/usr/bin → /usr/lib/virtdev`),
because `readlink -f` follows symlinks and normalises to the script's
actual location. PKGBUILD installs `lib/virtdev/*` as a sibling of
`/usr/bin/`, mode 644, and declares `bash>=5.2` in `depends`.

### Current libraries

| Library | Purpose | Reserved exit codes |
|---------|---------|---------------------|
| `import` | bootstrap module sourced by every script; provides `virtdev_library_directory`, `virtdev_bin_directory`, `virtdev_loaded_libraries`, and `import()` | none |
| `error` | terminal failure helper used by every script (`error <code>` with message via stdin/heredoc) | none (caller-supplied) |
| `validate` | input validation (`validate_project_name`) | 2 |
| `arguments` | declarative flag parsing and usage generation (`arguments_parse`, `arguments_usage`); universal `--help` and `--color` handling | 64 |
| `lock` | exclusive `flock(2)` acquisition on `${VIRTDEV_HOME}/lock`, with maintain-aware diagnostics | 75 |
| `ssh` | SSH key validation and connection helpers (`ssh_key_validate`, `ssh_rsync_command`, `ssh_poll_until_ready`) | 77, 78 |
| `snapshot` | enumerate, count, and select virtdev-backup snapshot directories (`snapshot_directory`, `snapshot_list*`, `snapshot_count`, `snapshot_any`, `snapshot_latest`, `snapshot_validate_format`) | 79 |
| `trigger` | run user-supplied trigger scripts at lifecycle points (`trigger_fire`); discovers system and per-project triggers, captures stdout via namerefs | 80 |
| `port` | SSH forwarding port file reading and validation (`port_require`, `port_read_lenient`, `port_in_use`) | 81 |
| `manifest` | resolve and validate backup manifest files (`manifest_resolve`, `manifest_has_entries`) | none (caller-supplied) |
| `project` | enumerate and query project state (`project_list`, `project_require`, `project_is_running`, `project_load_running_state`, `project_is_outdated`, `project_is_detached`, `generation_read`, `generation_read_lenient`) | 3, 82 |
| `passt` | passt network backend constructor helpers (`passt_command`, `passt_socket_clean`); single source of truth for passt flags. The forward-port bind race is detected via `port_in_use`, not a passt helper | 83, 84, 85, 86 |
| `confirm` | interactive confirmation prompts (`confirm_word`, `confirm_proceed`) | none (caller-supplied) |
| `terminal` | terminal-aware output via terminfo/tput (`terminal_init`, `terminal_write`, `terminal` array); lazy-inits on first `terminal_write` call using the color mode from `arguments_parse` | none |

Libraries are self-contained: each imports its own dependencies
(e.g., `validate` imports `error` because it calls `error()` on
invalid input) and self-defaults the env vars it reads (e.g., `lock`
defaults `VIRTDEV_HOME`). The bootstrap's idempotency guard makes
redundant imports harmless. Library-owned exit codes are reserved by
the library and documented in its header; consumers do not override
them, so the same error condition produces the same exit code in
every script.

The full discipline rules (no top-level side effects, function
naming convention, `local` everywhere, `readonly` for true
constants only, header comment format) are documented in
`CLAUDE.md`.

---

## Port Allocation

SSH forwarding ports are assigned at virtual-machine start time and recorded
in `projects/<name>/port` while the unit is running. A foreground
`virtdev-stop` removes the port file (and the per-project sockets) once the
unit reaches a terminal state, and `virtdev-start`'s cleanup-on-failure trap
removes it on failed activation. A guest-initiated `poweroff` or an external
`systemctl --user stop`, however, stops the unit through the `ExecStop`
`--acpi-only` hook, which deliberately skips that cleanup (see Stopping a VM),
so the port file can linger past an inactive unit until it is swept.

The port file is therefore the running signal only *while the unit is
active*: every consumer (`virtdev-ssh`, `virtdev-port`, `virtdev-list`) checks
the systemd unit's active state first and reads the port only once that
confirms the virtual machine is running. A port file left behind by the
deferred-cleanup path is harmless stale state — the next `virtdev-start`
overwrites it and sweeps stale sockets, and a foreground `virtdev-stop`
removes it. Auto-assignment finds the lowest port >= 2222 not currently bound
on the host. Explicit port assignment is
supported via `virtdev-start <project> <port>`; `virtdev-start`
verifies the port is free before launching QEMU.

`virtdev-maintain` hardcodes its forwarding port to 2222, the same
value the auto-assignment loop starts from. This is safe because
`virtdev-maintain` holds the exclusive virtdev lock and refuses to
run while any project VM is active, so no project can hold 2222
during a maintenance session.

---

## Command Reference

| Command            | Description                                                  |
|--------------------|--------------------------------------------------------------|
| `virtdev-key`      | Generate ed25519 key pair for VM authentication              |
| `virtdev-iso`      | Build the Arch Linux installation ISO via mkarchiso          |
| `virtdev-install`  | Boot ISO in QEMU, install base system to fresh qcow2 disks   |
| `virtdev-seal`     | Promote installation images to read-only sealed base         |
| `virtdev-maintain` | Boot sealed base for maintenance, reseal after poweroff       |
| `virtdev-move`     | Rename a project (directory rename, backups, markers)         |
| `virtdev-create`   | Derive a project VM from the sealed base                     |
| `virtdev-start`    | Start a project VM as a transient systemd user service; assigns SSH port |
| `virtdev-stop`     | Clean ACPI shutdown; SIGTERM fallback                        |
| `virtdev-ssh`      | SSH into a running project VM as dev; fires pre/post-ssh triggers, assembles hierarchical SSH config |
| `virtdev-transfer` | Copy files between host and VM via rsync over SSH            |
| `virtdev-console`  | Attach to the serial console via socat                       |
| `virtdev-wait`     | Poll until SSH is accepting connections post-start            |
| `virtdev-list`     | List all projects with port, status, and generation          |
| `virtdev-status`   | Print `running` or `stopped` for a project                   |
| `virtdev-port`     | Print the SSH port of a running project VM                   |
| `virtdev-pid`      | Print the QEMU process ID of a running project VM            |
| `virtdev-path`     | Print the path to a project resource                         |
| `virtdev-disk`     | Show disk usage information for a project VM                 |
| `virtdev-log`      | Show journal logs for a project's systemd unit               |
| `virtdev-monitor`  | Attach to the QEMU monitor of a running project VM           |
| `virtdev-generation` | Print the base or project generation counter               |
| `virtdev-stale`    | List projects with stale base generation                     |
| `virtdev-destroy`  | Delete a project VM and its disks (requires typing name)     |
| `virtdev-nuke`     | Delete all virtdev data (requires typing "nuke")             |
| `virtdev-backup`   | Snapshot user-curated guest-side paths to a host-side timestamped directory |
| `virtdev-restore`  | Restore a snapshot into a running project VM                |
| `virtdev-recreate` | Backup, destroy, recreate, optionally provision, and restore in one command |
| `virtdev-upgrade`  | Back up all projects, maintain the base, rebuild all projects on the new base |
| `virtdev-detach`   | Convert a project's delta images into standalone images, removing base dependency |

---

## Environment Variables

All scripts respect these variables:

| Variable                  | Default                                         |
|---------------------------|-------------------------------------------------|
| `VIRTDEV_HOME`            | `${XDG_DATA_HOME:-~/.local/share}/virtdev`      |
| `VIRTDEV_SSH_KEY`         | `${VIRTDEV_HOME}/ssh/id`                        |
| `VIRTDEV_CACHE`           | `${XDG_CACHE_HOME:-~/.cache}/virtdev`           |
| `VIRTDEV_TIMEZONE`        | host timezone (UTC fallback)                    |
| `VIRTDEV_LOCALE`          | host locale (`en_US.UTF-8` fallback)            |
| `VIRTDEV_KEYMAP`          | host keymap (`us` fallback)                     |
| `VIRTDEV_DNS`             | `9.9.9.9`                                       |
| `VIRTDEV_PACKAGES`        | (none)                                          |
| `VIRTDEV_SCRIPT`          | (none)                                          |
| `VIRTDEV_INVENTORY`       | (none)                                          |
| `VIRTDEV_ISO_PROFILE`     | Auto-detected from script location              |
| `VIRTDEV_ISO`             | `${VIRTDEV_CACHE}/virtdev.iso`                  |
| `VIRTDEV_SYSTEM_DISK_SIZE`| `24G`                                           |
| `VIRTDEV_HOME_DISK_SIZE`  | `48G`                                           |
| `VIRTDEV_VM_MEMORY`       | `4096`                                          |
| `VIRTDEV_VM_CPUS`         | `4`                                             |
| `VIRTDEV_STOP_TIMEOUT`    | `60`                                            |
| `VIRTDEV_WAIT_TIMEOUT`    | `120`                                           |
| `OVMF_CODE`               | `/usr/share/edk2/x64/OVMF_CODE.4m.fd`          |
| `OVMF_VARS`               | `/usr/share/edk2/x64/OVMF_VARS.4m.fd`          |

---

## Data Layout

```
${VIRTDEV_HOME}/
  lock                  flock(2) target; contains PID of current holder
  ssh/
    id                  ed25519 private key (mode 600)
    id.pub              ed25519 public key (injected at install time via fw_cfg)
  system/               sealed read-only base images (mode 444)
    system.qcow2
    home.qcow2
    nvram
    generation          monotonic counter, incremented by each reseal
  installation/         transient; present between virtdev-install and virtdev-seal
    system.qcow2
    home.qcow2
    nvram
  maintenance/          transient; present while virtdev-maintain is active
    system.qcow2
    home.qcow2
    nvram
  projects/maintenance/  transient maintenance virtual machine runtime directory (mode 0700)
    port                 hardcoded port 2222
    monitor.sock         QEMU monitor socket (present while maintenance virtual machine is running)
    console.sock         serial console socket (present while maintenance virtual machine is running)
    passt.sock           passt network backend socket (present while maintenance virtual machine is running)
  projects/
    <name>/
      system.qcow2      delta over system/system.qcow2 (or absent in ro mode)
      home.qcow2        delta over system/home.qcow2
      nvram             per-project UEFI variable store
      generation        copy of system/generation at create time
      port              SSH forwarding port (present while running)
      monitor.sock      QEMU monitor socket (present while running)
      console.sock      serial console socket (present while running)
      passt.sock        passt network backend socket (present while running)
      manifest       optional; user-curated manifest for virtdev-backup
                        (falls back to
                        ${XDG_CONFIG_HOME:-~/.config}/virtdev/projects/<name>/manifest
                        if absent here - config path survives virtdev-nuke)
  backups/
    <project>/
      <YYYY-MM-DD>/
        <HH-MM-SS>/
          project       source project name; virtdev-restore refuses
                        to apply a snapshot to a different project
          manifest   copy of projects/<project>/manifest at backup time
          generation    base generation at backup time (may be empty)
          tree/         user content, rsync-preserved
        <HH-MM-SS>.partial/  transient; present during an in-flight backup

${XDG_CACHE_HOME:-~/.cache}/virtdev/
  virtdev.iso
  work/                 mkarchiso work tree (cleared on each build)
  profile/              assembled ISO profile (cleared on each build)

${XDG_CONFIG_HOME:-~/.config}/virtdev/
  ssh_config              system-level SSH config for all virtdev-ssh
                          connections. Lowest-priority static source.
  triggers/
    pre-ssh               system-level trigger fired before virtdev-ssh
                          connects. Stdout is SSH config lines.
    post-ssh              system-level trigger fired after virtdev-ssh
                          disconnects. Used for cleanup.
  maintenance/
    provision           optional bash script run by virtdev-maintain
                        after SSH is up (before the interactive session).
                        Sets up dotfiles, tools, etc. for the sealed base.
                        Non-fatal; suppressible with --no-provision.
    inventory           optional bash script run by virtdev-maintain
                        to capture diffable system state (e.g., pacman -Q).
                        Executed twice: before the interactive session and
                        via a second boot after poweroff. The diff is shown
                        before the reseal prompt. Non-fatal; suppressible
                        with --no-inventory.
  projects/
    <name>/
      ssh_config          per-project SSH config. Overrides system-level.
      triggers/
        pre-ssh           per-project pre-ssh trigger (overrides system)
        post-ssh          per-project post-ssh trigger (overrides system)
      manifest       user-curated manifest, dotfile-friendly fallback;
                        used by virtdev-backup when a project-local
                        manifest is absent. Survives virtdev-nuke.
      provision         optional bash script run by virtdev-recreate
                        between start/wait and restore via
                        `virtdev-ssh <name> -- bash -s < provision`.
                        XDG-only (project-local would be wiped by
                        destroy before provision runs). Survives
                        virtdev-nuke. Overridable per-invocation
                        with `virtdev-recreate --provision <path>`.
```

`virtdev-backup` consults `projects/<name>/manifest` under
`${VIRTDEV_HOME}` first, falling back to the same relative path
under `${XDG_CONFIG_HOME}`. The first existing file wins.
Project-local wins because it is the more specific location; a
user who wants to experiment with a different manifest for one
VM can drop it there without touching dotfiles, and the edit
disappears with the VM on `virtdev-destroy` or `virtdev-nuke`.
Every backup run echoes the loaded manifest path to stderr so
there is no silent shadowing when both files exist.

---

## Known Limitations and Open Questions

- **Silent backing file divergence after maintenance.** After
  `virtdev-maintain` reseals the base, existing delta-mode project VMs hold
  deltas that were created against the old base content but whose backing file
  path now resolves to the new base. qcow2 does not detect this — QEMU
  silently composes the delta against the new content. The composed filesystem
  may be inconsistent if the delta contains any writes: ext4 metadata in
  the delta (block bitmaps, inode tables, extent trees, journal) references
  specific sector contents in the base that may have moved or changed during
  `pacman -Syu`, which can produce dangling references, fsck errors, or in
  the worst case a kernel panic at mount. The pacman database is a common
  trigger — if the project VM ever ran `pacman`, its database in the delta
  will disagree with the package files served from the updated base.
  **Mitigated:** a generation counter written by `virtdev-seal` and incremented
  by `virtdev-maintain` is recorded at `virtdev-create` time and checked at
  `virtdev-start` time. A mismatch causes a hard refusal with an actionable
  error message. The refusal is the right default even though it is
  technically over-broad: a project VM that has never written to its system
  disk has an empty delta and is functionally equivalent to a fresh
  `virtdev-create` against the new base, and any sectors the project did
  write are stored in the delta and returned as-is regardless of what the
  backing file contains at that offset. The risk is specifically the
  *intersection* of unmodified-by-project sectors that *did* change in the
  base — and there is no cheap way to compute that intersection at start
  time, so the generation mismatch is treated as conclusive.

- **System disk rebase after base update.** Project VMs in delta mode do not
  automatically pick up base system updates. The recommended path is destroy
  and recreate. Unsafe rebase (`qemu-img rebase -u`) is technically possible
  for VMs with minimal system-level writes, but is not officially supported and
  has no tooling. An alternative is `virtdev-detach`, which converts the
  project to standalone images — this preserves the current system state but
  requires the project to be updated independently going forward.

  `virtdev-detach` operates in two modes: in-place rebase (fast, uses
  `qemu-img rebase -b ""`) and convert-then-swap (default, produces a
  clean standalone image via `qemu-img convert`). The convert-then-swap
  mode has signal-trap protection and auto-recovery: signals are blocked
  during the critical rename sequence, and `.bak` files left by an
  interrupted swap are detected and rolled back on the next invocation.

- **Read-only root setup in base image.** The `systemd.volatile=state` kernel
  parameter is the intended mechanism. The base image configuration for this
  mode has not yet been implemented or tested end-to-end.

- **Home disk portability tooling.** The architecture supports detaching a home
  disk from one project and attaching it to another (LABEL=home fstab). No
  commands implement this yet.

- **Destroy-recreate loses state in delta-mode project VMs.** After
  `virtdev-maintain` reseals the base, delta-mode project VMs must be
  destroyed and recreated to absorb the update. Home-disk state that
  is not reproduced by a user-supplied provision script is preserved
  across this cycle by `virtdev-recreate`, which chains
  `backup + stop + destroy + create + start + wait + provision +
  restore` into a single command. The chain consults a per-project
  `manifest` (project-local first, XDG config fallback) for
  what to back up, and an optional XDG provision script
  (`~/.config/virtdev/projects/<name>/provision`, overridable with
  `--provision <path>`) for what to re-install. Each chain step is
  fail-fast with a step-specific recovery hint; the snapshot from
  step 1 is preserved across all failures except concurrent
  `virtdev-nuke`. Ephemeral projects without a manifest opt
  out via `virtdev-recreate --no-backup`.

- **Backup system scope.** `virtdev-backup` and `virtdev-restore` are
  intentionally simple file-list rsync wrappers. `virtdev-backup`
  hard-links unchanged files from the previous snapshot via rsync
  `--link-dest`, cheaply deduplicating identical content across
  snapshots. Not planned: compression, encryption at rest, automated
  retention or rotation policy, cross-project restore, system-disk
  backup, or glob/brace expansion in manifests. Per `DESIGN.md`'s threat model the host is trusted, so
  encryption adds complexity without matching a real adversary. The
  manifest is literal (`--files-from`) to keep the contract auditable.

- **Network isolation Phase 1 residuals.** The passt backend (`start` and
  `maintain` paths) blocks guest→host via passt's two translation shortcuts
  (loopback-via-gateway and host-global-address). The following reachability
  paths remain open in Phase 1:

  - **Guest→host via the host's real LAN IP or `0.0.0.0`-bound services**
    (including `sshd`, which binds `0.0.0.0:22`). This is ordinary NAT;
    passt cannot filter by destination address. Closing this requires a
    host-side nftables egress filter scoped to the virtual machine cgroup.
    Applies to all protocols (TCP, UDP, ICMP) and both IPv4 and IPv6.
  - **`install`-time guest→host**: `virtdev-install` keeps the original
    `-netdev user` SLIRP backend (accepted: short window, official signed
    repositories only, no untrusted code running during install).
  - passt crashing **mid-session**: the guest loses networking; the
    systemd unit continues (QEMU is the main process). No health
    supervision in Phase 1 — notice and restart the virtual machine.
