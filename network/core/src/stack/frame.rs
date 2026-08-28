//! Bounded framing primitives for QEMU `-netdev stream`.
//!
//! Each Ethernet frame has a four-byte big-endian payload length. Reads may
//! split a frame anywhere or coalesce several frames.

const PREFIX_LEN: usize = 4;

/// Largest accepted Ethernet frame: a 14-byte header plus the 1500-byte IP MTU.
pub const MAX_FRAME_LEN: usize = 1514;

/// Capacity needed for one maximum-sized framed packet.
pub const MAX_WIRE_FRAME_LEN: usize = PREFIX_LEN + MAX_FRAME_LEN;

/// Result of decoding one frame from the front of a byte slice.
#[derive(Debug, Eq, PartialEq)]
pub enum Decoded<'a> {
    Complete { payload: &'a [u8], consumed: usize },
    Incomplete,
    Oversized,
}

/// Decode one length-prefixed frame without retaining state.
pub fn decode(buf: &[u8]) -> Decoded<'_> {
    if buf.len() < PREFIX_LEN {
        return Decoded::Incomplete;
    }

    let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    if len > MAX_FRAME_LEN {
        return Decoded::Oversized;
    }

    let consumed = PREFIX_LEN + len;
    if buf.len() < consumed {
        return Decoded::Incomplete;
    }

    Decoded::Complete {
        payload: &buf[PREFIX_LEN..consumed],
        consumed,
    }
}

/// Result of a nonblocking read attempt, translated by the reactor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReadEvent {
    /// Bytes initialized at the front of `FrameDecoder::writable()`.
    Data(usize),
    /// A zero-byte read from the stream.
    Eof,
    /// `EAGAIN` or `EWOULDBLOCK`; retain state and wait for readability.
    WouldBlock,
    /// `EINTR`; retain state and retry immediately.
    Interrupted,
}

/// What the reactor should do after applying a read event.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReadAction {
    /// Inspect `FrameDecoder::next()` for frames or terminal state.
    Inspect,
    /// Wait for another readiness notification.
    Wait,
    /// Retry the interrupted read.
    Retry,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReadError {
    /// Zero must be represented by `ReadEvent::Eof`.
    ZeroBytes,
    /// The reported count exceeds the returned writable tail.
    ExceedsCapacity,
    /// Data was reported after EOF.
    AfterEof,
}

/// Current state at the front of a FrameDecoder.
#[derive(Debug, Eq, PartialEq)]
pub enum DecoderState<'a> {
    /// A complete frame, retained until `consume_frame` is called.
    Frame(&'a [u8]),
    /// No complete frame is buffered and the stream is still open.
    NeedRead,
    /// The current prefix exceeds `MAX_FRAME_LEN`.
    Oversized,
    /// EOF occurred exactly between frames.
    CleanEof,
    /// EOF occurred inside a prefix or payload.
    TruncatedEof,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConsumeError {
    /// The current frame needs more bytes.
    Incomplete,
    /// The current prefix exceeds `MAX_FRAME_LEN`.
    Oversized,
}

/// Fixed-capacity stream accumulator for one maximum-sized framed packet.
pub struct FrameDecoder {
    buf: [u8; MAX_WIRE_FRAME_LEN],
    start: usize,
    end: usize,
    eof: bool,
}

impl FrameDecoder {
    pub const fn new() -> Self {
        Self {
            buf: [0; MAX_WIRE_FRAME_LEN],
            start: 0,
            end: 0,
            eof: false,
        }
    }

    pub fn buffered_len(&self) -> usize {
        self.end - self.start
    }

    pub fn writable_capacity(&self) -> usize {
        self.buf.len() - self.end
    }

    /// Tail storage for the next read. Consume and compact to reclaim the front.
    pub fn writable(&mut self) -> &mut [u8] {
        if self.eof {
            &mut self.buf[self.end..self.end]
        } else {
            &mut self.buf[self.end..]
        }
    }

    /// Commit a translated read result without depending on std::io.
    pub fn apply_read(&mut self, event: ReadEvent) -> Result<ReadAction, ReadError> {
        match event {
            ReadEvent::Data(0) => Err(ReadError::ZeroBytes),
            ReadEvent::Data(_) if self.eof => Err(ReadError::AfterEof),
            ReadEvent::Data(n) if n > self.writable_capacity() => Err(ReadError::ExceedsCapacity),
            ReadEvent::Data(n) => {
                self.end += n;
                Ok(ReadAction::Inspect)
            }
            ReadEvent::Eof => {
                self.eof = true;
                Ok(ReadAction::Inspect)
            }
            ReadEvent::WouldBlock => Ok(ReadAction::Wait),
            ReadEvent::Interrupted => Ok(ReadAction::Retry),
        }
    }

    pub fn next(&self) -> DecoderState<'_> {
        match decode(&self.buf[self.start..self.end]) {
            Decoded::Complete { payload, .. } => DecoderState::Frame(payload),
            Decoded::Oversized => DecoderState::Oversized,
            Decoded::Incomplete if !self.eof => DecoderState::NeedRead,
            Decoded::Incomplete if self.buffered_len() == 0 => DecoderState::CleanEof,
            Decoded::Incomplete => DecoderState::TruncatedEof,
        }
    }

    /// Remove the complete frame currently returned by next.
    pub fn consume_frame(&mut self) -> Result<(), ConsumeError> {
        match decode(&self.buf[self.start..self.end]) {
            Decoded::Complete { consumed, .. } => {
                self.start += consumed;
                Ok(())
            }
            Decoded::Incomplete => Err(ConsumeError::Incomplete),
            Decoded::Oversized => Err(ConsumeError::Oversized),
        }
    }

    /// Move unconsumed bytes to the front and restore contiguous read capacity.
    pub fn compact(&mut self) {
        if self.start == 0 {
            return;
        }
        self.buf.copy_within(self.start..self.end, 0);
        self.end -= self.start;
        self.start = 0;
    }
}

impl Default for FrameDecoder {
    fn default() -> Self {
        Self::new()
    }
}

/// Return the four-byte big-endian prefix for frame.
pub fn encode(frame: &[u8]) -> [u8; PREFIX_LEN] {
    debug_assert!(frame.len() <= MAX_FRAME_LEN);
    (frame.len() as u32).to_be_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wire(payload: &[u8]) -> Vec<u8> {
        let mut wire = encode(payload).to_vec();
        wire.extend_from_slice(payload);
        wire
    }

    fn append(decoder: &mut FrameDecoder, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        decoder.writable()[..bytes.len()].copy_from_slice(bytes);
        assert_eq!(
            decoder.apply_read(ReadEvent::Data(bytes.len())),
            Ok(ReadAction::Inspect)
        );
    }

    #[test]
    fn decodes_a_single_complete_frame() {
        let wire = [0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF];
        assert_eq!(
            decode(&wire),
            Decoded::Complete {
                payload: &[0xDE, 0xAD, 0xBE, 0xEF],
                consumed: 8
            }
        );
    }

    #[test]
    fn incomplete_buffer_is_incomplete() {
        assert_eq!(decode(&[0x00, 0x00]), Decoded::Incomplete);
        assert_eq!(
            decode(&[0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD]),
            Decoded::Incomplete
        );
    }

    #[test]
    fn decodes_two_frames_back_to_back() {
        let mut bytes = wire(&[0xAA, 0xBB]);
        bytes.extend_from_slice(&wire(&[0x01, 0x02, 0x03]));

        let Decoded::Complete {
            payload: first,
            consumed: n1,
        } = decode(&bytes)
        else {
            panic!("frame 1 is complete");
        };
        assert_eq!(first, &[0xAA, 0xBB]);
        assert_eq!(n1, 6);

        assert_eq!(
            decode(&bytes[n1..]),
            Decoded::Complete {
                payload: &[0x01, 0x02, 0x03],
                consumed: 7
            }
        );
    }

    #[test]
    fn rejects_an_oversized_length_prefix() {
        let too_big = (MAX_FRAME_LEN as u32 + 1).to_be_bytes();
        assert_eq!(decode(&too_big), Decoded::Oversized);

        let at_limit = (MAX_FRAME_LEN as u32).to_be_bytes();
        assert_eq!(decode(&at_limit), Decoded::Incomplete);
        assert_eq!(decode(&u32::MAX.to_be_bytes()), Decoded::Oversized);
    }

    #[test]
    fn encode_then_decode_round_trips_at_the_cap() {
        let frame = vec![0xAB; MAX_FRAME_LEN];
        let bytes = wire(&frame);
        assert_eq!(
            decode(&bytes),
            Decoded::Complete {
                payload: &frame,
                consumed: MAX_WIRE_FRAME_LEN
            }
        );
    }

    #[test]
    fn accumulator_accepts_every_split_point() {
        let payload: Vec<u8> = (0..32).collect();
        let bytes = wire(&payload);

        for split in 0..=bytes.len() {
            let mut decoder = FrameDecoder::new();
            append(&mut decoder, &bytes[..split]);
            if split < bytes.len() {
                assert_eq!(decoder.next(), DecoderState::NeedRead, "split {split}");
            }
            append(&mut decoder, &bytes[split..]);
            assert_eq!(
                decoder.next(),
                DecoderState::Frame(&payload),
                "split {split}"
            );
            assert_eq!(decoder.consume_frame(), Ok(()));
            decoder.compact();
            assert_eq!(decoder.next(), DecoderState::NeedRead);
        }
    }

    #[test]
    fn consume_and_compact_preserve_coalesced_tail() {
        let first = wire(&[1, 2]);
        let second = wire(&[3, 4, 5]);
        let third = wire(&[6, 7, 8, 9]);
        let mut decoder = FrameDecoder::new();

        let mut coalesced = first;
        coalesced.extend_from_slice(&second);
        coalesced.extend_from_slice(&third[..5]);
        append(&mut decoder, &coalesced);

        assert_eq!(decoder.next(), DecoderState::Frame(&[1, 2]));
        assert_eq!(decoder.consume_frame(), Ok(()));
        assert_eq!(decoder.next(), DecoderState::Frame(&[3, 4, 5]));
        assert_eq!(decoder.consume_frame(), Ok(()));
        assert_eq!(decoder.next(), DecoderState::NeedRead);

        decoder.compact();
        assert_eq!(decoder.buffered_len(), 5);
        append(&mut decoder, &third[5..]);
        assert_eq!(decoder.next(), DecoderState::Frame(&[6, 7, 8, 9]));
    }

    #[test]
    fn accumulator_enforces_its_exact_capacity() {
        let payload = vec![0xA5; MAX_FRAME_LEN];
        let bytes = wire(&payload);
        let mut decoder = FrameDecoder::new();

        assert_eq!(decoder.writable_capacity(), MAX_WIRE_FRAME_LEN);
        append(&mut decoder, &bytes);
        assert_eq!(decoder.writable_capacity(), 0);
        assert_eq!(decoder.next(), DecoderState::Frame(&payload));
        assert_eq!(
            decoder.apply_read(ReadEvent::Data(1)),
            Err(ReadError::ExceedsCapacity)
        );

        let mut oversized = FrameDecoder::new();
        append(&mut oversized, &(MAX_FRAME_LEN as u32 + 1).to_be_bytes());
        assert_eq!(oversized.next(), DecoderState::Oversized);
        assert_eq!(oversized.consume_frame(), Err(ConsumeError::Oversized));
    }

    #[test]
    fn eof_distinguishes_clean_complete_and_truncated_streams() {
        let payload = [0x10, 0x20, 0x30, 0x40];
        let bytes = wire(&payload);

        let mut clean = FrameDecoder::new();
        assert_eq!(clean.apply_read(ReadEvent::Eof), Ok(ReadAction::Inspect));
        assert_eq!(clean.next(), DecoderState::CleanEof);

        for cut in 1..bytes.len() {
            let mut truncated = FrameDecoder::new();
            append(&mut truncated, &bytes[..cut]);
            assert_eq!(
                truncated.apply_read(ReadEvent::Eof),
                Ok(ReadAction::Inspect)
            );
            assert_eq!(truncated.next(), DecoderState::TruncatedEof, "cut {cut}");
        }

        let mut complete = FrameDecoder::new();
        append(&mut complete, &bytes);
        assert_eq!(complete.apply_read(ReadEvent::Eof), Ok(ReadAction::Inspect));
        assert_eq!(complete.next(), DecoderState::Frame(&payload));
        assert_eq!(complete.consume_frame(), Ok(()));
        assert_eq!(complete.next(), DecoderState::CleanEof);
        assert!(complete.writable().is_empty());
        assert_eq!(
            complete.apply_read(ReadEvent::Data(1)),
            Err(ReadError::AfterEof)
        );
    }

    #[test]
    fn eof_reports_a_truncated_tail_after_complete_frames() {
        let first = wire(&[1, 2, 3]);
        let second = wire(&[4, 5, 6]);
        let mut decoder = FrameDecoder::new();
        let mut bytes = first;
        bytes.extend_from_slice(&second[..5]);
        append(&mut decoder, &bytes);
        assert_eq!(decoder.apply_read(ReadEvent::Eof), Ok(ReadAction::Inspect));

        assert_eq!(decoder.next(), DecoderState::Frame(&[1, 2, 3]));
        assert_eq!(decoder.consume_frame(), Ok(()));
        assert_eq!(decoder.next(), DecoderState::TruncatedEof);
    }

    #[test]
    fn retryable_read_results_do_not_change_buffer_state() {
        let mut decoder = FrameDecoder::new();
        append(&mut decoder, &[0, 0]);
        let before = decoder.buffered_len();

        assert_eq!(
            decoder.apply_read(ReadEvent::WouldBlock),
            Ok(ReadAction::Wait)
        );
        assert_eq!(
            decoder.apply_read(ReadEvent::Interrupted),
            Ok(ReadAction::Retry)
        );
        assert_eq!(decoder.buffered_len(), before);
        assert_eq!(decoder.next(), DecoderState::NeedRead);
        assert_eq!(
            decoder.apply_read(ReadEvent::Data(0)),
            Err(ReadError::ZeroBytes)
        );
    }
}
