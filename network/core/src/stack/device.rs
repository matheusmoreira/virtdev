//! The datapath device: a fixed-buffer, single-frame conduit between the QEMU
//! frame transport and smoltcp.
//!
//! smoltcp does no I/O itself — it drives a `Device` we implement. Ours parks at
//! most one inbound and one outbound L2 frame in fixed buffers (no heap): the
//! reactor decodes a frame off the QEMU socket and leaves it here for smoltcp to
//! receive, and smoltcp leaves an outbound frame here for the reactor to encode
//! and send. This module builds the single-frame slot first; the smoltcp trait
//! impls land in the next increment.

use super::frame::MAX_FRAME_LEN;

/// A fixed-capacity holder for at most one L2 frame — the single-frame slot, no
/// heap. `len` is `Some(n)` when a frame of `n` bytes is present, `None` when
/// empty.
struct FrameSlot {
    buf: [u8; MAX_FRAME_LEN],
    len: Option<usize>,
}

impl FrameSlot {
    /// An empty slot. `const` so a device can be built in a `static`/`const`
    /// context in the freestanding binary (like C++ `constexpr`).
    const fn empty() -> Self {
        Self {
            buf: [0; MAX_FRAME_LEN],
            len: None,
        }
    }

    /// The frame currently held, or `None` when empty. `Option::map` transforms
    /// the `Some(n)` case into the sub-slice `&buf[..n]` and passes `None`
    /// through untouched — `x.map(f)` is "`f(x)` if present, else nothing".
    fn get(&self) -> Option<&[u8]> {
        self.len.map(|n| &self.buf[..n])
    }

    /// Copy `frame` into the slot, marking it occupied (overwriting any prior
    /// contents). `copy_from_slice` is a length-checked `memcpy`: the
    /// destination sub-slice `buf[..frame.len()]` and `frame` must match length.
    /// `frame` must fit `MAX_FRAME_LEN` — the reactor only stores decoded frames,
    /// so an over-length one is our bug (a debug assertion, not a fallible path).
    fn store(&mut self, frame: &[u8]) {
        debug_assert!(frame.len() <= MAX_FRAME_LEN);
        self.buf[..frame.len()].copy_from_slice(frame);
        self.len = Some(frame.len());
    }

    /// Empty the slot. The buffer bytes remain but are unreachable via `get`.
    fn clear(&mut self) {
        self.len = None;
    }
}

/// The datapath device smoltcp drives: one inbound and one outbound single-frame
/// slot. The reactor loads decoded frames into `inbound` and drains `outbound` to
/// encode and send; smoltcp does the reverse (next increment, via its token
/// traits). Named `QemuDevice`, not `Device`, so it does not collide with
/// smoltcp's `Device` trait we implement on it next.
pub struct QemuDevice {
    inbound: FrameSlot,
    outbound: FrameSlot,
}

impl QemuDevice {
    /// A device with both slots empty. `const` for freestanding static init.
    pub const fn new() -> Self {
        Self {
            inbound: FrameSlot::empty(),
            outbound: FrameSlot::empty(),
        }
    }

    /// Reactor → device: park a decoded frame for smoltcp to receive.
    pub fn load_inbound(&mut self, frame: &[u8]) {
        self.inbound.store(frame);
    }

    /// The parked inbound frame, if any (smoltcp consumes it next increment).
    pub fn inbound(&self) -> Option<&[u8]> {
        self.inbound.get()
    }

    /// Drop the inbound frame once received.
    pub fn clear_inbound(&mut self) {
        self.inbound.clear();
    }

    /// smoltcp → device: park an outbound frame for the reactor to send.
    pub fn store_outbound(&mut self, frame: &[u8]) {
        self.outbound.store(frame);
    }

    /// The parked outbound frame, if any (the reactor encodes + sends it).
    pub fn outbound(&self) -> Option<&[u8]> {
        self.outbound.get()
    }

    /// Drop the outbound frame once sent.
    pub fn clear_outbound(&mut self) {
        self.outbound.clear();
    }
}

impl Default for QemuDevice {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_slot_is_empty() {
        // A newly created slot holds no frame.
        let slot = FrameSlot::empty();
        assert_eq!(slot.get(), None);
    }

    #[test]
    fn stores_and_clears_one_frame() {
        let mut slot = FrameSlot::empty();
        slot.store(&[0xAA, 0xBB, 0xCC]);
        assert_eq!(slot.get(), Some(&[0xAA, 0xBB, 0xCC][..]));
        slot.clear();
        assert_eq!(slot.get(), None);
    }

    #[test]
    fn device_holds_inbound_and_outbound_independently() {
        let mut dev = QemuDevice::new();
        assert_eq!(dev.inbound(), None);
        assert_eq!(dev.outbound(), None);

        dev.load_inbound(&[0x11, 0x22]);
        dev.store_outbound(&[0x33, 0x44, 0x55]);
        assert_eq!(dev.inbound(), Some(&[0x11, 0x22][..]));
        assert_eq!(dev.outbound(), Some(&[0x33, 0x44, 0x55][..]));

        // Clearing one direction must not disturb the other.
        dev.clear_inbound();
        assert_eq!(dev.inbound(), None);
        assert_eq!(dev.outbound(), Some(&[0x33, 0x44, 0x55][..]));
    }
}
