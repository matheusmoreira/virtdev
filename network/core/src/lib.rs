#![cfg_attr(not(test), no_std)]

//! Freestanding egress stack primitives.
//!
//! Production builds are `no_std`; tests use the standard test harness. The
//! replacement's normative behavior is defined in `network/CONTRACT.md`.

pub mod filter;
pub mod stack;
