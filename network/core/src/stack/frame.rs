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
/// On success, returns the frame payload as a sub-slice borrowing from `buf`.
/// Returns `None` when `buf` does not yet hold a complete frame.
pub fn decode(buf: &[u8]) -> Option<&[u8]> {
    // Need the whole 4-byte length prefix before we can read the length.
    if buf.len() < 4 {
        return None;
    }
    // The first four bytes are the payload length, big-endian.
    let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    // ...and the whole payload must have arrived too.
    if buf.len() < 4 + len {
        return None;
    }
    // The payload is the `len` bytes following the 4-byte prefix.
    Some(&buf[4..4 + len])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_a_single_complete_frame() {
        // 4-byte big-endian length (0x0000_0004) followed by a 4-byte payload.
        let wire = [0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF];
        assert_eq!(decode(&wire), Some(&[0xDE, 0xAD, 0xBE, 0xEF][..]));
    }

    #[test]
    fn incomplete_buffer_yields_none() {
        // Fewer than 4 bytes: can't even read the length prefix.
        assert_eq!(decode(&[0x00, 0x00]), None);
        // A full 4-byte prefix claims 4 payload bytes, but only 2 are present.
        assert_eq!(decode(&[0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD]), None);
    }
}
