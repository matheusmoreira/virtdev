//! The datapath device: a fixed-buffer, single-frame conduit between the QEMU
//! frame transport and smoltcp.
//!
//! smoltcp does no I/O itself — it drives a `Device` we implement. Ours parks at
//! most one inbound and one outbound L2 frame in fixed buffers (no heap): the
//! reactor decodes a frame off the QEMU socket and leaves it here for smoltcp to
//! receive, and smoltcp leaves an outbound frame here for the reactor to encode
//! and send. Occupied slots apply backpressure; they are never overwritten.

use super::frame::MAX_FRAME_LEN;
use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::time::Instant;

/// Why a frame could not be parked in the device.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LoadError {
    Occupied,
    Oversized,
}

/// Fixed-capacity storage for one L2 frame.
struct FrameSlot {
    buf: [u8; MAX_FRAME_LEN],
    len: Option<usize>,
}

impl FrameSlot {
    const fn empty() -> Self {
        Self {
            buf: [0; MAX_FRAME_LEN],
            len: None,
        }
    }

    fn get(&self) -> Option<&[u8]> {
        self.len.map(|n| &self.buf[..n])
    }

    fn try_store(&mut self, frame: &[u8]) -> Result<(), LoadError> {
        if frame.len() > MAX_FRAME_LEN {
            return Err(LoadError::Oversized);
        }
        if self.len.is_some() {
            return Err(LoadError::Occupied);
        }
        self.buf[..frame.len()].copy_from_slice(frame);
        self.len = Some(frame.len());
        Ok(())
    }

    /// Build a frame in an empty slot. TxToken's contract initializes all bytes.
    fn fill<R>(&mut self, len: usize, f: impl FnOnce(&mut [u8]) -> R) -> R {
        assert!(self.len.is_none(), "TX token requires an empty slot");
        assert!(len <= MAX_FRAME_LEN, "TX frame exceeds device MTU");
        let r = f(&mut self.buf[..len]);
        self.len = Some(len);
        r
    }

    fn clear(&mut self) {
        self.len = None;
    }
}

/// The single-frame device driven by smoltcp and owned by NetStack.
pub struct QemuDevice {
    inbound: FrameSlot,
    outbound: FrameSlot,
}

impl QemuDevice {
    pub const fn new() -> Self {
        Self {
            inbound: FrameSlot::empty(),
            outbound: FrameSlot::empty(),
        }
    }

    /// Park one decoded frame without replacing queued data.
    pub(super) fn load_inbound(&mut self, frame: &[u8]) -> Result<(), LoadError> {
        self.inbound.try_store(frame)
    }

    #[cfg(test)]
    fn inbound(&self) -> Option<&[u8]> {
        self.inbound.get()
    }

    pub(super) fn clear_inbound(&mut self) {
        self.inbound.clear();
    }

    pub(super) fn outbound(&self) -> Option<&[u8]> {
        self.outbound.get()
    }

    pub(super) fn clear_outbound(&mut self) {
        self.outbound.clear();
    }
}

impl Default for QemuDevice {
    fn default() -> Self {
        Self::new()
    }
}

pub struct QemuRxToken<'a>(&'a mut FrameSlot);

pub struct QemuTxToken<'a>(&'a mut FrameSlot);

impl RxToken for QemuRxToken<'_> {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        let frame = self
            .0
            .get()
            .expect("QemuRxToken created only with an inbound frame");
        let result = f(frame);
        self.0.clear();
        result
    }
}

impl TxToken for QemuTxToken<'_> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        self.0.fill(len, f)
    }
}

impl Device for QemuDevice {
    type RxToken<'a>
        = QemuRxToken<'a>
    where
        Self: 'a;
    type TxToken<'a>
        = QemuTxToken<'a>
    where
        Self: 'a;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        self.inbound.get()?;
        if self.outbound.get().is_some() {
            return None;
        }
        Some((
            QemuRxToken(&mut self.inbound),
            QemuTxToken(&mut self.outbound),
        ))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        if self.outbound.get().is_some() {
            return None;
        }
        Some(QemuTxToken(&mut self.outbound))
    }

    fn capabilities(&self) -> DeviceCapabilities {
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
        let slot = FrameSlot::empty();
        assert_eq!(slot.get(), None);
    }

    #[test]
    fn stores_and_clears_one_frame() {
        let mut slot = FrameSlot::empty();
        slot.try_store(&[0xAA, 0xBB, 0xCC]).unwrap();
        assert_eq!(slot.get(), Some(&[0xAA, 0xBB, 0xCC][..]));
        slot.clear();
        assert_eq!(slot.get(), None);
    }

    #[test]
    fn device_holds_inbound_and_outbound_independently() {
        let mut dev = QemuDevice::new();
        assert_eq!(dev.inbound(), None);
        assert_eq!(dev.outbound(), None);

        dev.load_inbound(&[0x11, 0x22]).unwrap();
        dev.outbound.try_store(&[0x33, 0x44, 0x55]).unwrap();
        assert_eq!(dev.inbound(), Some(&[0x11, 0x22][..]));
        assert_eq!(dev.outbound(), Some(&[0x33, 0x44, 0x55][..]));

        dev.clear_inbound();
        assert_eq!(dev.inbound(), None);
        assert_eq!(dev.outbound(), Some(&[0x33, 0x44, 0x55][..]));
    }

    #[test]
    fn fill_builds_a_frame_in_place() {
        let mut slot = FrameSlot::empty();
        slot.fill(3, |buf| buf.copy_from_slice(&[0x01, 0x02, 0x03]));
        assert_eq!(slot.get(), Some(&[0x01, 0x02, 0x03][..]));
    }

    #[test]
    fn rx_token_yields_the_frame_then_clears() {
        let mut slot = FrameSlot::empty();
        slot.try_store(&[0xAB, 0xCD]).unwrap();
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
        assert!(dev.receive(Instant::from_millis(0)).is_none());

        dev.load_inbound(&[0x0A, 0x0B]).unwrap();
        let (rx, _tx) = dev.receive(Instant::from_millis(0)).expect("a frame waits");
        let seen = rx.consume(|frame| frame.to_vec());
        assert_eq!(seen, vec![0x0A, 0x0B]);
        assert!(dev.receive(Instant::from_millis(0)).is_none());
    }

    #[test]
    fn device_transmit_parks_an_outbound_frame() {
        let mut dev = QemuDevice::new();
        let tx = dev
            .transmit(Instant::from_millis(0))
            .expect("an empty device can send one frame");
        tx.consume(2, |buf| buf.copy_from_slice(&[0xEE, 0xFF]));
        assert_eq!(dev.outbound(), Some(&[0xEE, 0xFF][..]));
    }

    #[test]
    fn transmit_is_refused_while_the_outbound_slot_is_full() {
        let mut dev = QemuDevice::new();
        dev.outbound.try_store(&[0x01]).unwrap();
        assert!(dev.transmit(Instant::from_millis(0)).is_none());
        dev.clear_outbound();
        assert!(dev.transmit(Instant::from_millis(0)).is_some());
    }

    #[test]
    fn occupied_inbound_slot_preserves_the_first_frame() {
        let mut dev = QemuDevice::new();
        dev.load_inbound(&[0x01, 0x02]).unwrap();

        assert_eq!(dev.load_inbound(&[0x03]), Err(LoadError::Occupied));
        assert_eq!(dev.inbound(), Some(&[0x01, 0x02][..]));
    }

    #[test]
    fn oversized_inbound_frame_is_rejected_without_occupying_the_slot() {
        let mut dev = QemuDevice::new();
        let oversized = [0u8; MAX_FRAME_LEN + 1];

        assert_eq!(dev.load_inbound(&oversized), Err(LoadError::Oversized));
        assert_eq!(dev.inbound(), None);
    }

    #[test]
    fn receive_waits_for_outbound_capacity_without_losing_either_frame() {
        let mut dev = QemuDevice::new();
        dev.load_inbound(&[0x10]).unwrap();
        dev.outbound.try_store(&[0x20]).unwrap();

        assert!(dev.receive(Instant::ZERO).is_none());
        assert_eq!(dev.inbound(), Some(&[0x10][..]));
        assert_eq!(dev.outbound(), Some(&[0x20][..]));

        dev.clear_outbound();
        let (rx, tx) = dev
            .receive(Instant::ZERO)
            .expect("outbound capacity is free");
        assert_eq!(rx.consume(|frame| frame.to_vec()), vec![0x10]);
        tx.consume(1, |frame| frame.copy_from_slice(&[0x30]));
        assert_eq!(dev.outbound(), Some(&[0x30][..]));
    }
}
