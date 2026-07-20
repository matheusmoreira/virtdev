#![cfg_attr(not(test), no_std)]

//! network — virtdev's egress network stack.
//!
//! The shipping crate is `#![no_std]`; it never links the standard library.
//! Under `cfg(test)` we drop `no_std` so the ordinary `cargo test` harness
//! (which needs `std`) can run the TDD loop, while every non-test build stays
//! freestanding.
//!
//! Two halves:
//!   - [`stack`]  — the datapath: the QEMU transport, the smoltcp interface,
//!     NAT/flow management, the DHCP server, the DNS resolver/observer.
//!   - [`filter`] — the egress policy: the built-in zones plus the DNS-aware
//!     per-domain allow-list.

pub mod filter;
pub mod stack;
