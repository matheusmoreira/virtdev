# virtdev — project guide

`virtdev` is a per-project VM orchestrator built on KVM/QEMU. Each project gets
an isolated Arch Linux VM derived from a sealed base via qcow2 deltas. The
goal is hypervisor-level isolation between development environments as a
defense against supply-chain attacks (npm, etc.). Implemented as a set of
bash scripts in `bin/` with shared helpers in `lib/virtdev/`.

## Where to look first

| For | Read |
|---|---|
| User workflow, command reference, env vars | `README.md` |
| Architecture, threat model, lifecycle, qcow2 inheritance, locking model, ssh hardening, known limitations | `DESIGN.md` |
| Design specs for in-progress work | `docs/superpowers/specs/` (often untracked while in development) |
| Implementation | `bin/virtdev-*` |
| Shared bash helpers | `lib/virtdev/*` |
| ISO build inputs | `iso/` |

`README.md` and `DESIGN.md` are authoritative for what the project does and
how it's structured. Don't duplicate their content here — point to them.

## Coding conventions

### Every script in `bin/`

- Starts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Uses the library bootstrap (see below) and imports what it needs by name.
- Writes errors via `error <exit-code>` with the message on stdin (heredoc
  or here-string). `error()` is from `lib/virtdev/error`.
- Validates project-name arguments with `validate_project_name "${project}"`
  from `lib/virtdev/validate` (regex `^[a-zA-Z0-9_-]+$`, dynamically
  length-capped to fit within the 108-byte `sun_path` limit given the
  current `VIRTDEV_HOME` path).
- Acquires the exclusive virtdev lock with `lock_acquire` (or
  `lock_acquire_for_maintain` from `virtdev-maintain`) before doing anything
  that mutates virtdev state. See `DESIGN.md`'s "Concurrency and Locking"
  section for which scripts lock and why.
- Defaults `VIRTDEV_HOME` via `: "${VIRTDEV_HOME:="${XDG_DATA_HOME:-${HOME}/.local/share}/virtdev"}"`.
- Calls `arguments_parse` to parse argv and `arguments_usage` to
  generate usage lines from the spec. `arguments_parse` intercepts
  `--help` and `-h` automatically (anywhere in argv before the `--`
  terminator) and prints the usage line; consumers don't need a
  manual help intercept. `--color=yes|no|auto` is also universal —
  the parsed value is stored in `_virtdev_color_mode` for the
  terminal library.
- Sends all user-facing messages (progress, banners, warnings, success)
  to stderr. Only machine-readable output (paths, port numbers, PIDs,
  table data) goes to stdout.

### The `virtdev` dispatcher

`bin/virtdev` is the unified entry point. `virtdev start myproject`
dispatches to `virtdev-start myproject`; `virtdev help start` dispatches
to `virtdev-start --help`. Resolution order: adjacent sibling scripts
first, then `PATH`. The dispatcher does not use the arguments library
(it has its own option handling since it pre-dates the library and its
parsing needs are different). Beyond the lifecycle commands (`start`,
`stop`, `create`, `destroy`, etc.), the dispatcher also routes to
query/utility commands: `log`, `port`, `path`, `pid`, `status`, `disk`,
`monitor`, `generation`, `stale`, and `firewall`.

### Library-owned exit codes

Each library reserves the codes it uses; consumers don't override them.
Same error → same code, everywhere:

| Code | Meaning | Source |
|---|---|---|
| 2 | invalid project name | `validate_project_name` |
| 3 | project not found | `project_require` |
| 64 | usage error (unknown flag, missing value, etc.) | `arguments_parse` |
| 75 | lock contention (BSD `EX_TEMPFAIL` — retry possible) | `lock_acquire*` |
| 76 | lock setup failure (cannot create/open the lock file) | `lock_acquire*` |
| 77 | SSH key not found | `ssh_key_validate` |
| 78 | SSH key permissions too open | `ssh_key_validate` |
| 79 | invalid snapshot format | `snapshot_validate_format` |
| 80 | trigger aborted the command | `trigger_fire` |
| 81 | corrupt port file | `port_require` |
| 82 | corrupt generation file | `generation_read` |
| 83 | passt binary not found | `virtdev-netexec` shim |
| 84 | passt failed to initialise | `virtdev-netexec` shim |
| 85 | passt forward-port bind race | `virtdev-netexec` shim |
| 86 | QEMU command not found (pre-flight before exec) | `virtdev-netexec` shim |
| 87 | no port assigned (virtual machine not running) | `port_require` |
| 88 | host egress lockdown not active / stale baseline / wrong user | `firewall_require` |
| 89 | invalid zone-definition file (apply, via `firewall_zone_parse`) | `bin/virtdev-firewall` |
| 90 | QEMU exited before active (non-passt status) | `qemu_activation_classify` |
| 91 | unit did not become active before deadline | `qemu_activation_classify` |
| 92 | apply: not invoked via sudo / target identity indeterminate | `bin/virtdev-firewall` |
| 93 | apply: ruleset rejected by `nft -c` | `bin/virtdev-firewall` |
| 94 | apply: unit install / daemon-reload / enable failure | `bin/virtdev-firewall` |
| 95 | apply: ruleset installed but the holder failed to load it | `bin/virtdev-firewall` |
| 96 | holder: ruleset file missing or uid/base underivable | `bin/virtdev-firewall` |
| 97 | holder: table did not come up / baseline record failed | `bin/virtdev-firewall` |
| 98 | apply: lingering not enabled for the target user | `bin/virtdev-firewall` |
| 99 | holder: zone-slice cgroup dirs never appeared (pins not running) | `bin/virtdev-firewall` |

Per-script exit codes are still numbered locally for things that aren't
factored into a library (e.g., "project not found", "VM not running").
**Every exit code within a script must be unique** — distinct failure
modes get distinct codes so programmatic callers (like `virtdev-recreate`)
can discriminate them.

### Bootstrap (top of every consumer script)

```bash
#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1090
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/virtdev/import"

import error validate lock      # whatever this script needs
# business logic follows
```

`lib/virtdev/import` is the bootstrap module. Sourcing it provides:

- `virtdev_library_directory` — resolved path to `lib/virtdev/`
- `virtdev_bin_directory` — resolved path to `bin/`
- `virtdev_loaded_libraries` — associative array tracking loaded libraries
- `import()` — source libraries by name, idempotent

The `../lib/virtdev` path resolves correctly for both the dev tree
(`~/dev/virtdev/bin → ~/dev/virtdev/lib/virtdev`) and the pacman-installed
package (`/usr/bin → /usr/lib/virtdev`) because `readlink -f` follows
symlinks and normalises to the script's actual location. Sourced
libraries inherit the import infrastructure automatically —
composition is free.

### Argument parsing (`lib/virtdev/arguments`)

The `arguments` library provides declarative flag parsing and usage
generation. A script declares its interface via associative arrays and
the library handles `--long`, `-s` short, `--flag=value`, `--`
terminator, and clustered short flags (`-vy`).

```bash
declare -A spec=([yes]=bool [provision]=value)
declare -A spec_short=([y]=yes [p]=provision)    # optional: short aliases
declare -A spec_placeholders=([provision]=path)   # optional: usage text
declare -a spec_positionals=(project)             # optional: usage text
declare -A flags=()
declare -a positional=()
arguments_parse spec flags positional "$@"
```

Spec types: `bool` (presence/absence), `value` (takes one arg —
defaults to `""` if absent), `required` (like value, but errors if
not given). `--help`/`-h` and `--color=yes|no|auto` are reserved
universal flags handled before the spec is checked; declaring them
in a spec does not shadow the universal handling. The "required"
check is syntactic — `--flag=` counts as given; consumers needing
non-empty validation must do it after parsing.

Parsing is **GNU-style**: flags and positionals may be interleaved.
`virtdev-destroy myproject --yes` works. Use `--` to force all
remaining arguments into positional regardless of prefix — required
for scripts like `virtdev-ssh` that pass flag-like args through.

**Positional suffixes** (for `spec_positionals`, used only by
`arguments_usage`): bare name = required, `?` = optional, `+` =
variadic 1+, `*` = variadic 0+. Example: `(project "ssh-args*")`.

Companion arrays are discovered by naming convention:
`<spec>_short`, `<spec>_placeholders`, `<spec>_positionals`.

`virtdev-recreate` and `virtdev-upgrade` use `virtdev_bin_directory`
(provided by the import module) to invoke sibling scripts by resolved
path, avoiding PATH ordering issues between the dev tree and the
installed package.

### Triggers (`lib/virtdev/trigger`)

The trigger library provides `trigger_fire <event> [sys_var proj_var]`.
Triggers are user-supplied executables at two levels:

    ${XDG_CONFIG_HOME}/virtdev/triggers/<event>              (system)
    ${XDG_CONFIG_HOME}/virtdev/projects/<name>/triggers/<event>  (per-project)

**Contract:**
- Standalone executables, run as child processes (not sourced).
- Inherit the caller's full environment. virtdev exports `VIRTDEV_*`
  variables; everything else comes from the user's session naturally.
- Stdout is captured by virtdev (meaning is event-specific). Stderr
  passes through to the terminal.
- Pre-event non-zero exit: `error 80` aborts the command. Post-event
  non-zero exit: warning to stderr, no effect on command exit code.
- No arguments — all context via environment.
- Triggers determine their own applicability. virtdev fires them
  unconditionally (interactive and scripted). A trigger that should
  only act in tmux checks `$TMUX` itself.

**Interface:** `trigger_fire` accepts optional nameref variable names
for system and per-project output. When omitted, stdout is discarded
(used for post-ssh where output is irrelevant).

### SSH config assembly (`virtdev-ssh`)

`virtdev-ssh` assembles configuration from four sources via a temp
file passed to `ssh -F`. Priority order (SSH first-match-wins):

1. Per-project trigger output (most specific)
2. System trigger output
3. `${XDG_CONFIG_HOME}/virtdev/projects/<name>/ssh_config`
4. `${XDG_CONFIG_HOME}/virtdev/ssh_config`

Process substitution (`<(...)`) cannot be used because ssh opens the
`-F` path by name; the `/dev/fd/N` path is inaccessible by the time
ssh reads it. A temp file with EXIT trap cleanup is required.

The user's `~/.ssh/config` is intentionally excluded. This prevents
dangerous global settings (`ForwardAgent`, `ControlMaster`) from
leaking into untrusted VM connections.

**Trap composition in `virtdev-ssh`:** ssh runs in the foreground
(not backgrounded). An EXIT trap handles all cleanup: fires post-ssh
triggers and removes the temp file. Signal traps (INT, TERM, HUP)
simply call `exit` which triggers the EXIT trap — they do not
perform cleanup themselves, preventing double-cleanup. A
`pre_ssh_fired` guard ensures post-ssh only fires if pre-ssh
succeeded.

### Library file rules (`lib/virtdev/*`)

Library files are sourced into the calling shell. They share the caller's
variable scope, process, and shell options:

1. **Set strict mode at the top.** Each library starts with
   `set -euo pipefail`. Don't trust the caller; establish the contract on
   the library's own terms.
2. **Functions and constants only.** No top-level business logic. Sourcing
   a library must be free of side effects beyond function definitions,
   constants, and idempotent env-var defaulting.
3. **No `exit` — use `return`.** `error()` is the documented exception
   (intentionally terminal — treat it as `panic()`). Any other helper that
   exits the process is a bug.
4. **`local` for everything inside functions.** If a global must escape,
   namespace it with `VIRTDEV_*` so the consumer can see the contract.
   Top-level `declare -A` in a library creates a variable local to
   `import()` (since libraries are sourced from within that function).
   Use `declare -gA` for associative arrays that must be global.
5. **`readonly` for true constants only.** Library-level values that
   don't depend on mutable env vars get `readonly` (or `declare -r`)
   so they can't be accidentally rebound by a consumer. Values
   *derived* from mutable env vars (`VIRTDEV_HOME`, etc.) must be
   computed inside the functions that use them — `local -r` at
   function entry preserves immutability without freezing the env
   var's source-time value (which would break any consumer that
   rebinds the env var after `import`).
6. **Self-contained dependencies.** Each library imports the libraries it
   uses (e.g., `validate` does `import error` because it calls `error()`)
   and self-defaults the env vars it reads (e.g., `lock` defaults
   `VIRTDEV_HOME`). The consumer doesn't need to know a library's
   dependency chain or env-var requirements.
7. **Library-owned exit codes.** Each library reserves the exit codes it
   uses and documents them in its header.
8. **Naming: `<library>_<verb>_<rest>`.** The library prefix is the
   subsystem noun (`lock`, `validate`); the rest follows verb-noun
   (`acquire`, `acquire_for_maintain`, `project_name`). No `__` prefix,
   no `virtdev_` namespace — the library is internal-only and descriptive
   names are sufficient.
9. **No file extension.** Files are imported as `import lock`, not
   `import lock.sh`.
10. **Header comment documents the contract.** A short block at the top
    names the public functions, their arguments, and any exit codes the
    library reserves.

### Imports

The `import` function de-duplicates via `virtdev_loaded_libraries` —
sourcing the same library twice (transitively or via duplicate `import`
calls) is a one-line check, not a re-source. The flag is set *before* the
source call so circular imports terminate at the second entry rather than
recursing forever.

## Verification gates

After any change to `bin/` or `lib/virtdev/`:

```bash
bash -n bin/virtdev-* lib/virtdev/*       # syntax
shellcheck bin/virtdev-* lib/virtdev/*    # lint
```

Plus a smoke test of the affected script via real invocation. Don't claim a
change is done without running these. There's no formal test suite; the
scripts are the contract.

`.shellcheckrc` enables `external-sources=true` so shellcheck follows
`source -p` into the library files when warnings are suppressed for SC1090
at the call site.

## Bug patterns to watch for

These six recurring failure modes were extracted from the 2026-04-25
review and a series of hardening passes. Walk this list before declaring
a feature complete:

1. **Captured-but-unused metadata.** Don't read a value into a variable
   and then never use it (or use it only for a log line that nobody reads).
   Either make it load-bearing, or drop it.
2. **Asymmetric pairs.** A pre-flight check has a corresponding teardown;
   a setup has a corresponding cleanup; a writer has a corresponding
   validator. Missing the inverse half causes silent skew. Audit every
   "X happens here" for "where does X get cleaned up / validated / undone".
3. **TOCTOU on teardown.** Reading state and then acting on it without
   re-checking under the lock leaks a race. Particular hazards: VM
   running checks, port-bind checks, file-existence checks before `rm`.
4. **Cross-process state needs sync.** Anything systemd, anything fd-9
   flock, anything in `${VIRTDEV_HOME}/projects/<name>/` that another
   virtdev script might also touch — needs deliberate synchronization,
   not just "the lock is held". `virtdev-stop`'s ACPI vs SIGTERM
   escalation, `virtdev-start`'s post-systemd-run wait, and
   `virtdev-maintain`'s reset-failed coordination with `virtdev-stop`
   are the canonical examples.
5. **Doc-vs-tool drift.** When the docs say "X happens" but the tool no
   longer does X (or never did), users plan against the docs and get
   surprised. After any behavior change, grep `README.md`, `DESIGN.md`,
   and the script header comments for the old behavior.
6. **Unprotected critical sections.** Multi-step mutations (rename-aside,
   move-in, write-marker, remove-old) need signal traps around the
   critical section and auto-recovery on re-entry. `virtdev-detach`
   implements this pattern: `trap '' INT TERM HUP QUIT` before the
   swap, restore after, and `.bak`-detection recovery at the top of
   the script. `virtdev-maintain` avoids the problem entirely via
   `virtdev-exchange` (`renameat2(2)` with `RENAME_EXCHANGE`), which
   atomically swaps `system/` and `maintenance/` in a single syscall.
   Prefer atomic operations when possible; use signal traps when
   multi-step mutations cannot be avoided.

The meta-habit is "finish the 'and then what?' question" — when adding
or modifying a behavior, walk forward through what depends on it and
backward through what it depends on.

## Build and packaging

`PKGBUILD` (and `.SRCINFO`) ship the project as `virtdev-git` for the AUR.
Install layout:

- `bin/virtdev-*` → `/usr/bin/virtdev-*` (mode 755)
- `lib/virtdev/*` → `/usr/lib/virtdev/*` (mode 644)
- `systemd/virtdev-firewall.service` → `/usr/lib/systemd/system/` (holder)
- `systemd/virtdev-firewall-pin@.service` → `/usr/lib/systemd/user/` (pin; `--user`, NOT system)
- `iso/*` → `/usr/share/virtdev/profile/*`
- Docs → `/usr/share/doc/virtdev/`

`bash >= 5.2` required (for `source -p`). `passt` is a runtime
dependency added to `depends` in `build/aur/PKGBUILD`. `.gitignore`
excludes the `build/` tree from `makepkg`.

**Note:** `bin/virtdev-netexec` is a bash shim (not compiled C), so no
`GNUmakefile` change is needed — the `find bin/ ! -name '*.c'` install
glob in `PKGBUILD` picks it up automatically.

## Common gotchas

- **`VIRTDEV_HOME`** default is `${XDG_DATA_HOME:-${HOME}/.local/share}/virtdev`.
  Every script defaults it consistently.
- **Project name `maintenance`** is reserved by `virtdev-maintain`. The
  reservation is enforced at `virtdev-create` time. `virtdev-stop` skips
  lock acquisition when the target is `maintenance` — that's the
  documented abort path for a stuck maintenance session.
- **Sealed files (`system/*`)** are mode 444 by `chmod 444 system/*` glob
  in `virtdev-seal` and `virtdev-maintain`. Adding new files to `system/`
  means they get swept by the chmod too — fine today, but relevant for
  any future in-place update to a sealed file.
- **Backup and restore over SSH.** Both run rsync to/from the running
  guest's filesystem; the host does not touch `projects/<name>/*.qcow2`.
  Neither acquires the virtdev lock (see `DESIGN.md`'s "Concurrency and
  Locking" section for the full reasoning). The realistic concurrency
  hazard is `virtdev-stop` mid-transfer, which manifests as a noisy rsync
  failure handled by the PIPESTATUS distinction in both scripts.
- **Generation counter.** `virtdev-seal` writes the initial counter as `1`
  to `system/generation`; `virtdev-maintain` increments on reseal.
  `virtdev-create` copies the current value into the project's
  `projects/<name>/generation`; `virtdev-start` refuses to boot if the
  project's counter doesn't match the base's. Valid contents: a single
  non-negative integer, or the literal `detached` (written by
  `virtdev-detach`). Detached projects skip the generation check entirely.
  The `virtdev-list` GENERATION column and `virtdev-stale` use these files.
- **systemd `--user` units.** Project VMs run as transient
  `virtdev-<project>.service` units via `systemd-run --user`.
  `--collect` is intentionally omitted so failed units persist for
  `ExecMainStatus` queries until `reset-failed` clears them.
  `virtdev-start` calls `reset-failed` pre-launch; `virtdev-stop` calls
  it post-stop *unless* the target is `maintenance` (which would race
  `virtdev-maintain`'s own reset-failed coordination).
- **fw_cfg hostname injection.** `virtdev-start` passes
  `-fw_cfg name=opt/virtdev/project,string=<name>` to QEMU. The guest
  reads this at boot (via a systemd unit) and sets the machine's hostname
  from it. This is how each virtual machine knows its own project name
  without per-project disk customization.
- **Serial console autologin.** The guest's serial console (`ttyS0`)
  auto-logs in as the `dev` user. This is emergency access for when SSH
  is unavailable (e.g., network misconfiguration). Reachable from the
  host via `socat - UNIX-CONNECT:${VIRTDEV_HOME}/projects/<project>/console.sock`.
- **Lock visibility.** `${VIRTDEV_HOME}/lock` is a normal file with the
  current holder's PID written into it. `cat` it during a contention
  error to see who holds it. The library reads `/proc/<pid>/cmdline`
  to detect when the holder is `virtdev-maintain` and emits a
  maintenance-specific message instead of the generic one.
- **passt network backend.** `virtdev-start` and `virtdev-maintain` use
  passt instead of QEMU SLIRP (`-netdev user`). The exec-shim
  `bin/virtdev-netexec` starts passt (with `--map-host-loopback none` and
  `--map-guest-addr none` to block guest→host translations), then `exec`s
  QEMU. QEMU uses `-netdev stream,addr.type=unix,addr.path=<passt.sock>`
  to connect. The keystone invariant: passt creates the socket *before*
  forking to background, so a zero exit from passt means QEMU can connect
  immediately. The unit's `ExecMainStatus` is the shim's exit code when
  it fails before exec (83/84/85, or 86 when the QEMU pre-flight finds
  no binary); after exec it is QEMU's code.
  `virtdev-install` is unchanged (keeps SLIRP). `passt` is a required
  dependency; see `PKGBUILD` `depends` and `README.md` Requirements.
- **passt.sock cleanup.** `passt.sock` lives next to `monitor.sock` and
  `console.sock` in the per-project directory. It is removed by
  `virtdev-stop`'s `stop_finalize`, by `virtdev-maintain`'s
  `maintenance_cleanup` and its pre-launch sweep in `maintenance_boot`,
  and by `virtdev-start`'s `cleanup_failed_start` trap and stale-socket
  sweep. `virtdev-netexec` unlinks it before each
  passt start (`passt_socket_clean`) — passt's `bind()` returns
  `EADDRINUSE` on a leftover socket file.
- **Per-project directory permissions (mode 0700).** `virtdev-create`
  and `virtdev-maintain` create project directories with mode 0700.
  `lib/virtdev/lock` (`lock_open`) runs `chmod 0700
  ${VIRTDEV_HOME}` on every lock acquisition to harden pre-existing
  installs. This protects the socket files (`passt.sock`, `monitor.sock`)
  from other local users.
- **Host egress lockdown (Phase 2 network isolation).** A host-root nftables
  `inet virtdev` table (`lib/virtdev/firewall` policy + `bin/virtdev-firewall`
  root tool + a resident holder unit and a `--user` pin template under
  `systemd/`) filters guest egress per **zone**, matched to the machines'
  systemd `--user` slice cgroups. `nftables` is a runtime dependency. The
  ruleset is project-agnostic (no per-project content) and EXTENSIBLE with custom
  zones: one base jump narrows to `virtdev.slice` (every machine, by cgroup
  ancestry — scoped, catches descendants only), then one jump per slice-owning
  zone (built-in relaxation + customs). Key invariants:
  - **Four built-in zones + custom zones, deny-by-default.** `none` (nothing but
    your SSH session), `wan` (the internet; host + LAN blocked), `lan` (host + LAN,
    no WAN), `full` (host + LAN + WAN — the explicit opt-out of host isolation;
    host and LAN move together), plus user-authored custom zones (a built-in base
    + per-port host holes in `~/.config/virtdev/zones/<name>`, realized at
    `apply`). Built-ins are a static array (`firewall_zone_known`); the realized
    set (built-ins + customs) is the root-owned manifest
    `/etc/virtdev/firewall.zones`, the single source the rootless launch reads.
    The default is `none` — both an omitted `--zone` and an absent/invalid project
    `zone` file fall to it.
  - **Every launch passes `--slice`.** `firewall_slice_for <zone>` →
    `virtdev-<zone>.slice` is the single helper producing slice names;
    `virtdev-start`, `virtdev-maintain`, and the ruleset generator all call it.
    Slices are SHARED across projects (the collapse): identity stays in the unit
    name `virtdev-<project>.service`, so there is no per-project slice and no
    `systemd-escape` (deleted — the zone vocabulary is fixed and validated).
  - **Per-project default zone.** Host-side
    `${XDG_CONFIG_HOME}/virtdev/projects/<name>/zone` (`firewall_zone_default`,
    fail-closed to `none`, host-controlled only — the guest has no path to it).
    `--zone` overrides per launch; `--unfiltered` bypasses `firewall_require`
    with a loud warning.
  - **Resident pins materialise the cgroups.** A started-but-empty slice has no
    cgroup dir, so nft (which resolves cgroup paths to inodes at load) cannot
    reference it. `virtdev-firewall-pin@<zone>.service` (`sleep infinity`,
    `Restart=always`, one per relaxation zone — `wan`/`lan`/`full` and every
    custom zone, enabled `--now` and reconciled by `apply`) holds those slices and
    their parent `virtdev.slice` with stable inodes. **Linger is required** so they
    run boot→shutdown.
  - **The guard is fail-closed on staleness.** `firewall_require` (and the
    shared `firewall_is_active` behind `status`/`list`) checks the holder is
    `active` AND the recorded base inode (`/etc/virtdev/firewall.base`, written
    by the HOLDER post-load) still matches the live `virtdev.slice` — a
    `user@<uid>.service` teardown churns that inode and reads down. No `nft list`
    (root-only); the `owner,persist` holder asserts the table transitively. The
    guard additionally requires the caller to BE the firewall's uid. It runs
    before the lock in `virtdev-start` and before both boots in
    `virtdev-maintain`; both then re-verify post-launch via the unit's live
    `ControlGroup` (`firewall_assert_unit_filtered`) to close the guard→launch
    TOCTOU, tearing the unit down on a mismatch (start exit 21 / maintain 25).
  - **`apply` is root, runtime is rootless.** `sudo virtdev firewall apply`
    requires linger (98), validates `SUDO_UID` (never bakes a guessed uid),
    **copies** (never symlinks) the holder → `/etc/systemd/system` and the pin →
    `/etc/systemd/user` (user-vs-system, NOT by file extension) and starts the
    pins AS THE USER, then constructs (never searches) the cgroup base, generates
    → `nft -c` → atomic `rename(2)`, and restarts the holder. The holder derives
    uid+base from the installed ruleset, waits for the pin-backed cgroup dirs
    (99 on timeout), loads, verifies, and records `firewall.base`. The package
    ships `/usr/lib/systemd/{system,user}`.
  - **maintenance runs in `wan`** (needs WAN for `pacman -Syu`; trusted base, no
    host/LAN). Its running-machine preflight glob excludes the pins
    (`virtdev-firewall-pin@*.service`, permanent under linger).
    `virtdev-recreate`/`virtdev-upgrade` restore a running machine's captured
    zone and otherwise pass NO `--zone` (so `virtdev-start` reads the zone file).
  - **`virtdev-status` stdout is unchanged** — the ZONE column lives only in
    `virtdev-list` (a ZONE token in status would break `grep -q running`).

## Process notes

- **Design specs and dev narrative stay uncommitted.** This repo's
  convention is to leave design/brainstorm docs as untracked files in
  `docs/superpowers/`; the user strips dev narrative and publishes
  distilled versions after feature completion.
- **Per-step verification gate.** When refactoring, each commit ends in
  a verified state: `bash -n` clean, `shellcheck` clean, smoke test
  passes. No "let's revisit later" — fix in place before moving on.
