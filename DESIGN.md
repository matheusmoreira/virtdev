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

**Isolation scope:** host and inter-project isolation are hard boundaries. A
compromised guest must not reach the host or another project. Internet and LAN
egress are explicit user policy rather than an absolute security boundary:
projects start in zone `none`, and the user may grant `wan`, `lan`, `full`, or a
custom host-port zone when the workload needs it. Policy failure is fail-closed.

**Network backend:** virtdev uses passt as its network backend (`start` and
`maintain` paths) with both host-translation paths disabled:
`--map-host-loopback none` blocks the guest→host-loopback path (the one the
old SLIRP gateway address exposed), and `--map-guest-addr none` blocks passt's
host-global-address mapping.

**Phase 2 — host egress lockdown (deny-by-default, per-zone):** passt cannot
filter by destination, so Phase 1 still left the guest able to reach the host's
real LAN IP / `0.0.0.0` bindings (including the host's `sshd`) and the rest of
the LAN. Phase 2 closes this with a **host-root nftables `inet virtdev` table**
that filters the virtual machines' egress by destination, matched to the
machines' systemd `--user` slice cgroups (`virtdev.slice` and below). Every
machine launches into one of four built-in **zone** slices (or a custom host-hole
zone) and is filtered accordingly: `none` (the default — nothing reachable but the
host→guest SSH reply), `wan` (WAN only; host + LAN dropped via `fib daddr type
local` and the private/link-local/CGNAT/multicast/broadcast sets), `lan` (host +
LAN, no WAN), `full` (host + LAN + WAN).
Host and LAN move together — the host is a LAN device, so "allow LAN, block
host" is incoherent. The host→guest SSH forward survives in EVERY zone via a
loopback-**destination** accept (`ip daddr 127.0.0.1`), not an interface match,
because a guest→host-LAN-IP packet also routes via `lo` (an `oifname "lo"`
accept would be a fail-open). See **VM Runtime → Host egress lockdown** for the
full ruleset and rationale.

- **Zones (`--zone`, per invocation):** a machine starts in `none` (fully
  locked) unless its host-side `zone` file or an explicit `--zone` says
  otherwise. The four built-ins are `none` (nothing), `wan` (the internet; host
  and LAN blocked), `lan` (host and LAN, no WAN), and `full` (host + LAN + WAN);
  user **custom zones** add per-port host holes on a built-in base. The default
  (no `--zone`, no `zone` file) is the most restrictive policy. The guest cannot
  choose its own zone — the host picks it at start, and the `zone` file is
  host-controlled.
- **passt is a filter-correctness invariant, not only a rootlessness one:**
  the match surface *is* passt's host sockets (passt is a userspace process in
  the unit cgroup making ordinary host sockets). A future TAP backend would
  move guest egress off them and silently void the ruleset — so passt is
  load-bearing for the filter and must not be swapped without redesigning it.
- **Single-user:** `socket cgroupv2` matches a uid-specific path, so
  `virtdev firewall apply` derives and bakes the validated `SUDO_UID` user's
  cgroup path. Protecting multiple users (one ruleset per user) is future work.
- **Flush-resistant via `owner,persist`:** the table carries the `owner,persist`
  flags and a resident holder (`virtdev-firewall.service`) keeps the owning
  socket open, so another process's `flush ruleset` / `systemctl restart
  nftables` SKIPS the table instead of wiping it — no reassert timer is needed.
  The separate exposure is a `user@<uid>.service` teardown that churns
  `virtdev.slice`'s inode (the frozen base match stops matching); the launch
  guard catches it by comparing the live inode to the holder-recorded baseline
  and fails CLOSED, and each launch re-verifies post-activation (see **Host
  egress lockdown → staleness**).

Remaining residuals (documented openly):

1. **`install`-time guest→host**: the installer keeps SLIRP networking.
   Accepted: the installer runs only official Arch Linux signed packages
   (no AUR, no `makepkg`, no provisioning), so the threat window is very
   short and the network exposure is similar to any OS installation.
2. **Host-local-user access to socket files** (`network.sock`, `monitor.sock`,
   `qmp.sock`, `console.sock`): mitigated by mode 0700 on the per-project
   directory; outside the primary hypervisor-escape threat model but
   documented for completeness. The QMP control socket is the same host-only
   exposure class as the HMP monitor — the guest has no path to any of them.

---

## Architecture Overview

The behavioral contract for the planned freestanding backend is tracked in
[`network/CONTRACT.md`](network/CONTRACT.md). It preserves the shipped zone
surface while separating future backend work from the temporary firewall.

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
  so the guest ignores the DNS server advertised over DHCP (by passt) and
  resolves via the fixed `systemd/resolved.conf.d/dns.conf` instead — Quad9 by
  default, set from an IPv4 or IPv6 literal in `VIRTDEV_INSTALL_DNS` at install
  time (`VIRTDEV_DNS` remains a compatibility alias)

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
  monitor.sock   (QEMU HMP monitor socket, present while running)
  qmp.sock       (QEMU QMP control socket, present while running)
  console.sock   (serial console socket, present while running)
  network.sock   (QEMU network transport socket, present while running)
```

### System Disk Mode

Virtdev currently implements delta mode only.

The project's `system.qcow2` is a writable delta over the sealed base. The
guest can install packages, modify system files, and generally treat the system
disk as writable. Updates to the base image do not propagate to existing
project VMs automatically.

### Proposed Shared Read-Only Mode

Shared read-only mode is not implemented or selectable. The intended design is
recorded here so future CLI, guest-image, and QEMU work has one contract.

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

The base image is intended to support this mode without modification.

**Note on `/etc/machine-id`:** in shared read-only mode, all VMs sharing the
same base will present the same machine ID. This is acceptable for development
use but worth knowing if any tool relies on it for namespacing.

**Note on unclean shutdown:** ext4 requires journal replay on unclean shutdown,
which needs write access. The base image must be cleanly shut down before
sealing. Maintenance QEMU runs with `-no-shutdown` and `-action panic=pause`;
`virtdev-maintain` requires QMP `query-status` to report `status=shutdown` and
`running=false`, then asks QEMU to quit and proves its systemd unit terminated
successfully. A bare QEMU exit status—including zero from monitor `quit`—is not
accepted as guest-shutdown evidence.

This is positive **guest-originated shutdown evidence**, not attestation that a
particular userspace finalizer ran: a privileged guest can request emergency
poweroff without completing normal systemd shutdown services. The maintenance
guest is trusted; a future stronger contract can add a per-boot, nonce-bound
finalizer acknowledgement after its last sync step.

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
7. After QMP positively confirms guest shutdown and QEMU exits successfully,
   if inventory was captured: boots a second time, captures inventory again,
   and requires the same shutdown proof before showing a diff
8. User confirms reseal; `virtdev-exchange` flushes the staged filesystem,
   atomically swaps `system/` and `maintenance/` via `renameat2(2)` with
   `RENAME_EXCHANGE`, then flushes the exchanged namespace before the old tree
   is eligible for cleanup

The namespace commit point is the `renameat2` syscall — a single atomic
operation that swaps the two directory names. Durability is a separate part of
the protocol: `syncfs` commits staged image bytes and metadata before the
exchange and commits the exchanged namespace afterward. The generation counter
increment and `chmod 444` are applied to `maintenance/` before those barriers.
A pre-exchange failure leaves the old `system/` authoritative; a
post-exchange-sync failure preserves both trees and refuses cleanup so the
operator can inspect them. After successful barriers, `system/` contains the
new images, generation, and read-only permissions even across power loss.

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
  the reseal prompt. Non-fatal when the hook is absent, when the
  before-capture itself fails, or when the second boot fails to
  start (the images were never opened and stay clean): in those cases
  the second boot and diff are skipped and the reseal proceeds
  normally. However, if the second (inventory) boot launches and then
  lacks shutdown proof (e.g. SSH never came up and the boot was force-stopped,
  whether QEMU reports exit 0 or a signal-derived status), the reseal is
  refused (`error 24`) to avoid sealing a
  potentially dirty image into the base; the maintenance staging is
  preserved so the session can be retried.

Both hooks can be suppressed per-invocation: `--no-provision`,
`--no-inventory`.

After resealing, current project VMs do not pick up changes. Rebuild them with
`virtdev-destroy` + `virtdev-create` followed by the provision script.

**Warning:** after a reseal, existing delta-mode project VMs hold deltas
created against the old base content. qcow2 does not validate backing file
content identity — QEMU would silently compose the delta against the new
base, which may produce filesystem corruption. `virtdev-start` detects this
via a generation counter (`system/generation` vs `projects/<name>/generation`)
and refuses to boot a project VM whose generation does not match the current
base. Back up coupled projects before resealing, then recreate them from those
exact snapshots; `virtdev-upgrade` performs that sequence. Never destroy a
mismatched project when its disks are the only remaining copy of needed data.
Detached projects (see `virtdev-detach`) are exempt — their standalone images
have no backing file dependency and `virtdev-start` skips the generation check.

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

The installer scrubs persistent host keys after customization. On the host,
each project has a private ed25519 key and an exact `virtdev-<project>`
known-host entry under `projects/<name>/ssh-host/`. QEMU injects that key with
fw_cfg; `virtdev-ssh-hostkeys` validates it, installs it under `/run`, scrubs
any persistent keys, and blocks `sshdgenkeys` from recreating them. A project
keeps its identity across restarts. Move rebinds only the alias inside its
journaled rename; recreate gets a new identity. Maintenance creates and removes
a fresh host-side identity around each proven-terminal boot.

This binding matters even on loopback: ports are reused, so a listener at the
right numeric endpoint is not proof that it is the intended VM. Every SSH path
uses the shared `ssh_transport_argv` policy: strict checking, project-local
known-host state, exact alias, ed25519 host algorithms, fixed client key and
port, disabled agent/GSSAPI credential forwarding, and no global known hosts,
host-IP lookup, DNS lookup, update, or control socket. Command-line policy takes
precedence over the assembled config.

`virtdev-ssh` still assembles per-project trigger output, system trigger output,
per-project config, and system config through `ssh -F`; `~/.ssh/config` is
excluded. Identity-source and include directives are rejected before the
connection so the fixed client key remains exclusive. Explicit client options
use a bounded, one-token `--client-option=<option>` channel before the
destination. Only selected forwarding/session options are accepted. Remote
argv follows `--` unchanged;
policy overrides, backgrounding, and modes that bypass the connection are
rejected. Polling, rsync, backup, restore, transfer, and maintenance use the
same transport builder.

Host and guest helpers are a matched transport contract. The installer emits
`capability:ssh-host-identity=1` before `complete`; the host records an exact
`guest-contract` marker, seal promotes it, and create copies it into each
project. Start requires the project marker (including detached projects), while
maintain, recreate, and upgrade preflight the base marker. Older helpers ignore
the injected key—and old maintenance chooses a random key—so no authenticated
automatic bootstrap exists. Migration uses the previous host version for
backup, then a current ISO/base and project recreation or restoration; insecure
host-key fallback is never attempted.

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
- `-netdev stream,id=net0,server=off,addr.type=unix,addr.path=<network.sock>` — connects QEMU to the
  passt network backend via a UNIX socket. passt is started by the private `virtdev-netexec` exec shim
  before QEMU, with host-translation paths disabled (`--map-host-loopback none`,
  `--map-guest-addr none`) and a loopback-only SSH forward (`-t 127.0.0.1/<port>:22`).
  `virtdev-install` keeps the original `-netdev user` (SLIRP) backend.
- `-fw_cfg name=opt/virtdev/project,string=<name>` — injects the project name into the guest via QEMU firmware configuration; used for hostname setting. `validate_project_name` applies the stable 64-byte guest `HOST_NAME_MAX`; VM creation and launch separately check exact Unix-socket paths for the current `VIRTDEV_HOME`.
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
- `-chardev socket ... -monitor` — QEMU HMP monitor via Unix socket (virtdev-stop's
  ACPI `system_powerdown`, interactive `virtdev-monitor`)
- `-chardev socket,id=qmp,...,server=on,wait=off -mon chardev=qmp,mode=control` — host-side
  QMP control channel; `virtdev-start` probes it with `query-status` to confirm QEMU actually
  launched before publishing the port. Maintenance additionally launches with
  `-no-shutdown` and `-action panic=pause`, requires QMP's durable `shutdown`
  runstate, and only then sends QMP `quit`. Host-only, guest-unreachable (bound
  only to `-mon`, no guest `-device`), same exposure class as the HMP monitor
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
`poweroff`, or an external `systemctl --user stop virtdev-<project>`. Systemd
passes its authoritative `$MAINPID` and the launch-time monitor path to the
private hook. The lock-free helper requires the unit to be `deactivating`,
sends one best-effort ACPI `system_powerdown`, and waits for that same process
to exit without touching runtime controls. Escalation is driven by systemd's
own `TimeoutStopSec`, which `virtdev-start` pins to `VIRTDEV_STOP_TIMEOUT` on the
transient unit (`--property=TimeoutStopSec=`) so the hook path and the
foreground path escalate on the same bound. Port and socket cleanup is
deferred to the next
`virtdev-start` sweep or a later foreground `virtdev-stop` (see Port
Allocation).

The transient unit is **not** launched with `--collect`. Leaving the default
`CollectMode=inactive` in place means that a failed unit persists until
`systemctl reset-failed` is called, so `virtdev-stop` can reliably query
`ExecMainStatus` and `ActiveState` after the wait completes. `virtdev-stop`
reports QEMU's final exit status alongside the stop confirmation and asserts
that the unit has reached a terminal state (`inactive` or `failed`) before
removing sockets. A host SIGTERM may surface as a signal-derived status or as
0 when QEMU handles the signal; neither value proves guest shutdown.
`virtdev-start` calls `reset-failed` before `systemd-run` to clear any residual
state from a previous failed start.

### Host egress lockdown (Phase 2 network isolation)

The host-root nftables table introduced in the Threat Model is what makes a
guest unable to reach the host or the LAN by default. Its mechanism lives
entirely in the per-zone slice the machine launches into and a host-static,
project-agnostic ruleset; the runtime path (`virtdev-start`, `virtdev-maintain`)
stays rootless.

**Slices.** Every machine launches with `--slice=` into one per-zone slice, all
children of `virtdev.slice`. The four BUILT-IN zones, plus one
`virtdev-<name>.slice` per custom zone (see **Custom zones** below):

```
virtdev.slice                lockdown handle — EVERY machine is under it (base match)
  virtdev-none.slice         no jump; the terminal drop is its policy (the secure default)
  virtdev-wan.slice          WAN only (host + LAN dropped)
  virtdev-lan.slice          host + LAN, no WAN
  virtdev-full.slice         host + LAN + WAN
  virtdev-<name>.slice       a custom zone: its base + per-port host holes
```

The slices are **shared across projects** — there is no per-project slice and no
`systemd-escape`. Identity stays in the unit name `virtdev-<project>.service`
(`stop`/`list`/`status` key off it). The zone vocabulary is the four built-ins
plus the user's custom zones; custom names are held to a strict charset
(`^[a-z][a-z0-9_]*$`, no dashes — a dash would nest the slice a level deeper and
break the cgroup-level math), so there is still nothing to collide and nothing to
escape. `firewall_slice_for <zone>` (in `lib/virtdev/firewall`) is the **single**
helper producing these names; `virtdev-start`, `virtdev-maintain`, and the ruleset
generator all call it, so a launch path cannot silently forget `--slice` and
escape the baseline. `maintenance` launches into `virtdev-wan.slice` (it needs WAN
for `pacman -Syu`; the base image is trusted and needs no host/LAN).

Because nft resolves a `socket cgroupv2 "path"` to a cgroup **inode at load
time**, a referenced slice must exist when the ruleset loads — but a
started-but-EMPTY systemd slice has no cgroup directory. So each nft-referenced
zone (`wan`, `lan`, `full`, and every custom zone) carries a **resident pin**:
`virtdev-firewall-pin@<zone>.service`, a `--user` `sleep infinity`
(`Restart=always`) launched into the slice by `apply`, which also **reconciles**
— a pin whose zone no longer exists is disabled, so a removed custom zone leaves
no immortal unit. The pins hold the relaxation slices and their parent
`virtdev.slice` present with stable inodes for the firewall's lifetime.
`virtdev-none.slice` needs no pin (no rule references it). **Linger is required**
so the user manager, pins, and slices run boot→shutdown.

**Ruleset.** `bin/virtdev-firewall` generates one fixed dual-stack `inet
virtdev` table (no per-project content; illustrative):

```
table inet virtdev {
  flags owner, persist                 # held by the resident holder; flush-resistant
  set lan_v4 { type ipv4_addr; flags interval; elements = { <private/CGNAT/mcast/bcast> } }
  set lan_v6 { type ipv6_addr; flags interval; elements = { fc00::/7, fe80::/10, ff00::/8 } }
  chain output {
    type filter hook output priority 0; policy accept;
    socket cgroupv2 level 4 "user.slice/user-<uid>.slice/user@<uid>.service/virtdev.slice" jump virtdev_machines
  }
  chain virtdev_machines {
    ip  daddr 127.0.0.1 accept          # passt's SSH-forward reply (loopback DEST, every zone)
    ip6 daddr ::1       accept          #   (gains `ct state established` once a host-hole zone exists)
    socket cgroupv2 level 5 "…/virtdev.slice/virtdev-wan.slice"  jump zone_wan
    socket cgroupv2 level 5 "…/virtdev.slice/virtdev-lan.slice"  jump zone_lan
    socket cgroupv2 level 5 "…/virtdev.slice/virtdev-full.slice" jump zone_full
    socket cgroupv2 level 5 "…/virtdev.slice/virtdev-gdb.slice"  jump zone_gdb   # a custom zone
    drop                                # none + strays: deny by default
  }
  chain zone_none { drop; }
  chain zone_wan  { fib daddr type local drop; ip daddr @lan_v4 drop; ip6 daddr @lan_v6 drop; accept; }
  chain zone_lan  { ip daddr @lan_v4 accept; ip6 daddr @lan_v6 accept; fib daddr type local accept; drop; }
  chain zone_full { accept; }
  chain zone_gdb {                      # custom: base wan + a hole to host:1234
    fib daddr type local meta l4proto { tcp, udp } th dport 1234 accept
    jump zone_wan
  }
}
```

The generator emits the four built-ins as reusable base chains
(`zone_none/wan/lan/full`) plus one `zone_<name>` per custom zone, with a uniform
`jump zone_<z>` dispatch for every slice-owning zone (built-in relaxation +
customs). The cgroup `level` numbers above (4 for the base, 5 for the zones)
illustrate the standard layout but are not hard-coded — the generator derives them
from the constructed base path's depth, so the level can never disagree with the
actual cgroup depth. Properties: dropping on `daddr` with no L4 qualifier is
**all-protocol** for free; one `inet` table is **dual-stack** for free; `fib daddr
type local` solves the host's own addresses without enumeration; the
**loopback-destination** accept (not `oifname "lo"`) preserves the host→guest SSH
forward in every zone without accepting guest→host-LAN-IP (which also routes via
`lo`). That accept is **conntrack-free when no host-hole zone exists**, so a
`notrack`-on-`lo` rule in the user's firewall cannot break `virtdev-ssh`; defining
a host-hole zone narrows it to `ct state established` (so a guest-INITIATED new
loopback flow falls through to the per-port holes instead of being blanket-accepted)
and from then on virtdev-ssh DOES depend on loopback conntrack. The narrowing is
safe because passt always `connect(2)`s for guest flows — the host-side packet is
SYN-first → `ct new` → gated by the zone — so only the SSH-reply leg (passt as the
accepting server) is `established`. The base match is on `virtdev.slice` and
catches every machine by ancestry (scoped: descendants only, nothing outside —
verified); `none` machines and anything unrecognised hit the terminal `drop`
(fail-closed).

**Custom zones.** A custom zone is a user-authored file
`~/.config/virtdev/zones/<name>` declaring a `base` (a built-in) and one or more
`port <number> <proto...>` host holes — e.g. `base wan` + `port 1234 tcp udp`. It
extends the built-in set with a narrow, scoped hole to a HOST service (the
motivating case: a guest driving a host gdbserver) without opening the whole
LAN/WAN. Each hole becomes `fib daddr type local … th dport <port> accept` (so it
reaches the service however it binds — loopback or the host's LAN IP), and a
launch into that zone flips passt's host-loopback map on (the map is
all-or-nothing, so the PER-PORT limit is nft's; the guest reaches host services at
its default gateway). The per-port limit holds only for `base none`/`base wan`,
whose chains drop the host after the holes; `base lan`/`base full` accept all
host-destined traffic, so on those bases the holes are inert and the guest reaches
the WHOLE host loopback (the zone is still marked `hostmap=1`) — by design, since
`lan`/`full` already mean host-reachable. Use `none`/`wan` for a scoped per-port
hole. The files commit to dotfiles — author once, `git`, reuse.
**`apply` is the ONLY context that reads the user's `zones/` config** (root, via
`SUDO_UID` + the user's home; constructed, never searched). It validates every
file up front (a malformed one aborts apply, exit 89), then — only after the
holder load wins — writes the realized set to `/etc/virtdev/firewall/zones`
(`<name> <needs-hostmap>`, atomic). The rootless launch and `list`/`recreate`/
`upgrade` read that manifest; the holder derives its cgroup-dir wait-set from the
installed ruleset; none of them read the user's config, so the dynamic set has a
single root-owned source of truth. Selecting a zone that isn't applied refuses
(`virtdev-start` exit 22, "run apply") rather than launching into an empty slice
that silently locks. A custom zone is a deliberate, documented breach of host
isolation: driving a host service grants the untrusted guest whatever that service
permits (gdbserver = host code-exec).

Adding or loosening a hole is safe to `apply` live; **removing the LAST host-hole
zone is not, while a machine still runs in one.** passt's host-loopback map is fixed
at machine launch and `apply` never touches running machines (it restarts only the
holder and the pins), so the nft loopback accept un-narrows (its `ct state
established` gate exists only while some host-hole zone does — see below) out from
under a machine whose passt map is still wide open, widening it from its declared
port to **every** host loopback port. So `apply` **refuses** (exit 100) when the new
zone set has no host-hole zone but a machine is still running with its passt map
open, naming the machines to `virtdev stop` first; nothing is changed on refusal.
"Map open" is read from each running machine's **own** `ExecStart` — it carries
`--allow-host-loopback` iff the launch opened the map — which is the authoritative
per-machine signal: systemd-owned (the guest cannot forge it) and INDEPENDENT of
`firewall/zones`, so a lost or stale manifest cannot blind the guard, and an
`--unfiltered` machine (map never opened) is correctly not counted. Running machines
are enumerated through the shared `firewall_running_machine_units` predicate, which
counts `active` AND `deactivating` (a machine mid-shutdown still holds its map open)
— the same predicate `virtdev-maintain`'s reseal preflight uses. Removing a
*non-last* hole keeps the gate (the machine that lost its hole fails *closed*), and
removing the last one with no such machine running just proceeds. If the
enumeration itself cannot reach the user manager, `apply` fails closed (exit 102,
nothing changed) rather than reading the empty result as "no machines running".

**Apply (root, one-time).** `virtdev firewall apply` (no sudo) **self-elevates**:
run rootless it re-execs `sudo <self> apply --virtdev-home <VIRTDEV_HOME>`,
forwarding the invoking user's `VIRTDEV_HOME` explicitly across the sudo boundary
(sudo strips the env), so the no-sudo form is the cleanest invocation. A direct
`sudo virtdev firewall apply` also works — with no flag it falls back to the
default home built from the user's home dir. Either way apply requires **linger**
(exit 98; never enables it silently), validates `SUDO_UID` (numeric > 0; refuses
bare root, never bakes a guessed uid/path), **copies** (never symlinks) the
holder unit → `/etc/systemd/system` and the `--user` pin template →
`/etc/systemd/user` (the split is user-vs-system, NOT by file extension), starts
the pins AS THE USER (so the zone cgroups exist), **constructs** the cgroup base
path from the validated uid (never searches the user-writable cgroup tree),
generates to a temp file on the same filesystem, validates it with `nft -c` **in a
throwaway network namespace** (`unshare --net`: on a re-apply the live `inet
virtdev` is owner-held by the running holder, so a plain `nft -c` of the ruleset's
`destroy`/recreate is rejected `EPERM`; a fresh netns has no such table, while
cgroup2 paths still resolve — so the pins must be up first), atomically
`rename(2)`s it over `/etc/virtdev/firewall/nft`, and restarts the holder. The
atomic install means an interrupted apply leaves the prior good ruleset intact.
The ruleset is project-agnostic, so a project created later is covered
immediately — no re-apply.

To serialize against a concurrent `virtdev start`, apply takes the invoking
user's **rootless lock** (`firewall_lock_user` opens the SAME
`${VIRTDEV_HOME}/lock` the launches hold) around its running-machine scan, the
holder reload, and the manifest write — the structural close of the start-vs-apply
race (a launch must not read the old manifest, open passt's map, then have apply's
reload un-narrow the loopback under it). This is the ONLY reason apply needs the
user's `VIRTDEV_HOME` (forwarded via `--virtdev-home`): solely to LOCATE that lock,
never for a security decision — every security input still derives from `SUDO_UID`,
so a wrong/forged home only skips coordination (fail-safe). Timing out (60 s) is
exit 101. The realized-zone manifest `/etc/virtdev/firewall/zones` is published
**lockstep** with the ruleset: apply removes it BEFORE the holder restart and
(re)writes it only after the restart confirms a successful load, enforcing
"`firewall/zones` exists ⟺ the loaded ruleset was published by a COMPLETED apply".
Any outcome that loads the new ruleset but skips the rewrite (a crash in the
restart→write window, or an exit-95 abort whose holder self-heals via
`Restart=on-failure`) therefore stays fail-CLOSED — the manifest is absent, so
custom zones refuse with "run apply" and built-ins fall to the legacy floor — until
the rewrite completes.

**Holder.** One resident unit, `virtdev-firewall.service` (root, `Type=notify`),
loads the ruleset into the `owner,persist` table via an `nft -i` include and
holds the owning socket open. While it runs the table is **owned**, so another
process's `flush ruleset` SKIPS it — no reassert timer is needed. At start it
derives the uid + cgroup base from the installed ruleset, waits for the
pin-backed cgroup dirs to appear (exit 99 on timeout → guard reads down → fail
CLOSED; also resolves boot ordering, since a system unit cannot `After=` a
`--user` unit), loads + verifies the table, and records `<uid>
<virtdev.slice-inode>` to `/etc/virtdev/firewall/cgroupv2` atomically. Recording the
inode it actually froze against means a reboot re-records and never bricks the
guard.

**Launch guard + staleness.** `firewall_require` (in `lib/virtdev/firewall`)
runs before every launch and refuses (exit 88) unless the shared
`firewall_is_active` holds — the holder is exactly `active` AND the live
`virtdev.slice` inode still equals the recorded baseline (built from the
RECORDED uid, so `status`/`list` run by any user report truth) — AND the caller
IS the firewall's uid. No `nft list` (root-only); the `owner,persist` holder
asserts the table transitively. It queries the **system** manager (the firewall
is a system unit; the guests are `--user` units). `--unfiltered` bypasses it
with a loud warning. The guard is local to `virtdev-maintain` too, firing before
**both** its boots. The remaining exposure is a `user@<uid>.service` teardown
(`systemctl restart user@<uid>`, manager OOM, reboot) that recreates
`virtdev.slice` with a NEW inode — the frozen base rule then stops matching. A
teardown kills all running machines, so the exposure is strictly *new launches*:
the inode check catches them (fail CLOSED), and each launch additionally
re-verifies post-activation — it reads the launched unit's live `ControlGroup`,
walks to its `virtdev.slice` ancestor, and compares the inode to the recorded
baseline (`firewall_assert_unit_filtered`), tearing the unit down on a mismatch
(`virtdev-start` exit 21 / `virtdev-maintain` 25) to close the
guard→`systemd-run` TOCTOU.

**Migration:** no reseal or generation bump, but `apply` is now mandatory before
launches (the guard reads `/etc/virtdev/firewall/cgroupv2`, which only the holder
writes). When the new ruleset first loads, a machine still in an OLD slice name
matches no zone jump and falls to the terminal `drop` (loses all network) until
relaunched — fail CLOSED; `recreate`/`upgrade` relaunch to migrate it.

---

## Concurrency and Locking

Locks live outside the data they protect:

```
${XDG_RUNTIME_DIR}/virtdev/locks/store-<sha256>.lock
${XDG_RUNTIME_DIR}/virtdev/locks/cache-<sha256>.lock
${XDG_RUNTIME_DIR}/virtdev/locks/transfer-target-<sha256>.lock
```

The fallback is `${XDG_STATE_HOME:-~/.local/state}/virtdev/locks`; an
explicit `VIRTDEV_LOCK_DIRECTORY` overrides both. Each hash includes its lock
domain and canonical protected path, so aliases collide while distinct stores,
caches, and host publication targets remain independent. Stable lock files
survive deletion of the protected data.

Store locks use fd 9. A compatibility lock on `${VIRTDEV_HOME}/lock` uses
fd 7 so the current firewall apply path remains coordinated. Cache operations
use fd 8. Download publication uses fd 6 and a per-canonical-target
`transfer-target-<sha256>.lock`. `virtdev-iso` and `virtdev-nuke` therefore
cannot mutate the same build tree concurrently, and two downloads cannot
publish concurrently to one host target.

`flock -n` fails immediately with exit 75. Setup failures use exit 76.
Holder records are one bounded PID line, and maintenance detection reads at
most 512 bytes from `/proc/<pid>/cmdline`. The contention message prints the
exact primary path.

`virtdev-recreate` and `virtdev-upgrade` hold one store lock across their
whole transaction. Lock-aware children verify and reuse the inherited
descriptors, covering backup, restore, provisioning, maintenance, and every
inter-step boundary without self-deadlock.

Store-lock users are install, seal, maintain, create, start, stop, destroy,
detach, move, key, recreate, upgrade, and nuke. ISO uses only the cache lock;
nuke takes store then cache. Direct list/status/SSH/wait/console/transfer/
backup/restore commands do not acquire a store lock; a download transfer does
acquire its target lock. `virtdev-stop
maintenance` keeps its explicit lock exception so it can stop the session
whose parent holds the store lock.

`virtdev-start` retains its lock until systemd reports the transient unit
active. `virtdev-maintain` retains it for the full maintenance session.

---

## Implementation: Shared Library System

`bin/virtdev-*` are the entry points; cross-cutting helpers used by
more than one entry point live in `lib/virtdev/*` and are sourced
into the script's shell at start-up rather than reimplemented per-script.
This is mechanical deduplication of identical boilerplate, not an
extension point: the libraries are internal-only and have no stable API.

The mechanism is bash 5.3's `source -p <colon-search-path> <name>`,
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
`/usr/bin/`, mode 644, and declares `bash>=5.3` in `depends`.

### Current libraries

| Library | Purpose | Reserved exit codes |
|---------|---------|---------------------|
| `import` | bootstrap module sourced by every script; provides `virtdev_library_directory`, `virtdev_bin_directory`, `virtdev_loaded_libraries`, and `import()` | none |
| `error` | terminal failure helper used by every script (`error <code>` with message via stdin/heredoc) | none (caller-supplied) |
| `validate` | input validation (`validate_project_name`) | 2 |
| `arguments` | declarative flag parsing and usage generation (`arguments_parse`, `arguments_usage`); universal `--help` and `--color` handling | 64 |
| `integer` | canonical bounded-positive-decimal predicate (`integer_is_bounded_positive`) | none (predicate status) |
| `ip` | IPv4/IPv6 literal predicate (`ip_literal_is_valid`) | none (predicate status) |
| `lock` | canonical store, cache, and transfer-target `flock(2)` domains, including `lock_acquire_transfer_target`, inherited composition, and bounded diagnostics | 75, 76 |
| `ssh` | Guest-contract checks, project host identities, strict shared transport argv, rsync wrapper, and bounded polling | 77, 78, 103, 104, 105 |
| `diagnostic` | bounded, sanitized stderr capture and emission for untrusted subprocesses, including guest transport and host tar/rsync (`bounded_stderr_run`, `bounded_stderr_emit`) | 1, 2, 125 (returned; otherwise child status) |
| `enumerate` | strict bounded NUL-record capture and sorting (`enumerate_nul_sorted`) | 2, 3, 4 (returned) |
| `snapshot` | enumerate, count, and select virtdev-backup snapshot directories (`snapshot_directory`, `snapshot_list*`, `snapshot_count`, `snapshot_any`, `snapshot_latest`, `snapshot_validate_format`) | 79 |
| `trigger` | run user-supplied trigger scripts at explicit lifecycle points (`trigger_fire`); bounds execution and stdout before returning text through namerefs | 80 |
| `trigger-runner` | internal bounded trigger pipeline and status reporting to its supervisor | none |
| `port` | SSH forwarding port file reading and validation (`port_require`, `port_read_lenient`, `port_in_use`) | 81, 87 |
| `manifest` | resolve and normalize backup manifests; reject parent escapes and intermediate restore symlinks | none (caller-supplied) |
| `frozen-input` | bounded durable copies and digest revalidation for inputs crossing irreversible phases | 40, 41, 42, 43, 44 (returned) |
| `mount` | locate containing and nested mounts before recursive operations | none (caller-supplied) |
| `machine` | resolve project and maintenance machine targets into explicit kind, unit, data-root, and runtime-root descriptors; owns authoritative single-machine state mapping and fail-closed predicates | 2, 3 (returned) |
| `project` | enumerate projects and enforce ordinary-project data operations (`project_require_ordinary`, batch state, generation and detached-state readers); compatibility state predicates delegate to `machine` | 3, 82 |
| `runtime` | single source of truth for a machine's ephemeral host-side artifacts — the monitor/console/passt/qmp sockets, atomic `port` readiness signal, and `launch.phase` exit-provenance marker | none |
| `lifecycle` | nonterminating machine lifecycle service: activation/QMP readiness with unit ownership checks, atomic readiness publication, terminal proof, and fail-closed runtime cleanup; callers map structured statuses to CLI exits | structured return statuses |
| `recreate-result` | stable recreate results and phase/state mappings shared with orchestrators | 20–29 |
| `stop-result` | shared stopped-with-incomplete-cleanup result | 7 |
| `passt` | passt network backend constructor helpers (`passt_command`, `passt_socket_clean`); single source of truth for passt flags | 83, 84, 86 |
| `qemu` | shared QEMU argv construction; the network-isolation security boundary keeping `start` and `maintain` flags byte-identical | none |
| `qmp` | bounded, transport-only QMP client (`qmp_query_running_once`, `qmp_query_running`, `qmp_wait_shutdown`, `qmp_quit`); lifecycle ownership decisions remain outside the transport | none |
| `firewall` | host egress lockdown policy single-source-of-truth (`firewall_slice_for`, `firewall_zone_of_slice`, `firewall_zone_default`, `firewall_require`, `firewall_is_active`, `firewall_assert_unit_filtered`, `firewall_zone_valid`, `firewall_zones`) + zone/destination-set constants. Root-only ruleset generation and apply live in `bin/virtdev-firewall`, not here | 88 |
| `confirm` | interactive confirmation prompts (`confirm_word`, `confirm_proceed`) | none (caller-supplied) |
| `terminal` | terminal-aware output via terminfo/tput (`terminal_init`, `terminal_write`, `terminal` array); lazy-inits on first `terminal_write` call using the color mode from `arguments_parse` | none |

Libraries are self-contained: each imports its own dependencies
(e.g., `validate` imports `error` because it calls `error()` on
invalid input) and self-defaults the env vars it reads (e.g., `lock`
defaults `VIRTDEV_HOME`). The bootstrap's idempotency guard makes
redundant imports harmless. Library-owned exit codes are reserved by
the library and documented in its header; consumers do not override
them, so the same error condition produces the same exit code in
every script. `port_require`, for instance, raises the absent-port
condition as a fixed `87` (and a corrupt file as `81`) rather than
accepting a per-script code, so "no port assigned" reports identically
from `virtdev-ssh`, `virtdev-port`, `virtdev-wait`, `virtdev-transfer`,
`virtdev-backup`, and `virtdev-restore`.

The full discipline rules (no top-level side effects, function
naming convention, `local` everywhere, `readonly` for true
constants only, header comment format) are documented in
`CLAUDE.md`.

---

## Port Allocation

SSH forwarding ports are assigned at virtual-machine start time and recorded
in `projects/<name>/port`. The port file is written LAST, only after QEMU is
confirmed running (the mandatory QMP `query-status` liveness probe; a host
missing the declared `socat` or `jq` dependency refuses launch first) and,
for a filtered launch, the machine is proven to sit under the frozen
`virtdev.slice` — so
`port file exists ⟹ the machine was confirmed running`, never a false green
from a launch that failed after the unit went active. A foreground
`virtdev-stop` removes the port file (and the per-project sockets) once the
unit reaches a terminal state, and `virtdev-start`'s cleanup-on-failure trap
removes it on failed activation. A guest-initiated `poweroff` or an external
`systemctl --user stop`, however, stops the unit through the `ExecStop`
private ACPI hook, which deliberately skips that cleanup (see Stopping a VM),
so the port file can linger past an inactive unit until it is swept.

The port file is therefore the running signal only *while the unit is
active*: every consumer (`virtdev-ssh`, `virtdev-port`, `virtdev-list`) gates
on the systemd unit's active state before it uses the port to reach the
guest, so a port file that outlives its unit is never acted on. A port file
left behind by the deferred-cleanup path is harmless stale state — the next
`virtdev-start` clears it (and stale sockets) only after observing `inactive` or
`failed`, then rechecks that terminal state at submission. A stale wrong port
therefore never survives into the launch window; it
then writes the correct port only after confirming liveness, and a failed
start removes it via the cleanup trap. A foreground `virtdev-stop` removes it
too. Auto-assignment finds the lowest port >= 2222 not currently bound
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
| `virtdev-ssh`      | SSH with strict project identity; separates bounded client options from remote argv |
| `virtdev-transfer` | Copy files; bounded downloads are atomically published on the host |
| `virtdev-console`  | Attach to the serial console via socat                       |
| `virtdev-wait`     | Poll until SSH is accepting connections post-start            |
| `virtdev-list`     | List all projects with port, status, and generation          |
| `virtdev-status`   | Print `running`, `stopped`, `starting`, `stopping`, or `unknown` |
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
| `virtdev-firewall` | Generate / apply / status of the host egress lockdown (`apply` is root; `status` is rootless) |

---

## Environment Variables

The public environment interface is:

| Variable | Default | Accepted values or purpose |
|----------|---------|----------------------------|
| `VIRTDEV_HOME` | `${XDG_DATA_HOME:-~/.local/share}/virtdev` | Data directory |
| `VIRTDEV_SSH_KEY` | `${VIRTDEV_HOME}/ssh/id` | SSH private-key path |
| `VIRTDEV_CACHE` | `${XDG_CACHE_HOME:-~/.cache}/virtdev` | Cache directory |
| `VIRTDEV_LOCK_DIRECTORY` | `${XDG_RUNTIME_DIR}/virtdev/locks`, else `${XDG_STATE_HOME:-~/.local/state}/virtdev/locks` | Private lock directory override for all lock domains |
| `VIRTDEV_TIMEZONE` | host timezone (UTC fallback) | IANA timezone name |
| `VIRTDEV_LOCALE` | host locale (`en_US.UTF-8` fallback) | Guest locale |
| `VIRTDEV_KEYMAP` | host keymap (`us` fallback) | Guest console keymap |
| `VIRTDEV_INSTALL_DNS` | `9.9.9.9` | Install-time IPv4 or IPv6 literal |
| `VIRTDEV_DNS` | unset | Legacy fallback for `VIRTDEV_INSTALL_DNS` |
| `VIRTDEV_PACKAGES` | unset | Readable extra-packages file |
| `VIRTDEV_SCRIPT` | unset | Readable custom install script |
| `VIRTDEV_INVENTORY` | unset | Readable inventory script |
| `VIRTDEV_ISO_PROFILE` | auto-detected | ISO profile directory |
| `VIRTDEV_ISO` | `${VIRTDEV_CACHE}/virtdev.iso` | Installer ISO path |
| `VIRTDEV_SYSTEM_DISK_SIZE` | `24G` | `qemu-img` size syntax |
| `VIRTDEV_HOME_DISK_SIZE` | `48G` | `qemu-img` size syntax |
| `VIRTDEV_VM_MEMORY` | `4096` MB | Positive integer MB |
| `VIRTDEV_VM_CPUS` | `4` | Positive integer CPU count |
| `VIRTDEV_INSTALL_SOCKET_TIMEOUT` | `120` seconds | Integer `1..86400` seconds |
| `VIRTDEV_INSTALL_PROGRESS_TIMEOUT` | `1200` seconds | Integer `1..86400` seconds |
| `VIRTDEV_INSTALL_SHUTDOWN_TIMEOUT` | `120` seconds | Integer `1..86400` seconds |
| `VIRTDEV_STOP_TIMEOUT` | `60` seconds | Integer `1..86400` seconds |
| `VIRTDEV_WAIT_TIMEOUT` | `120` seconds | Integer `1..86400` seconds |
| `VIRTDEV_TRIGGER_TIMEOUT` | `10` seconds per trigger | Integer `1..3600` seconds |
| `VIRTDEV_TRIGGER_KILL_AFTER` | `2` seconds | Integer `1..60` seconds from TERM to KILL |
| `VIRTDEV_TRIGGER_OUTPUT_MAX_BYTES` | `65536` bytes | Integer `1..1048576` bytes per output stream |
| `VIRTDEV_MAINTENANCE_HOOK_TIMEOUT` | `3600` seconds per hook | Integer `1..86400` seconds |
| `VIRTDEV_MAINTENANCE_HOOK_KILL_AFTER` | `5` seconds | Integer `1..60` seconds from TERM to KILL |
| `VIRTDEV_MAINTENANCE_HOOK_OUTPUT_MAX_BYTES` | `1048576` bytes | Integer `1..67108864` bytes per output stream |
| `VIRTDEV_BACKUP_MAX_BYTES` | `8589934592` bytes (8 GiB) | Integer `1..1099511627776`; archive and regular logical-data ceiling |
| `VIRTDEV_BACKUP_MAX_ENTRIES` | `200000` entries | Integer `1..10000000`; extracted paths including implicit parents |
| `VIRTDEV_BACKUP_TIMEOUT` | `3600` seconds total | Integer `1..86400` seconds |
| `VIRTDEV_BACKUP_KILL_AFTER` | `5` seconds | Integer `1..60` seconds from TERM to KILL |
| `VIRTDEV_RESTORE_MAX_BYTES` | `8589934592` bytes (8 GiB) | Integer `1..1099511627776`; regular logical-data ceiling |
| `VIRTDEV_RESTORE_MAX_ENTRIES` | `200000` entries | Integer `1..10000000`; snapshot-tree entries |
| `VIRTDEV_RESTORE_TIMEOUT` | `3600` seconds total | Integer `1..86400` seconds |
| `VIRTDEV_RESTORE_KILL_AFTER` | `5` seconds | Integer `1..60` seconds from TERM to KILL |
| `VIRTDEV_TRANSFER_MAX_BYTES` | `8589934592` bytes (8 GiB) | Integer `1..1099511627776`; download logical-data ceiling |
| `VIRTDEV_TRANSFER_MAX_ALLOCATED_BYTES` | `10737418240` bytes (10 GiB) | Integer `1..2199023255552`; per materialized tree; must also cover archive overhead |
| `VIRTDEV_TRANSFER_MAX_TRANSACTION_BYTES` | `53687091200` bytes (50 GiB) | Integer `1..10995116277760`; aggregate host transaction cap |
| `VIRTDEV_TRANSFER_MAX_ENTRIES` | `200000` entries | Integer `1..10000000`; download-tree entries |
| `VIRTDEV_TRANSFER_TIMEOUT` | `3600` seconds total | Integer `1..86400` seconds |
| `VIRTDEV_TRANSFER_KILL_AFTER` | `5` seconds | Integer `1..60` seconds from TERM to KILL |
| `VIRTDEV_REMOTE_DIAGNOSTIC_MAX_BYTES` | `65536` bytes | Integer `1..1048576`; bounded untrusted subprocess diagnostics for guest transport and host tar/rsync |
| `OVMF_CODE` | `/usr/share/edk2/x64/OVMF_CODE.4m.fd` | OVMF code-image path |
| `OVMF_VARS` | `/usr/share/edk2/x64/OVMF_VARS.4m.fd` | OVMF variables-template path |

---

## Data Layout

```
${XDG_RUNTIME_DIR}/virtdev/locks/
  store-<sha256>.lock  canonical store lock (state-directory fallback)
  cache-<sha256>.lock  canonical cache lock (state-directory fallback)
  transfer-target-<sha256>.lock  canonical host publication-target lock

<host-download-stage-parent>/
  .virtdev-transfer.XXXXXXXX/  active transaction; preserved as ambiguous-publication evidence
    publication          NUL-delimited target, identity, and phase manifest
    publication.tmp      manifest publication temporary

<host-target-parent>/
  .virtdev-transfer-recovery.XXXXXXXX/  successful-overwrite recovery sibling
    publication          NUL-delimited target, identity, and phase manifest
    publication.tmp      manifest publication temporary
    previous             displaced target retained for open-handle safety

${VIRTDEV_HOME}/
  lock                  compatibility lock for firewall coordination
  move.transaction      durable exact source/target journal for move recovery
  move.transaction.tmp.<pid>  move-journal publication temporary
  transactions/         private workflow transaction directories (mode 0700)
    recreate.<project>.<random>/
      provision         frozen provision input; preserved after some failures
    upgrade.<random>/
      <project>.provision  per-project frozen provision input
    maintain.<random>/  frozen hook inputs and bounded output captures
  ssh/
    id                  ed25519 private key (mode 600)
    id.pub              ed25519 public key (injected at install time via fw_cfg)
  system/               sealed read-only base images (mode 444)
    system.qcow2
    home.qcow2
    nvram
    generation          monotonic counter, incremented by each reseal
    guest-contract      proven guest/host transport version
  installation/         transient; present between virtdev-install and virtdev-seal
    system.qcow2
    home.qcow2
    nvram
    guest-contract      written only after the installer capability and clean exit
  maintenance/          transient; present while virtdev-maintain is active
    system.qcow2
    home.qcow2
    nvram
    guest-contract      copy of the sealed-base marker
  projects/maintenance/  transient maintenance virtual machine runtime directory (mode 0700)
    port                 hardcoded port 2222
    monitor.sock         QEMU HMP monitor socket (present while maintenance virtual machine is running)
    qmp.sock             QEMU QMP control socket (present while maintenance virtual machine is running)
    console.sock         serial console socket (present while maintenance virtual machine is running)
    network.sock         QEMU network transport socket (present while maintenance virtual machine is running)
  projects/
    <name>/
      system.qcow2      delta over system/system.qcow2
      home.qcow2        delta over system/home.qcow2
      nvram             per-project UEFI variable store
      generation        copy of system/generation at create time
      guest-contract    copied at create time; independent after detach
      ssh-host/         private host key, public key, exact-alias known_hosts
      .detach.transaction      identity-bound detach recovery journal
      .detach.transaction.tmp  detach-journal publication temporary
      system.qcow2.bak         journal-bound original system disk
      home.qcow2.bak           journal-bound original home disk
      system.qcow2.detach      uncommitted converted system disk
      home.qcow2.detach        uncommitted converted home disk
      generation.detach.tmp    detached-marker publication temporary
      port              SSH forwarding port (present while running)
      monitor.sock      QEMU HMP monitor socket (present while running)
      qmp.sock          QEMU QMP control socket (present while running)
      console.sock      serial console socket (present while running)
      network.sock      QEMU network transport socket (present while running)
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
          manifest      frozen manifest used for capture
          generation    mandatory canonical base generation at backup time
          tree/         extracted user content
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
                        before the reseal prompt. Non-fatal when absent,
                        when the before-capture fails, or when the second
                        boot fails to start (images stay clean). If the
                        second boot launches but lacks positive QMP shutdown
                        evidence or exits unclean, the reseal is refused to
                        protect the base (exit 24); the
                        staging is preserved for retry. Suppressible with
                        --no-inventory.
  projects/
    <name>/
      ssh_config          per-project SSH config. Overrides system-level.
      triggers/
        pre-ssh           per-project pre-ssh trigger; runs after system hook
        post-ssh          per-project post-ssh trigger; runs after system hook
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

Move and detach recovery is authorized only by a matching
`move.transaction` or `.detach.transaction` journal. Detach additionally binds
the original disk identities; a bare `.bak` file has no recovery authority.
Workflow directories under `transactions/` are normally removed. Recreate and
upgrade may preserve frozen provision inputs after failures in irreversible
phases, and abrupt host loss can leave any in-flight transaction directory for
inspection.

A successful transfer overwrite retains its recovery sibling so the previous
target remains named for open handles. Remove that directory manually only
after the new target is validated and all users or processes holding old
handles have stopped. An active `.virtdev-transfer.XXXXXXXX/` retained after an
ambiguous publication is evidence; inspect it and the target before any change.
Exit 16 during retention can leave both the active transaction and a partial
recovery sibling, whose manifests must be inspected together.

`virtdev-iso` refuses cleanup when mountinfo contains a mount at or below
`work/` or `profile/`. It atomically moves each tree to a root-owned quarantine
on the same filesystem, checks mounts again, and performs privileged deletion
only inside that locked directory. `virtdev-destroy` and `virtdev-nuke` also
refuse nested mounts and restrict recursive removal to one filesystem.

The host egress lockdown (Phase 2) stores root-owned state outside
`${VIRTDEV_HOME}`, established by `sudo virtdev firewall apply`:

```
/etc/virtdev/firewall/
  nft                     generated nftables ruleset (not shipped; mode 0644).
                          Loaded by the holder below; regenerated atomically.
  cgroupv2                "<uid> <virtdev.slice-inode>" recorded by the holder
                          post-load; the launch guard's staleness reference.
  zones                   realized-zone manifest ("<zone> <needs-hostmap>" per
                          line); published by apply after the holder load wins.
/etc/systemd/system/      admin copy written by `virtdev firewall apply`
  virtdev-firewall.service          resident owner,persist holder (Type=notify); is-active signal
/etc/systemd/user/        admin copy of the --user pin template
  virtdev-firewall-pin@.service     sleep-infinity pin, one instance per relaxation zone
/usr/lib/systemd/{system,user}/  package copies of the holder + pin (shipped by PKGBUILD)

systemd --user slices (shared per zone; the pins keep the relaxation zones resident):
  virtdev.slice                     lockdown handle (every machine is under it)
  virtdev-none.slice                the secure default (no rule; terminal drop)
  virtdev-wan.slice                 WAN only (pinned)
  virtdev-lan.slice                 host + LAN, no WAN (pinned)
  virtdev-full.slice                host + LAN + WAN (pinned)
  virtdev-<custom>.slice            custom host-hole zone (base + per-port holes; pinned)
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

  `virtdev-detach` supports in-place rebase (`qemu-img rebase -b ""`) and
  convert-then-swap (the default). Both first durably write an identity-bound
  `.detach.transaction` journal. Convert recovery either finishes a proven
  swap or restores matching original/`.bak` inodes. In-place recovery cannot
  roll back rewritten images; it publishes `detached` only after both matching
  disk inodes are proven backing-free, and otherwise preserves the journal for
  inspection. A `.bak` file without the journal is untrusted.

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

- **Backup system scope.** `virtdev-backup` captures a bounded uncompressed tar
  stream and extracts it only after validating logical bytes and every explicit
  or implicit output path. `virtdev-restore` counts unique regular-file bytes
  and entries before transfer, rejects nested mounts and intermediate symlinks,
  and gives rsync the same filesystem boundary. Every snapshot owns its inodes
  independently, so editing one restore point cannot rewrite
  another. Not planned: compression, encryption at rest, automated
  retention or rotation policy, cross-project restore, system-disk
  backup, or glob/brace expansion in manifests. Per `DESIGN.md`'s threat model the host is trusted, so
  encryption adds complexity without matching a real adversary. The
  manifest is literal (`--files-from`) to keep the contract auditable.

- **Network isolation residuals.** The passt backend (`start` and `maintain`
  paths) blocks guest→host via passt's two translation shortcuts
  (loopback-via-gateway and host-global-address), and the Phase 2 host egress
  lockdown (see VM Runtime → Host egress lockdown) drops guest→host (real LAN
  IP / `0.0.0.0`-bound services, including `sshd`) and guest→LAN by default
  across all protocols and both families. The following remain:

  - **The lockdown is opt-in to install.** It is inactive until
    `sudo virtdev firewall apply` runs (the launch guard refuses to start until
    then, override `--unfiltered`). The `owner,persist` table + resident holder
    make it flush-resistant (an external `flush ruleset` / `systemctl restart
    nftables` SKIPS it). A `user@<uid>.service` teardown churns the base inode;
    the guard fails CLOSED on the mismatch and each launch re-verifies
    post-activation. Multi-user hosts are not yet covered (the match is
    uid-specific).
  - **`install`-time guest→host**: `virtdev-install` keeps the original
    `-netdev user` SLIRP backend (accepted: short window, official signed
    repositories only, no untrusted code running during install). The
    installer does not pass through the egress lockdown.
  - passt crashing **mid-session**: the guest loses networking; the
    systemd unit continues (QEMU is the main process). No health
    supervision — notice and restart the virtual machine.
