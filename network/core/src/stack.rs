//! The network datapath.
//!
//! Terminates the guest's traffic — the QEMU `-netdev stream` transport feeds a
//! smoltcp interface acting as the guest's gateway — and splices allowed flows
//! onto real host sockets. Submodules arrive as the walking skeleton grows: the
//! frame codec, the smoltcp interface, the NAT/flow manager, the DHCP server,
//! the DNS resolver/observer, and the reactor.

// QEMU `-netdev stream` framing: deframe the length-prefixed byte stream.
pub mod frame;

// The smoltcp datapath device: fixed-buffer, single-frame conduit.
pub mod device;
