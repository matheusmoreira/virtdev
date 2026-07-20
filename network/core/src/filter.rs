//! The egress policy.
//!
//! Decides whether a guest-initiated flow may leave the machine: the four
//! built-in zones (`none` / `wan` / `lan` / `full`) plus the DNS-aware
//! per-domain allow-list, with a per-connection denial log. Filled in at M2
//! (zones) and M3 (per-domain).
