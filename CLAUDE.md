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
  from `lib/virtdev/validate` (regex `^[a-zA-Z0-9_-]{1,100}$` — NAME_MAX-safe
  and `sun_path`-safe).
- Acquires the exclusive virtdev lock with `lock_acquire` (or
  `lock_acquire_for_maintain` from `virtdev-maintain`) before doing anything
  that mutates virtdev state. See `DESIGN.md`'s "Concurrency and Locking"
  section for which scripts lock and why.
- Defaults `VIRTDEV_HOME` via `: "${VIRTDEV_HOME:="${XDG_DATA_HOME:-${HOME}/.local/share}/virtdev"}"`.
- Calls `arguments_parse` to parse argv and `arguments_usage` to
  generate usage lines from the spec. `arguments_parse` intercepts
  `--help` and `-h` automatically (anywhere in argv before the `--`
  terminator) and prints the usage line; consumers don't need a
  manual help intercept.

### The `virtdev` dispatcher

`bin/virtdev` is the unified entry point. `virtdev start myproject`
dispatches to `virtdev-start myproject`; `virtdev help start` dispatches
to `virtdev-start --help`. Resolution order: adjacent sibling scripts
first, then `PATH`. The dispatcher does not use the arguments library
(it has its own option handling since it pre-dates the library and its
parsing needs are different).

### Library-owned exit codes

Each library reserves the codes it uses; consumers don't override them.
Same error → same code, everywhere:

| Code | Meaning | Source |
|---|---|---|
| 2 | invalid project name | `validate_project_name` |
| 64 | usage error (unknown flag, missing value, etc.) | `arguments_parse` |
| 75 | lock contention (BSD `EX_TEMPFAIL` — retry possible) | `lock_acquire*` |
| 77 | SSH key not found | `ssh_key_validate` |
| 78 | SSH key permissions too open | `ssh_key_validate` |
| 79 | invalid snapshot format | `snapshot_validate_format` |

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
not given). `--help`/`-h` is reserved by the library; declaring
either in a spec does not shadow the universal handling. The
"required" check is syntactic — `--flag=` counts as given; consumers
needing non-empty validation must do it after parsing.

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

These five recurring failure modes were extracted from the 2026-04-25
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

The meta-habit is "finish the 'and then what?' question" — when adding
or modifying a behavior, walk forward through what depends on it and
backward through what it depends on.

## Build and packaging

`PKGBUILD` (and `.SRCINFO`) ship the project as `virtdev-git` for the AUR.
Install layout:

- `bin/virtdev-*` → `/usr/bin/virtdev-*` (mode 755)
- `lib/virtdev/*` → `/usr/lib/virtdev/*` (mode 644)
- `iso/*` → `/usr/share/virtdev/profile/*`
- Docs → `/usr/share/doc/virtdev/`

`bash >= 5.2` required (for `source -p`). `.gitignore` excludes the
`build/` tree from `makepkg`.

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
- **Version counter.** `virtdev-seal` writes the initial counter as `1`,
  `virtdev-maintain` increments on reseal. `virtdev-create` copies the
  current value into the project; `virtdev-start` refuses to boot if the
  project's counter doesn't match the base's. Files must be a single
  non-negative integer; everything else is a hard error.
- **systemd `--user` units.** Project VMs run as transient
  `virtdev-<project>.service` units via `systemd-run --user`.
  `--collect` is intentionally omitted so failed units persist for
  `ExecMainStatus` queries until `reset-failed` clears them.
  `virtdev-start` calls `reset-failed` pre-launch; `virtdev-stop` calls
  it post-stop *unless* the target is `maintenance` (which would race
  `virtdev-maintain`'s own reset-failed coordination).
- **Lock visibility.** `${VIRTDEV_HOME}/lock` is a normal file with the
  current holder's PID written into it. `cat` it during a contention
  error to see who holds it. The library reads `/proc/<pid>/cmdline`
  to detect when the holder is `virtdev-maintain` and emits a
  maintenance-specific message instead of the generic one.

## Process notes

- **Design specs and dev narrative stay uncommitted.** This repo's
  convention is to leave design/brainstorm docs as untracked files in
  `docs/superpowers/`; the user strips dev narrative and publishes
  distilled versions after feature completion.
- **Per-step verification gate.** When refactoring, each commit ends in
  a verified state: `bash -n` clean, `shellcheck` clean, smoke test
  passes. No "let's revisit later" — fix in place before moving on.
