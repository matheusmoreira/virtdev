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

## Structs, methods & constructors

- **Associated function (constructor)** — `fn empty() -> Self` / `fn new() ->
  Self` take no `self`; you call them on the *type* (`FrameSlot::empty()`), like
  a C `foo_create()` factory. `Self` inside = the type being defined; `Self {
  field: … }` builds an instance.
- **`&self` vs `&mut self`** — the method receiver's borrow. `&self` = read-only
  view (many at once, can't mutate); `&mut self` = exclusive mutable access (one
  at a time, may mutate). C: `const T *this` vs `T *this`, but exclusivity is
  compiler-enforced, not a convention.
- **`const fn`** — a function evaluable at *compile time* (C++ `constexpr`), so
  its result can initialize a `const`/`static`. Matters for the freestanding
  binary, which builds state without a runtime.
- **`copy_from_slice(src)`** — a length-checked `memcpy`: destination and `src`
  must be the *same length* or it panics. `buf[..n].copy_from_slice(f)` copies
  `f`'s `n` bytes into the front of `buf`.
- **`Default`** — the conventional "empty/zero value" constructor: `T::default()`.
  clippy asks for it beside any no-arg `new()` so generic code can build a `T`
  without naming the concrete constructor.
- **Newtype over a borrow** — `struct QemuRxToken<'a>(&'a mut FrameSlot);` — a
  tuple struct wrapping one reference. Zero-cost (same layout as the reference),
  but a *distinct type* you can hang trait impls on (here smoltcp's `RxToken`).
- **`#[non_exhaustive]`** — a library marks a struct/enum so downstream crates
  can't build it with a literal or match it without a `_ =>` arm; you construct
  via `default()` + field sets. Lets the library add fields/variants later without
  breaking you (forward-compat). C: a struct whose initializer the library owns.

## Option — "maybe"

- **`Option<T>`** = `Some(T)` | `None`. C's "return `NULL` for none," but the
  type *forces* the caller to handle `None` — no accidental use of a missing value.
- **Why `Some(T)`, not bare `T | None`:** `Option` is a *tagged* sum type. The tag
  (a) works for any `T` (a `u32` has no spare "none" value the way a pointer has
  `NULL`), (b) nests — `Option<Option<T>>` keeps `Some(None)` distinct from `None`,
  (c) forces the check. And when `T` has a spare value it's free: `Option<&[u8]>` is
  the same size as `&[u8]` (niche optimization — `None` = null pointer).
- **`.unwrap()`** — on `Some(x)` returns `x`; on `None` it *panics* (aborts with a
  message + source location). Reads as "I assert this is `Some`; if I'm wrong,
  crash loudly here rather than carry a bad value forward." C analogy:
  dereferencing a pointer you're *sure* is non-NULL — except a wrong guess is a
  clean panic, not undefined behavior. Fine in **tests** (a `None` there means the
  test itself is broken, so panicking fails it). Avoided on **production paths** —
  there we handle both arms explicitly (`match`, `if let`, `let … else`, `?`) so
  there is no hidden abort. `Result` has the same `.unwrap()`, panicking on `Err`.
- **`Option::map(f)`** — `x.map(f)` applies `f` to the inner value when `Some`
  and passes `None` through: `Some(3).map(double) == Some(6)`, `None.map(double)
  == None`. Transforms the inside without an `if`/`match` or an unwrap.
- **`?` on `Option`** — `self.inbound.get()?;` returns `None` from the *enclosing
  function* when the value is `None`, else yields the inner value. The
  early-return guard as one character — the C `if (!x) return NULL;` habit, built
  into the language (works on `Result` too, propagating the `Err`).

## Enums & pattern matching

- **`enum` with data** = a *tagged union* (sum type). Each variant may be empty
  (`Incomplete`) or carry fields, tuple- or named struct-style
  (`Complete { payload, consumed }`). C: a hand-rolled `struct { enum tag; union
  {…}; }`, but tag and payload are fused, the compiler forces you to handle
  every variant, and the size is `tag + largest variant` (minus niche savings).
  This *is* a little state machine: one value, exactly one of N states.
- **`Decoded<'a>` / `Decoded<'_>`** — the enum takes a *lifetime parameter*
  because a variant borrows (`Complete.payload: &'a [u8]`). Writing the return
  type `Decoded<'_>` means "a borrow lives in here; infer its lifetime"
  (elision) — the compiler proves the payload can't outlive the input `buf`.
- **`#[derive(Debug, PartialEq)]`** — auto-generate impls: `Debug` = a `{:?}`
  dump, `PartialEq` = structural `==` (field-by-field). C: you'd hand-write a
  compare and a print helper. Lets `assert_eq!` work on the enum.
- **Refutable patterns need a home.** A plain `let PAT = expr;` requires PAT to
  *always* match (irrefutable). A single-variant pattern is *refutable*, so the
  compiler (E0005) makes you use `match`, `if let`, or `let … else`.
- **`let … else`** — `let Decoded::Complete { payload, consumed } = decode(buf)
  else { return; };`. Binds the fields if the pattern matches; otherwise runs a
  block that *must diverge* (`return`/`panic!`/`break`). The idiomatic
  `.unwrap()` replacement for a data-carrying enum: name the happy path, handle
  the rest explicitly. C: `if (r.tag != COMPLETE) bail(); /* use r.fields */`,
  but the bindings only come into scope *after* the guard.
- **field-init shorthand** — `Complete { payload, consumed }` when the local
  names match the fields (short for `payload: payload, consumed: consumed`).
- **`matches!(x, Decoded::Oversized)`** — a boolean "is it this variant?" test
  without a full `match`; handy when you don't need the fields.

## Generics, traits & lifetimes

- **`T: Trait`** = a bounded type parameter, "any `T` that implements `Trait`."
  Java's `<T extends Bound>` is the right first intuition, with two differences:
  Rust **monomorphizes** (like C++ templates — a specialized, inlined copy per
  concrete type; zero-cost, no boxing) where Java **erases** to `Object` + casts
  at runtime; and the bound is a *trait* (behavior, implementable even for
  primitives/foreign types), not class inheritance.
- **Monomorphization: cost & escape hatch.** One copy per *distinct* concrete
  type (call sites sharing a type share the copy), so code size grows with type
  *variety*, not usage — and dead-code elimination + inlining claw much of it
  back; our concrete types are few, so it is negligible here. When you instead
  want *one shared copy* (dynamic dispatch), use **`dyn Trait`**: a fat pointer
  (data ptr + vtable), exactly Java/C++ virtual calls — smaller code, one
  indirection per call. The classic space-vs-speed dial.
- **`Self` vs `self`** — capital `Self` = *the type* implementing the trait
  (shorthand for its name); lowercase `self` = *the instance* (C++ `this`, but a
  value). `fn consume(self, …)` takes `self` **by value** — moves the receiver
  in — which is what makes a call *consume* it.
- **Lifetime `'a`** — a compile-time *name* for "the region a reference stays
  valid." Pure compile-time, zero runtime cost. C: the "is this pointer still
  alive?" question you track in your head and lose to use-after-free; Rust writes
  it down and the borrow checker proves it. `Foo<'a>` holds a ref valid for `'a`.
- **What a lifetime *is* to the compiler.** Erased before codegen — at runtime a
  `&'a T` is just a pointer (same bytes as C). Borrow-checking is a *static* pass:
  each borrow gets a *region* (the CFG points where it is still used later), and
  the checker proves the referent stays valid across that whole region. `Self: 'a`
  / `'a: 'b` are *outlives* constraints — plain region-containment (`⊇`) — solved
  like inequalities. Annotations exist only to connect borrows *across* function
  signatures, where the checker can't see into the callee. Exhaustive
  compile-time pointer-provenance analysis, made a hard error — not a runtime value.
- **`'_`** — the *elided* lifetime: "a lifetime goes here; infer which one."
  `RxToken<'_>` returned from `receive(&mut self)` = "the token borrows from
  `&mut self`; tie its lifetime to that borrow."
- **`where Self: 'a`** — "the type `Self` outlives `'a`." Needed because the
  token (parameterized by `'a`) borrows the device (`Self`); the device must live
  at least as long as the token. The compiler keeping the borrow sound.
- **Two generic scopes on one trait** — `type RxToken<'a>` puts the *lifetime* on
  the **type** (it borrows for `'a`); `fn consume<R, F>(…)` puts the *type params*
  `R, F` on the **method** (closure type + return, chosen per call site).
- **GAT (generic associated type)** — an associated type that itself takes a
  parameter: `type RxToken<'a>` is a *family* of types, one per lifetime `'a` — a
  type-level function from a lifetime to a type. Needed when a trait method
  returns something borrowing `self` for a caller-chosen lifetime (each `receive`
  call has its own). The impl fills the family: `type RxToken<'a> =
  QemuRxToken<'a> where Self: 'a` (the `where` echoes the trait's required bound).
  Stabilized Rust 1.65 (late 2022).
- **Split borrows** — you can hold two `&mut` into *different fields* of one
  struct at once (`&mut self.inbound` and `&mut self.outbound`); the borrow
  checker is field-sensitive. C: two pointers into different members — obviously
  fine — except Rust *proves* they don't alias. This is why the device keeps
  inbound/outbound as separate fields: `receive` hands out both at once.
- **`impl Trait` in argument position** — `f: impl FnOnce(&mut [u8]) -> R` is
  shorthand for an anonymous generic `<F: FnOnce(&mut [u8]) -> R>`. Monomorphized
  like any generic; just terser when you don't need to name the type.
- **Orphan rule** — you may `impl` a trait for a type only if you own the trait
  *or* the type. We own `QemuDevice`, so we can implement smoltcp's `Device` for
  it. Stops two crates writing conflicting impls for a pair they both merely
  import. (C has no traits, so no analogue.)

## Closures (Fn / FnMut / FnOnce)

- A **closure** = a function value that captures its environment: a code pointer
  plus a hidden struct of captured variables. Three traits, by how they use the
  captures / how often they can run:
  - **`Fn`** — reads captures by `&`; callable any number of times.
  - **`FnMut`** — mutates captures by `&mut`; callable many times.
  - **`FnOnce`** — may **move** a captured value out of itself; that consumes the
    closure, so it runs **exactly once** (called via `self`, by value).
- **`f: F where F: FnOnce(&[u8]) -> R`** — `consume` asks only for `FnOnce`
  because it calls `f` once. `FnOnce` is the *weakest* bound, so it is the most
  accepting: an `Fn` or `FnMut` closure also satisfies it, and the caller may
  pass any of them. C: a one-shot callback allowed to consume its captured state.

## Control flow & safety

- **Tail expression = return.** A block's last expression *with no `;`* is its
  value / the function's return. `return x;` is only for *early* exits.
- **Early return as a guard.** `if buf.len() < 4 { return None; }` before indexing
  is the C `if (len < 4) return NULL;` habit — but here it also *prevents a panic*:
  without it, `buf[2]` on a 2-byte slice panics (bounds check). C would silently
  overread past the buffer (UB / info-leak); Rust either panics or, once guarded,
  returns `None`. Turning a would-be overread into an explicit `None` is the whole
  game when parsing untrusted guest bytes.
- **`debug_assert!(cond)`** — like C's `assert()` under `NDEBUG`: checked in
  debug/test builds, *compiled out* in release. Use it for *internal invariants
  the producer guarantees* (here: our own frames never exceed `MAX_FRAME_LEN`).
  `assert!` is the always-on version. A tripped assertion panics — in a
  freestanding binary that means abort, so egress fails closed. Contrast
  `decode`, which meets *untrusted* guest input with a typed variant, not an
  assert.

## Bytes & endianness

- **`u32::from_be_bytes([b0,b1,b2,b3])`** — build a `u32` from 4 bytes,
  big-endian. Replaces C's `ntohl(*(uint32_t*)p)` but with **no alignment UB**
  and **no host-endian dependence**. (`_le_bytes` / `_ne_bytes` variants exist.)
- **`(n as u32).to_be_bytes()`** — the inverse: a `u32` → `[u8; 4]`, big-endian.
  Replaces `htonl` + a manual serialize; returns a fixed 4-byte array on the
  stack (no alloc), which the caller `writev`s alongside the payload.

## no_std

- **`#![cfg_attr(not(test), no_std)]`** — the shipping crate is `no_std` (never
  links libstd); under `cfg(test)` we drop it so the ordinary test harness
  (which needs `std`) can run. `core` is always available; it's `std` minus the
  OS/allocation bits.

## Project facts worth remembering

- QEMU `-netdev stream` wire format: 4-byte **big-endian** length prefix (payload
  length, prefix not counted) + raw L2 frame; no virtio-net header. QEMU is the
  socket *client* (`server=off`), so our binary is the *server*.
