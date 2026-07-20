//! QEMU `-netdev stream` frame codec.
//!
//! QEMU connects to our unix socket as a client (`server=off`) and speaks the
//! "qemu socket" stream protocol: each L2 Ethernet frame is preceded by a
//! 4-byte **big-endian** length prefix whose value is the payload length (the
//! prefix itself is not counted). The `stream` backend carries no virtio-net
//! header. Confirmed against QEMU `net/net.c` `net_fill_rstate`:
//!
//! ```text
//! rs->packet_len = ntohl(*(uint32_t *)rs->buf);   // 4 bytes, network order
//! ```
//!
//! Because the transport is a byte stream, one read may deliver a partial
//! prefix, a partial payload, or several frames at once — so the decoder must
//! tolerate incomplete input.

/// The largest L2 Ethernet frame we accept from the guest: the 14-byte header
/// plus the 1500-byte IP MTU we advertise via DHCP. It is also the MTU we set
/// on our smoltcp `Device`. A prefix claiming more than this is rejected as
/// hostile — the cap bounds how much we ever buffer for one frame (a DoS bound)
/// and keeps `4 + len` far from overflowing `usize`.
///
/// Assumes standard-MTU frames: virtio-net segmentation offload (TSO/GSO) must
/// stay OFF on the `stream` backend (its default — `stream` carries no
/// virtio-net header to signal GSO). With offload on a guest could emit frames
/// up to QEMU's `NET_BUFSIZE` (69632); confirm offloads are disabled at the M1
/// device spike so this cap never rejects legitimate traffic.
///
/// (Lives here as the codec is its first user; hoist to a shared constant once
/// the `Device` and DHCP server reference the same MTU.)
pub const MAX_FRAME_LEN: usize = 1514;

/// The outcome of decoding one frame from the front of a buffer.
#[derive(Debug, PartialEq)]
pub enum Decoded<'a> {
    /// A complete frame: the payload (borrowing the input) and how many bytes it
    /// occupied — prefix + payload — so the caller can advance its cursor.
    Complete { payload: &'a [u8], consumed: usize },
    /// Not enough bytes have arrived yet; keep reading and call again.
    Incomplete,
    /// The length prefix exceeds `MAX_FRAME_LEN`: a malformed or hostile stream.
    /// Reject immediately — drop the connection rather than buffer the claim.
    Oversized,
}

/// Decode a single frame from the front of `buf`.
///
/// Returns [`Decoded::Complete`] with the borrowed payload and the byte count
/// consumed (prefix + payload) when a whole frame is present;
/// [`Decoded::Incomplete`] when more bytes are needed; or [`Decoded::Oversized`]
/// when the length prefix exceeds [`MAX_FRAME_LEN`] and the stream should be
/// dropped.
pub fn decode(buf: &[u8]) -> Decoded<'_> {
    // Need the whole 4-byte length prefix before we can read the length.
    if buf.len() < 4 {
        return Decoded::Incomplete;
    }
    // The first four bytes are the payload length, big-endian.
    let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    // A prefix larger than the biggest frame we allow is hostile: reject as soon
    // as we have read it, before waiting to buffer that many bytes.
    if len > MAX_FRAME_LEN {
        return Decoded::Oversized;
    }
    // The whole frame is the 4-byte prefix plus that payload...
    let consumed = 4 + len;
    // ...and all of it must have arrived.
    if buf.len() < consumed {
        return Decoded::Incomplete;
    }
    // Return the payload and how far to advance the cursor to the next frame.
    Decoded::Complete {
        payload: &buf[4..consumed],
        consumed,
    }
}

/// The 4-byte big-endian length prefix for `frame`. Write it and the frame
/// together — e.g. `writev` with two iovecs — never copying the payload, exactly
/// how QEMU frames its own outbound packets. The inverse of [`decode`].
///
/// `frame` must be at most [`MAX_FRAME_LEN`]; a longer frame is our own bug
/// (smoltcp produces frames at our MTU), so it trips a debug assertion rather
/// than a fallible return — untrusted input earns a variant, our own invariant
/// earns an assert.
pub fn encode(frame: &[u8]) -> [u8; 4] {
    debug_assert!(frame.len() <= MAX_FRAME_LEN);
    (frame.len() as u32).to_be_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_a_single_complete_frame() {
        // 4-byte big-endian length (0x0000_0004) followed by a 4-byte payload.
        let wire = [0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF];
        assert_eq!(
            decode(&wire),
            Decoded::Complete { payload: &[0xDE, 0xAD, 0xBE, 0xEF][..], consumed: 8 }
        );
    }

    #[test]
    fn incomplete_buffer_is_incomplete() {
        // Fewer than 4 bytes: can't even read the length prefix.
        assert_eq!(decode(&[0x00, 0x00]), Decoded::Incomplete);
        // A full 4-byte prefix claims 4 payload bytes, but only 2 are present.
        assert_eq!(decode(&[0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD]), Decoded::Incomplete);
    }

    #[test]
    fn decodes_two_frames_back_to_back() {
        // One socket read can carry several whole frames at once. The decoder
        // reports how many bytes it consumed so the caller can advance a cursor
        // to the next frame — it never has to buffer or allocate the frames.
        let wire = [
            0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB, // frame 1: len 2
            0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03, // frame 2: len 3
        ];

        let Decoded::Complete { payload: first, consumed: n1 } = decode(&wire) else {
            panic!("frame 1 is complete");
        };
        assert_eq!(first, &[0xAA, 0xBB][..]);
        assert_eq!(n1, 6); // 4-byte prefix + 2-byte payload

        // Advance the cursor past frame 1, then decode frame 2 from the tail.
        let Decoded::Complete { payload: second, consumed: n2 } = decode(&wire[n1..]) else {
            panic!("frame 2 is complete");
        };
        assert_eq!(second, &[0x01, 0x02, 0x03][..]);
        assert_eq!(n2, 7); // 4 + 3
    }

    #[test]
    fn rejects_an_oversized_length_prefix() {
        // A prefix claiming more than MAX_FRAME_LEN is hostile: reject the moment
        // we have read the 4-byte prefix, without waiting to buffer the payload.
        let too_big = (MAX_FRAME_LEN as u32 + 1).to_be_bytes();
        assert_eq!(decode(&too_big), Decoded::Oversized);

        // Exactly MAX_FRAME_LEN is allowed — with no payload yet it is merely
        // Incomplete, not Oversized. Pins the boundary at `>`, not `>=`.
        let at_limit = (MAX_FRAME_LEN as u32).to_be_bytes();
        assert_eq!(decode(&at_limit), Decoded::Incomplete);
    }

    #[test]
    fn encode_produces_the_big_endian_length_prefix() {
        // encode yields only the 4-byte header; the caller writev's it with the
        // frame (zero-copy), so a 4-byte frame gives the prefix 0x0000_0004.
        let frame = [0xDE, 0xAD, 0xBE, 0xEF];
        assert_eq!(encode(&frame), [0x00, 0x00, 0x00, 0x04]);
    }

    #[test]
    fn encode_then_decode_round_trips() {
        // encode and decode are inverses: prefix a frame, then decode it back
        // whole. Pins their symmetry — the test to trust if the wire format ever
        // changes. (Passes on first write; both sides already exist and are
        // unit-tested above, so this is a living guard, not a driver.)
        let frame = [0x01, 0x02, 0x03];
        let mut wire = encode(&frame).to_vec(); // std Vec is available under cfg(test)
        wire.extend_from_slice(&frame);

        let Decoded::Complete { payload, consumed } = decode(&wire) else {
            panic!("a freshly encoded frame must decode as complete");
        };
        assert_eq!(payload, &frame[..]);
        assert_eq!(consumed, 4 + frame.len());
    }
}
