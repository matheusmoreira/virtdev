//! The network datapath.
//!
//! QEMU's framed stream feeds a smoltcp interface acting as the guest gateway.
//! This module currently contains bounded frame, device, inspection, and
//! interface primitives; host-socket flow management is not implemented.

pub mod frame;

mod device;

pub mod netstack;

mod inspect;

pub use device::LoadError;
pub use inspect::TcpFlowKey;
