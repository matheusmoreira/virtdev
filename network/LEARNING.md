# LEARNING.md — Rust, for a C programmer

A running reference, built as we implement virtdev's network stack. Each entry: the Rust
thing, then the closest C mental model.

## Workflow

- **TDD loop:** write a failing test (the WHAT) → *watch it fail* (proves the
  test works) → minimal code to pass (the HOW) → refactor. `cargo test`.
- **Read the compiler / test output.** A failed `assert_eq!` *panics*; the test
  harness catches it and prints `left` (got) vs `right` (expected).
- **clippy** = idiom linter (`cargo clippy`); **rustfmt** = formatter (`cargo fmt`).
- Debug output prints bytes in **decimal** (`0xDE` → `222`).
- **The type checker is the first test.** Changing a function's return type makes
  every caller *fail to compile* until updated — `error[E0308]: mismatched types`
  at each site. In TDD that compile failure IS the RED: write the test against the
  new shape, watch it fail to build, then grow the code to match. A type error
  anywhere in a test module blocks the *whole* test binary — nothing runs until it
  compiles (unlike a dynamic language, where one broken test errors in isolation).

## Types & memory

- **`&[u8]`** — a *slice*: a fat pointer = `(pointer, length)` in one value. C's
  `(const uint8_t *buf, size_t len)` pair, bundled, with every index
  bounds-checked. `&` = *borrow* (you don't own it; can't outlive the owner).
- **`&buf[4..4+len]`** — a sub-slice over the half-open range `[start, end)`.
  Like `buf + 4` with length `len`, but panics instead of reading out of bounds.
- **Returning `&[u8]` that borrows the input** — zero-copy (no allocation). The
  compiler infers the lifetime (`fn f<'a>(x: &'a [u8]) -> &'a [u8]`) and proves
  the result can't outlive `x`. C: `return buf+4;` and *hope* the caller keeps
  `buf` alive — Rust proves it at compile time.
- **`usize`** = `size_t` (pointer-sized unsigned; slice indices are `usize`).
- **`as`** = an explicit, non-fallible cast (`u32 as usize`).

## Tuples & multiple returns

- **`(&[u8], usize)`** — a *tuple*: several values bundled into one anonymous,
  fixed-size struct, accessed positionally (`.0`, `.1`) rather than by name. C
  has no multiple return — you'd pass an out-param (`size_t *consumed`) or
  declare a named `struct`. A tuple is zero-cost: returned in registers, no
  allocation.
- **Destructuring** — `let (payload, consumed) = decode(buf)?;` pulls the pair
  apart by pattern in one line, like unpacking the fields of a returned struct.
- **Threading a cursor** — `decode` stays *single-frame* (dumb): it returns the
  payload plus `consumed` (`4 + len`), and the caller advances `&buf[consumed..]`
  and decodes again. `&buf[n..]` is the tail sub-slice — `buf + n` with the
  remaining length, bounds-checked. Iterating over many frames lives in the
  *caller*, not the codec: no array/`Vec` of frames, each stays borrowed in place
  in the read buffer (stack-friendly, alloc-free).

## Option — "maybe"

- **`Option<T>`** = `Some(T)` | `None`. C's "return `NULL` for none," but the
  type *forces* the caller to handle `None` — no accidental use of a missing value.
- **Why `Some(T)`, not bare `T | None`:** `Option` is a *tagged* sum type. The tag
  (a) works for any `T` (a `u32` has no spare "none" value the way a pointer has
  `NULL`), (b) nests — `Option<Option<T>>` keeps `Some(None)` distinct from `None`,
  (c) forces the check. And when `T` has a spare value it's free: `Option<&[u8]>` is
  the same size as `&[u8]` (niche optimization — `None` = null pointer).

## Control flow & safety

- **Tail expression = return.** A block's last expression *with no `;`* is its
  value / the function's return. `return x;` is only for *early* exits.
- **Early return as a guard.** `if buf.len() < 4 { return None; }` before indexing
  is the C `if (len < 4) return NULL;` habit — but here it also *prevents a panic*:
  without it, `buf[2]` on a 2-byte slice panics (bounds check). C would silently
  overread past the buffer (UB / info-leak); Rust either panics or, once guarded,
  returns `None`. Turning a would-be overread into an explicit `None` is the whole
  game when parsing untrusted guest bytes.

## Bytes & endianness

- **`u32::from_be_bytes([b0,b1,b2,b3])`** — build a `u32` from 4 bytes,
  big-endian. Replaces C's `ntohl(*(uint32_t*)p)` but with **no alignment UB**
  and **no host-endian dependence**. (`_le_bytes` / `_ne_bytes` variants exist.)

## no_std

- **`#![cfg_attr(not(test), no_std)]`** — the shipping crate is `no_std` (never
  links libstd); under `cfg(test)` we drop it so the ordinary test harness
  (which needs `std`) can run. `core` is always available; it's `std` minus the
  OS/allocation bits.

## Project facts worth remembering

- QEMU `-netdev stream` wire format: 4-byte **big-endian** length prefix (payload
  length, prefix not counted) + raw L2 frame; no virtio-net header. QEMU is the
  socket *client* (`server=off`), so our binary is the *server*.
