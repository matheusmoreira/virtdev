//! The network datapath.
//!
//! Terminates the guest's traffic — the QEMU `-netdev stream` transport feeds a
//! smoltcp interface acting as the guest's gateway — and splices allowed flows
//! onto real host sockets. Submodules arrive as the walking skeleton grows: the
//! frame codec, the smoltcp interface, the NAT/flow manager, the DHCP server,
//! the DNS resolver/observer, and the reactor.
