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

/// Decode a single frame from the front of `buf`.
///
/// On success, returns the frame payload (a sub-slice borrowing from `buf`)
/// together with the number of bytes consumed — the 4-byte prefix plus the
/// payload — so the caller can advance a cursor to the next frame.
/// Returns `None` when `buf` does not yet hold a complete frame.
pub fn decode(buf: &[u8]) -> Option<(&[u8], usize)> {
    // Need the whole 4-byte length prefix before we can read the length.
    if buf.len() < 4 {
        return None;
    }
    // The first four bytes are the payload length, big-endian.
    let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    // The whole frame is the 4-byte prefix plus that payload.
    let consumed = 4 + len;
    // ...and all of it must have arrived.
    if buf.len() < consumed {
        return None;
    }
    // Return the payload (the `len` bytes after the prefix) and how far to
    // advance the cursor to reach the next frame.
    Some((&buf[4..consumed], consumed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_a_single_complete_frame() {
        // 4-byte big-endian length (0x0000_0004) followed by a 4-byte payload.
        let wire = [0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF];
        assert_eq!(decode(&wire), Some((&[0xDE, 0xAD, 0xBE, 0xEF][..], 8)));
    }

    #[test]
    fn incomplete_buffer_yields_none() {
        // Fewer than 4 bytes: can't even read the length prefix.
        assert_eq!(decode(&[0x00, 0x00]), None);
        // A full 4-byte prefix claims 4 payload bytes, but only 2 are present.
        assert_eq!(decode(&[0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD]), None);
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

        let (first, n1) = decode(&wire).unwrap();
        assert_eq!(first, &[0xAA, 0xBB][..]);
        assert_eq!(n1, 6); // 4-byte prefix + 2-byte payload

        // Advance the cursor past frame 1, then decode frame 2 from the tail.
        let (second, n2) = decode(&wire[n1..]).unwrap();
        assert_eq!(second, &[0x01, 0x02, 0x03][..]);
        assert_eq!(n2, 7); // 4 + 3
    }
}
