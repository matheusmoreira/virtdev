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

The tradeoff accepted is operational overhead: VMs cost more to create and
manage than directories. `virtdev` exists to reduce that overhead to the point
where the isolation is practical for day-to-day development.

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
- archinstall generates entries assuming kernel lives on ESP; those are erased
  post-install and replaced with a correct XBOOTLDR entry
- XBOOTLDR partition type is set to EA00 via `sgdisk` post-install, since
  archinstall creates it as a plain fat32 partition

### Networking

- Live environment (ISO): `systemd-networkd` + `systemd-resolved`, Quad9 DNS
- Installed system: same stack, with `UseDNS=false` in the `[DHCPv4]` section
  to suppress QEMU's broken DNS proxy; Quad9 configured explicitly via
  `systemd/resolved.conf.d/dns.conf`

### User

- Username: `dev`
- Passwordless sudo (`NOPASSWD: ALL`)
- All accounts locked (`passwd -l`) — no password-based login is possible
- SSH public key injected at ISO build time, installed to
  `/home/dev/.ssh/authorized_keys` post-install

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
`virtdev-maintain` does), QEMU will not detect it. The version counter
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
2. Boots the staging images as a regular QEMU process (no cdrom, no install)
3. User performs maintenance: `pacman -Syu`, dotfile setup, etc.
4. On poweroff, reseals — replacing the previous seal. The reseal
   commit point is a single `rename(2)` from `system.old/` to
   `system.old.trash/` after the new base is fully written and chmod-444'd;
   an interrupt (Ctrl-C, SIGTERM, or host reset) before that rename leaves
   the previous sealed base intact at `system.old/` and is auto-recovered
   on the next `virtdev-maintain` run, while an interrupt after the
   rename leaves the new base committed and only the trash directory to
   clean up. A SIGKILL or hardware failure in the brief window between
   the two `mv`s and the version-file write is the only path that can
   leave a partial layout, and the auto-recovery handles that case too
   by reverting to `system.old/`.

After resealing:
- Project VMs in shared read-only mode pick up changes on next boot automatically
- Project VMs in delta mode do not pick up changes; they can be rebuilt via
  `virtdev-destroy` + `virtdev-create` + provision script

**Warning:** after a reseal, existing delta-mode project VMs hold deltas
created against the old base content. qcow2 does not validate backing file
content identity — QEMU would silently compose the delta against the new
base, which may produce filesystem corruption. `virtdev-start` detects this
via a version counter (`system/version` vs `projects/<name>/version`)
and refuses to boot a project VM whose version does not match the current
base. Always destroy and recreate delta-mode project VMs after resealing.

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
`virtdev-ssh <name> bash -s` on the fresh VM. The provision script makes the
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
- `PermitRootLogin no`
- `UsePAM yes` (required on Arch)
- Passes ssh-audit with all green (verified 2026-04-02)

The same `sshd_config` is used in both the live ISO environment and the
installed system.

Client-side, every host-to-VM SSH invocation (`virtdev-ssh`,
`virtdev-wait`, `virtdev-maintain`, `virtdev-transfer`,
`virtdev-backup`, `virtdev-restore`) passes
`-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`. The
host key changes on every base reseal and every project recreate, so
a persistent `known_hosts` entry would produce a host-key-mismatch
warning on every legitimate operation. The connection is restricted
to loopback (`-netdev user,hostfwd=tcp:127.0.0.1:<port>-:22`), so the
man-in-the-middle attacks that `StrictHostKeyChecking` defends
against do not apply.

---

## VM Runtime

Project VMs run as transient systemd user services:

```
systemd-run --user --unit=virtdev-<project> -- qemu-system-x86_64 ...
```

QEMU flags of note:

- `-enable-kvm -cpu host` — hardware-assisted virtualisation
- `-machine q35` — modern PCIe machine type
- `-drive if=pflash ...` — OVMF firmware; OVMF_CODE read-only, per-project NVRAM copy writable
- `-netdev user,hostfwd=tcp:127.0.0.1:<port>-:22` — SSH port forwarding, loopback only
- `-device virtio-rng-pci` — entropy for the guest
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
- `virtdev-create`, `virtdev-start`, `virtdev-stop`, `virtdev-destroy`
- `virtdev-nuke`

**Commands that do not take the lock** (read-only or ISO-level):

- `virtdev-list`, `virtdev-ssh`, `virtdev-wait`, `virtdev-console`
- `virtdev-transfer`, `virtdev-key`, `virtdev-iso`
- `virtdev-backup`, `virtdev-restore`, `virtdev-recreate`

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
hardcoding its path. Each script in `bin/` opens with a uniform
4-symbol bootstrap: it derives the library directory from its own
location via `readlink -f` on `BASH_SOURCE[0]`, defines an `import`
helper that de-duplicates via an associative array, and then issues
`import` calls for the libraries it uses.

The same `<bin>/../lib/virtdev` relative path resolves correctly for
both the dev tree (`~/dev/virtdev/bin → ~/dev/virtdev/lib/virtdev`)
and the pacman-installed package (`/usr/bin → /usr/lib/virtdev`),
because `readlink -f` follows symlinks and normalises to the script's
actual location. PKGBUILD installs `lib/virtdev/*` as a sibling of
`/usr/bin/`, mode 644, and declares `bash>=5.2` in `depends`.

### Current libraries

| Library | Purpose | Reserved exit codes |
|---------|---------|---------------------|
| `error` | terminal failure helper used by every script (`error <code>` with message via stdin/heredoc) | none (caller-supplied) |
| `validate` | input validation (`validate_project_name`) | 2 |
| `arguments` | declarative flag parsing and usage generation (`arguments_parse`, `arguments_usage`) | 64 |
| `lock` | exclusive `flock(2)` acquisition on `${VIRTDEV_HOME}/lock`, with maintain-aware diagnostics | 75 |
| `ssh` | SSH key file existence and permission validation (`ssh_key_validate`) | 77, 78 |

Libraries are self-contained: each imports its own dependencies
(e.g., `validate` imports `error` because it calls `error()` on
invalid input) and self-defaults the env vars it reads (e.g., `lock`
defaults `VIRTDEV_HOME`). The bootstrap's idempotency guard makes
redundant imports harmless. Library-owned exit codes are reserved by
the library and documented in its header; consumers do not override
them, so the same error condition produces the same exit code in
every script.

The full discipline rules (no top-level side effects, function
naming convention, `local` everywhere, `readonly` for constants,
header comment format) are documented in `CLAUDE.md`.

---

## Port Allocation

SSH forwarding ports are assigned at VM start time and recorded in
`projects/<name>/port` while the VM is running. The port file is removed on
clean shutdown. Auto-assignment finds the lowest port >= 2222 not currently
bound on the host. Explicit port assignment is supported via
`virtdev-start <project> <port>`; `virtdev-start` verifies the port is free
before launching QEMU.

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
| `virtdev-create`   | Derive a project VM from the sealed base                     |
| `virtdev-start`    | Start a project VM as a transient systemd user service; assigns SSH port |
| `virtdev-stop`     | Clean ACPI shutdown; SIGTERM fallback                        |
| `virtdev-ssh`      | SSH into a running project VM as dev                         |
| `virtdev-transfer` | Copy files between host and VM via rsync over SSH            |
| `virtdev-console`  | Attach to the serial console via socat                       |
| `virtdev-wait`     | Poll until SSH is accepting connections post-start            |
| `virtdev-list`     | List all projects with port and running status               |
| `virtdev-destroy`  | Delete a project VM and its disks (requires typing name)     |
| `virtdev-nuke`     | Delete all virtdev data (requires typing "nuke")             |
| `virtdev-backup`   | Snapshot user-curated guest-side paths to a host-side timestamped directory |
| `virtdev-restore`  | Restore a snapshot into a running project VM                |
| `virtdev-recreate` | Backup, destroy, recreate, optionally provision, and restore in one command |

---

## Environment Variables

All scripts respect these variables:

| Variable                  | Default                                         |
|---------------------------|-------------------------------------------------|
| `VIRTDEV_HOME`            | `${XDG_DATA_HOME:-~/.local/share}/virtdev`      |
| `VIRTDEV_SSH_KEY`         | `${VIRTDEV_HOME}/ssh/id`                        |
| `VIRTDEV_TIMEZONE`        | `UTC`                                           |
| `VIRTDEV_ISO_PROFILE`     | Auto-detected from script location              |
| `VIRTDEV_ISO`             | `${XDG_CACHE_HOME:-~/.cache}/virtdev/virtdev.iso` |
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
    id.pub              ed25519 public key (injected into ISO at build time)
  system/               sealed read-only base images (mode 444)
    system.qcow2
    home.qcow2
    nvram
    version             monotonic counter, incremented by each reseal
  installation/         transient; present between virtdev-install and virtdev-seal
    system.qcow2
    home.qcow2
    nvram
  maintenance/          transient; present while virtdev-maintain is active
    system.qcow2
    home.qcow2
    nvram
  projects/
    <name>/
      system.qcow2      delta over system/system.qcow2 (or absent in ro mode)
      home.qcow2        delta over system/home.qcow2
      nvram             per-project UEFI variable store
      version           copy of system/version at create time
      port              SSH forwarding port (present while running)
      monitor.sock      QEMU monitor socket (present while running)
      console.sock      serial console socket (present while running)
      backup.list       optional; user-curated manifest for virtdev-backup
                        (falls back to
                        ${XDG_CONFIG_HOME:-~/.config}/virtdev/projects/<name>/backup.list
                        if absent here - config path survives virtdev-nuke)
  backups/
    <project>/
      <YYYY-MM-DD>/
        <HH-MM-SS>/
          project       source project name; virtdev-restore refuses
                        to apply a snapshot to a different project
          backup.list   copy of projects/<project>/backup.list at backup time
          version       base version at backup time (may be empty)
          tree/         user content, rsync-preserved
        <HH-MM-SS>.partial/  transient; present during an in-flight backup

${XDG_CACHE_HOME:-~/.cache}/virtdev/
  virtdev.iso
  work/                 mkarchiso work tree (cleared on each build)
  profile/              assembled ISO profile (cleared on each build)

${XDG_CONFIG_HOME:-~/.config}/virtdev/
  projects/
    <name>/
      backup.list       user-curated manifest, dotfile-friendly fallback;
                        used by virtdev-backup when a project-local
                        backup.list is absent. Survives virtdev-nuke.
      provision         optional bash script run by virtdev-recreate
                        between start/wait and restore via
                        `virtdev-ssh <name> bash -s < provision`.
                        XDG-only (project-local would be wiped by
                        destroy before provision runs). Survives
                        virtdev-nuke. Overridable per-invocation
                        with `virtdev-recreate --provision <path>`.
```

`virtdev-backup` consults `projects/<name>/backup.list` under
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
  **Mitigated:** a version counter written by `virtdev-seal` and incremented
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
  time, so the version mismatch is treated as conclusive.

- **System disk rebase after base update.** Project VMs in delta mode do not
  automatically pick up base system updates. The recommended path is destroy
  and recreate. Unsafe rebase (`qemu-img rebase -u`) is technically possible
  for VMs with minimal system-level writes, but is not officially supported and
  has no tooling.

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
  `backup.list` (project-local first, XDG config fallback) for
  what to back up, and an optional XDG provision script
  (`~/.config/virtdev/projects/<name>/provision`, overridable with
  `--provision <path>`) for what to re-install. Each chain step is
  fail-fast with a step-specific recovery hint; the snapshot from
  step 1 is preserved across all failures except concurrent
  `virtdev-nuke`. Ephemeral projects without a backup.list opt
  out via `virtdev-recreate --no-backup`.
