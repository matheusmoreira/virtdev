# network — dependency supply-chain audit & lock

virtdev exists to contain supply-chain attacks against the code it runs. The
egress network stack must not become a supply-chain hole in that defense. Every
third-party crate is therefore **audited, vendored into this repo, pinned by
exact version + SHA-256 checksum, and built offline** — the build can never
silently fetch or substitute code.

**Audited:** 2026-07-19 · **Toolchain:** Arch `rust` 1.97.0 (system-signed —
one trust root with the rest of virtdev's runtime: qemu, nftables, …).

## Policy (how the lock is enforced)

- `core/Cargo.toml` (crate `network`) pins `smoltcp = "=0.13.1"` (exact) with
  `default-features = false`; every transitive version is frozen in `Cargo.lock`
  with a SHA-256 checksum.
- The repository-root `.cargo/config.toml` redirects the crates-io registry to
  `network/vendor` and sets `net.offline = true`. It applies both from the
  repository root and from `network/`.
- Verified reproducible offline: `cargo build --manifest-path
  network/Cargo.toml --locked --offline` and the matching `cargo test` command.
- **Changing a dependency requires a conscious re-audit:** bump the pin, run
  `cargo vendor`, audit the new/changed source, and update this file.

## The dependency tree (8 crates, all pure-compute, `no_std`)

    network
    └── smoltcp 0.13.1
        ├── bitflags 1.3.2
        ├── byteorder 1.5.0
        ├── cfg-if 1.0.4
        ├── heapless 0.9.3
        │   ├── hash32 0.3.1
        │   │   └── byteorder 1.5.0
        │   └── stable_deref_trait 1.2.1
        └── managed 0.8.0

| Crate | Version | crates.io downloads | License | Verdict |
|---|---|---|---|---|
| smoltcp | 0.13.1 | 6.9M | 0BSD | GREEN |
| heapless | 0.9.3 | 108M | MIT/Apache-2.0 | GREEN |
| byteorder | 1.5.0 | 696M | Unlicense/MIT | GREEN |
| bitflags | 1.3.2 | 1.54B | MIT/Apache-2.0 | GREEN |
| hash32 | 0.3.1 | 130M | MIT/Apache-2.0 | GREEN |
| stable_deref_trait | 1.2.1 | 527M | MIT/Apache-2.0 | GREEN |
| managed | 0.8.0 | 12M | 0BSD | GREEN |
| cfg-if | 1.0.4 | 1.21B | MIT/Apache-2.0 | GREEN |

SHA-256 checksums: see `Cargo.lock` (the authoritative pin).

## What was checked (per crate)

1. **Build-time code execution** — every `build.rs` read in full; the tree has
   no proc-macros and no build-dependencies.
2. **Provenance** — canonical repo, maintainer/org, download count (scrutiny
   proxy), pinned-vs-latest, yanked status, typosquat / ownership-transfer signals.
3. **Advisories** — RustSec advisory-db / OSV for each crate @ its exact version.
4. **`unsafe`** — every `unsafe` site reviewed for "standard pattern vs red flag".
5. **Capabilities** — network, process spawn, filesystem, env/secret reads, FFI,
   `include_bytes!`/blobs, obfuscation, phone-home.
6. **License** — all permissive (0BSD / MIT / Apache-2.0 / Unlicense).

## Key findings

- **Two `build.rs`, both benign.** `smoltcp` generates compile-time config
  constants into `$OUT_DIR`; `heapless` probes target atomics by compiling a
  hardcoded `clrex` snippet via `$RUSTC` into `$OUT_DIR`. Neither touches the
  network, secrets, or anything outside the build scratch dir.
- **The attacker-facing parser is unsafe-free by compiler enforcement.**
  `smoltcp` carries `#![deny(unsafe_code)]`; its `src/wire/` (packet + DNS
  parser) and `src/socket/` contain **zero** `unsafe`. All of smoltcp's `unsafe`
  lives in `src/phy/sys/*` (OS device backends behind `phy-raw_socket` /
  `phy-tuntap_interface`), which we do **not** enable — we implement our own
  `Device`.
- **Feature hygiene.** The resolved graph enables **no `std`, no `alloc`, no
  `log`, no `libc`**. `heapless` resolves with no features (no allocator
  dependency — required for the freestanding target).
- **Malformed guest input** is bounded to panic-level DoS, never memory
  unsafety (bounds-checked slices; smoltcp's DNS parser truncates
  compression-pointer loops). One network process serves one machine, so a
  panic fails that machine's egress **closed** — consistent with the threat model.

## Per-crate notes & caveats

- **smoltcp 0.13.1** — author whitequark, `smoltcp-rs/smoltcp`, latest, no
  advisories, fuzzed upstream. Requires edition 2024 / rustc ≥ 1.91 (note for
  packaging). A few `panic!`/`unwrap` remain on the parse path (accepted:
  per-machine fail-closed).
- **heapless 0.9.3** — rust-embedded WG. RUSTSEC-2020-0145 (IntoIter UAF)
  affects only `<=0.6`; 0.9.3 is unaffected and is itself the most-fixed
  release. Miri + ThreadSanitizer in CI. The lock-free `pool`/`spsc`/`mpmc` code
  is not on smoltcp's path; `mpmc` is deprecated upstream — do not use directly.
- **byteorder 1.5.0** — BurntSushi, no advisories. Read helpers are safe code;
  writes assert bounds unconditionally. Panics on short buffers — we rely on
  smoltcp's length checks (we don't call it directly).
- **bitflags 1.3.2** — no advisories ever. Terminal 1.x release but zero-defect;
  2.0 fixed no soundness bug affecting 1.3.2. Pinned by smoltcp's `^1.0`.
  `rustc-dep-of-std` stays off (confirmed).
- **hash32 0.3.1** — japaric → rust-embedded-community (documented handoff).
  Pinned 0.3.1 (latest 1.0.0) per heapless's requirement; clean, unyanked. 8
  bounds-guarded `unsafe` blocks in murmur3.
- **stable_deref_trait 1.2.1** — Storyyeller. Marker-trait only; all `unsafe` is
  empty `unsafe impl` markers, no executable unsafe. `std` stays off via
  `default-features = false` (confirmed).
- **managed 0.8.0** — smoltcp sibling (`smoltcp-rs/rust-managed`), **zero unsafe
  / zero deps** (verified two ways). Dormant/frozen since 2020 (a positive for a
  vendored dep). smoltcp enables its `map` feature (benign, still `no_std`).
- **cfg-if 1.0.4** — rust-lang org (maintained by the Rust project). One
  `macro_rules!`, zero unsafe.

## Re-audit guidance

- Periodically run `cargo audit` (or check <https://rustsec.org>) against
  `Cargo.lock` to catch advisories filed after this date.
- On any version bump: `cargo vendor`, review the source diff of changed crates
  (especially any new `build.rs` / `unsafe`), then update this file.
