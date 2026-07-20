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
use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::time::Instant;

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

    /// Build a frame of `len` bytes *in place*: hand the closure a mutable
    /// `len`-byte window into the buffer, then mark the slot occupied — no
    /// intermediate copy. The TX counterpart of `store` (which copies a
    /// ready-made frame): smoltcp's `TxToken` writes straight into our buffer.
    /// Returns the closure's result. `len` must fit `MAX_FRAME_LEN`.
    /// (`impl FnOnce(&mut [u8]) -> R` in argument position is shorthand for a
    /// generic `<F: FnOnce(&mut [u8]) -> R>` — an anonymous type parameter.)
    fn fill<R>(&mut self, len: usize, f: impl FnOnce(&mut [u8]) -> R) -> R {
        debug_assert!(len <= MAX_FRAME_LEN);
        let r = f(&mut self.buf[..len]);
        self.len = Some(len);
        r
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

/// smoltcp's receive token: a mutable borrow of the inbound slot. `<'a>` is the
/// borrow's lifetime — the token cannot outlive the device (`where Self: 'a` on
/// the trait). Consuming it is the one chance to read the frame.
pub struct QemuRxToken<'a>(&'a mut FrameSlot);

/// smoltcp's transmit token: a mutable borrow of the outbound slot.
pub struct QemuTxToken<'a>(&'a mut FrameSlot);

impl RxToken for QemuRxToken<'_> {
    /// Hand the received frame to `f`, then free the slot. `f` is `FnOnce` and
    /// the token is taken by value (`self`), so the frame is received exactly
    /// once. The bound desugars to `for<'x> FnOnce(&'x [u8]) -> R`, so `R` can't
    /// borrow the frame — which is why the `clear` below is sound.
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        // Only ever created with a frame waiting (see `Device::receive`); its
        // absence would be our bug, hence the panic.
        let frame = self
            .0
            .get()
            .expect("QemuRxToken created only with an inbound frame");
        let result = f(frame);
        self.0.clear(); // received — free the slot for the next frame
        result
    }
}

impl TxToken for QemuTxToken<'_> {
    /// Let smoltcp build a `len`-byte frame directly in the outbound slot.
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        self.0.fill(len, f)
    }
}

impl Device for QemuDevice {
    // The GATs made concrete: the token type family, one member per borrow
    // lifetime `'a`. The `where Self: 'a` echoes the trait's required bound.
    type RxToken<'a> = QemuRxToken<'a> where Self: 'a;
    type TxToken<'a> = QemuTxToken<'a> where Self: 'a;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        // Only offer a receive when a frame actually waits.
        self.inbound.get()?;
        // Two `&mut` borrows of `self` at once — legal only because they touch
        // *different* fields (`inbound` vs `outbound`); the borrow checker is
        // field-sensitive. This split is the whole reason the slots are
        // separate: smoltcp may build a reply (TxToken) from the received frame.
        Some((
            QemuRxToken(&mut self.inbound),
            QemuTxToken(&mut self.outbound),
        ))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        // The single outbound slot can always take one frame.
        Some(QemuTxToken(&mut self.outbound))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        // `DeviceCapabilities` is `#[non_exhaustive]`, so build from `default()`
        // and set fields rather than a struct literal.
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ethernet;
        caps.max_transmission_unit = MAX_FRAME_LEN; // 1514 = IP MTU 1500 + 14B Ethernet header
        caps.max_burst_size = Some(1); // one frame per poll — our single slot
        caps
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use smoltcp::phy::{Device, RxToken, TxToken};
    use smoltcp::time::Instant;

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

    #[test]
    fn fill_builds_a_frame_in_place() {
        // The TX side hands a `len`-byte buffer to a closure to build the frame,
        // then marks the slot occupied — no intermediate copy.
        let mut slot = FrameSlot::empty();
        slot.fill(3, |buf| buf.copy_from_slice(&[0x01, 0x02, 0x03]));
        assert_eq!(slot.get(), Some(&[0x01, 0x02, 0x03][..]));
    }

    #[test]
    fn rx_token_yields_the_frame_then_clears() {
        let mut slot = FrameSlot::empty();
        slot.store(&[0xAB, 0xCD]);
        // consume hands the frame to the closure, then marks the slot consumed.
        let seen = QemuRxToken(&mut slot).consume(|frame| frame.to_vec());
        assert_eq!(seen, vec![0xAB, 0xCD]);
        assert_eq!(slot.get(), None);
    }

    #[test]
    fn tx_token_builds_the_outbound_frame() {
        let mut slot = FrameSlot::empty();
        QemuTxToken(&mut slot).consume(3, |buf| buf.copy_from_slice(&[0x07, 0x08, 0x09]));
        assert_eq!(slot.get(), Some(&[0x07, 0x08, 0x09][..]));
    }

    #[test]
    fn device_receive_delivers_then_frees() {
        let mut dev = QemuDevice::new();
        // Nothing to receive on an empty device.
        assert!(dev.receive(Instant::from_millis(0)).is_none());

        dev.load_inbound(&[0x0A, 0x0B]);
        let (rx, _tx) = dev.receive(Instant::from_millis(0)).expect("a frame waits");
        let seen = rx.consume(|frame| frame.to_vec());
        assert_eq!(seen, vec![0x0A, 0x0B]);
        // Consumed → the slot is free again.
        assert!(dev.receive(Instant::from_millis(0)).is_none());
    }

    #[test]
    fn device_transmit_parks_an_outbound_frame() {
        let mut dev = QemuDevice::new();
        let tx = dev
            .transmit(Instant::from_millis(0))
            .expect("always able to send one frame");
        tx.consume(2, |buf| buf.copy_from_slice(&[0xEE, 0xFF]));
        assert_eq!(dev.outbound(), Some(&[0xEE, 0xFF][..]));
    }
}
