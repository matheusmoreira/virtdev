//! Flow inspection: peek a new TCP flow's destination off an inbound frame.
//!
//! The reactor peeks each inbound frame *before* `poll`, so the flow manager can
//! learn the `(dst, port)` a new connection is dialing, consult policy, and — if
//! allowed — provision a smoltcp listening socket on that exact destination on
//! demand (AnyIP transparent termination; design spec §5.1).
//!
//! The peek's acceptance is a **subset** of what the datapath (`Interface::poll`)
//! will actually terminate: it parses with the *same* `Ipv4Repr::parse` /
//! `TcpRepr::parse` smoltcp's ingress uses, so it inherits their IP-version,
//! IPv4/TCP checksum, and fragment checks, and additionally requires the frame be
//! L2-addressed to our gateway MAC and carry a unicast source and a unicast,
//! non-zero-port destination (a foreign dst-MAC, a broadcast/multicast target, or
//! port 0 is not a terminable egress connection). This keeps "peek reports a
//! flow" ⟹ "poll will terminate it" — so the future flow manager never
//! provisions a socket or dials a host for a frame smoltcp would silently drop.
//! (The peek is the *identifier* of a real new flow; the policy gate is what
//! decides whether it may leave — that gate is separate, not-yet-written code.)
//!
//! Parsing reuses smoltcp's audited, bounds-checked, `#![deny(unsafe_code)]`
//! parsers rather than hand-rolled IP/TCP parsing; hostile bytes yield `None`,
//! never a panic or overread. (The DNS parser we still own — a distinct
//! untrusted surface, M3.)

use smoltcp::phy::ChecksumCapabilities;
use smoltcp::wire::{
    EthernetAddress, EthernetFrame, EthernetProtocol, IpAddress, IpProtocol, Ipv4Address,
    Ipv4Packet, Ipv4Repr, TcpControl, TcpPacket, TcpRepr,
};

/// A guest-initiated TCP connection attempt: the destination the guest is
/// dialing. `(dst, dst_port)` is what the flow manager provisions a listening
/// socket on; smoltcp learns the source from the frame itself.
#[derive(Debug, PartialEq)]
pub struct SynFlow {
    pub dst: Ipv4Address,
    pub dst_port: u16,
}

/// Whether `addr` is a unicast IPv4 address — mirrors smoltcp's own
/// `AddressExt::x_is_unicast` (`wire/ipv4.rs`): not broadcast, multicast, or
/// unspecified. Those are not terminable egress destinations.
fn is_unicast(addr: Ipv4Address) -> bool {
    !(addr.is_broadcast() || addr.is_multicast() || addr.is_unspecified())
}

/// Peek a new-flow TCP SYN off the front of an L2 frame addressed to
/// `gateway_mac` (our interface's MAC). Returns `Some` only for a *pure* SYN
/// (connection open) over IPv4/Ethernet that the datapath will actually
/// terminate: L2-addressed to us, valid IP version and IPv4/TCP checksums, not a
/// fragment, a unicast source, and a unicast, non-zero-port destination. `None`
/// for anything else — a frame bound for a different MAC, a SYN/ACK, a
/// mid-connection segment, or malformed / checksum-corrupt input.
pub fn peek_tcp_syn(frame: &[u8], gateway_mac: EthernetAddress) -> Option<SynFlow> {
    let caps = ChecksumCapabilities::default();

    let eth = EthernetFrame::new_checked(frame).ok()?;
    // The datapath (process_ethernet) only accepts a frame addressed to our MAC
    // (or broadcast/multicast, which are not egress flows); a foreign unicast
    // dst-MAC SYN is dropped by poll, so the peek must drop it too.
    if eth.dst_addr() != gateway_mac {
        return None;
    }
    if eth.ethertype() != EthernetProtocol::Ipv4 {
        return None;
    }

    // Parse the IPv4 header exactly as the datapath does: rejects a non-4 version,
    // a bad header checksum, and any fragment (reassembly is off in our build).
    let ipv4 = Ipv4Packet::new_checked(eth.payload()).ok()?;
    let ip = Ipv4Repr::parse(&ipv4, &caps).ok()?;
    if ip.next_header != IpProtocol::Tcp {
        return None;
    }
    // Only real unicast egress: the ingress gate drops a non-unicast source, and
    // broadcast/multicast/unspecified is not an egress destination.
    if !is_unicast(ip.src_addr) || !is_unicast(ip.dst_addr) {
        return None;
    }

    // Parse the TCP header the same way (verifies the TCP checksum).
    let tcp = TcpPacket::new_checked(ipv4.payload()).ok()?;
    let seg = TcpRepr::parse(
        &tcp,
        &IpAddress::Ipv4(ip.src_addr),
        &IpAddress::Ipv4(ip.dst_addr),
        &caps,
    )
    .ok()?;
    // A new flow is a pure SYN (control Syn, no ACK) to a real port; `listen()`
    // rejects port 0.
    if seg.control != TcpControl::Syn || seg.ack_number.is_some() || seg.dst_port == 0 {
        return None;
    }

    Some(SynFlow {
        dst: ip.dst_addr,
        dst_port: seg.dst_port,
    })
}

#[cfg(test)]
mod tests {
    use super::{is_unicast, peek_tcp_syn, SynFlow};
    use smoltcp::phy::ChecksumCapabilities;
    use smoltcp::wire::{
        EthernetAddress, EthernetFrame, EthernetProtocol, EthernetRepr, IpAddress, IpProtocol,
        Ipv4Address, Ipv4Packet, Ipv4Repr, TcpControl, TcpPacket, TcpRepr, TcpSeqNumber,
    };

    const GUEST_MAC: EthernetAddress = EthernetAddress([0x02, 0, 0, 0, 0, 0x02]);
    const GW_MAC: EthernetAddress = EthernetAddress([0x02, 0, 0, 0, 0, 0x01]);
    const GUEST_IP: Ipv4Address = Ipv4Address::new(10, 0, 0, 2);
    const SERVER_IP: Ipv4Address = Ipv4Address::new(93, 184, 216, 34);
    // Offsets in a crafted frame: 14-byte Ethernet, 20-byte IPv4 (no options).
    const IP_OFF: usize = 14;
    const TCP_OFF: usize = 34;

    fn tcp(control: TcpControl, ack: Option<TcpSeqNumber>, dst_port: u16) -> TcpRepr<'static> {
        TcpRepr {
            src_port: 49152,
            dst_port,
            control,
            seq_number: TcpSeqNumber(0x1000),
            ack_number: ack,
            window_len: 1024,
            window_scale: None,
            max_seg_size: None,
            sack_permitted: false,
            sack_ranges: [None, None, None],
            timestamp: None,
            payload: &[],
        }
    }

    fn syn() -> TcpRepr<'static> {
        tcp(TcpControl::Syn, None, 80)
    }

    /// Build a valid, fully-checksummed Ethernet|IPv4|TCP frame from `src` to
    /// `dst` at L2 addressed to our gateway MAC.
    fn craft(src: Ipv4Address, dst: Ipv4Address, seg: &TcpRepr) -> Vec<u8> {
        let ip_repr = Ipv4Repr {
            src_addr: src,
            dst_addr: dst,
            next_header: IpProtocol::Tcp,
            payload_len: seg.buffer_len(),
            hop_limit: 64,
        };
        let eth_repr = EthernetRepr {
            src_addr: GUEST_MAC,
            dst_addr: GW_MAC,
            ethertype: EthernetProtocol::Ipv4,
        };
        let mut buf = vec![0u8; eth_repr.buffer_len() + ip_repr.buffer_len() + seg.buffer_len()];
        eth_repr.emit(&mut EthernetFrame::new_unchecked(&mut buf[..]));
        {
            let mut p = Ipv4Packet::new_unchecked(&mut buf[IP_OFF..]);
            ip_repr.emit(&mut p, &ChecksumCapabilities::default());
        }
        {
            let mut p = TcpPacket::new_unchecked(&mut buf[TCP_OFF..]);
            seg.emit(
                &mut p,
                &IpAddress::Ipv4(src),
                &IpAddress::Ipv4(dst),
                &ChecksumCapabilities::default(),
            );
        }
        buf
    }

    #[test]
    fn is_unicast_classifies_addresses() {
        assert!(is_unicast(SERVER_IP));
        assert!(!is_unicast(Ipv4Address::new(224, 0, 0, 5))); // multicast
        assert!(!is_unicast(Ipv4Address::new(255, 255, 255, 255))); // broadcast
        assert!(!is_unicast(Ipv4Address::new(0, 0, 0, 0))); // unspecified
    }

    #[test]
    fn peeks_a_tcp_syn() {
        let frame = craft(GUEST_IP, SERVER_IP, &syn());
        assert_eq!(
            peek_tcp_syn(&frame, GW_MAC),
            Some(SynFlow {
                dst: SERVER_IP,
                dst_port: 80,
            }),
        );
    }

    #[test]
    fn ignores_a_syn_ack() {
        let frame = craft(
            GUEST_IP,
            SERVER_IP,
            &tcp(TcpControl::Syn, Some(TcpSeqNumber(1)), 80),
        );
        assert_eq!(peek_tcp_syn(&frame, GW_MAC), None);
    }

    #[test]
    fn ignores_a_bare_ack() {
        let frame = craft(
            GUEST_IP,
            SERVER_IP,
            &tcp(TcpControl::None, Some(TcpSeqNumber(1)), 80),
        );
        assert_eq!(peek_tcp_syn(&frame, GW_MAC), None);
    }

    #[test]
    fn ignores_non_ipv4_and_truncated() {
        let mut arp = vec![0u8; 14];
        EthernetRepr {
            src_addr: GUEST_MAC,
            dst_addr: GW_MAC,
            ethertype: EthernetProtocol::Arp,
        }
        .emit(&mut EthernetFrame::new_unchecked(&mut arp[..]));
        assert_eq!(peek_tcp_syn(&arp, GW_MAC), None);
        assert_eq!(peek_tcp_syn(&[0x00, 0x11, 0x22], GW_MAC), None);
    }

    #[test]
    fn ignores_a_frame_for_a_different_mac() {
        // A valid SYN addressed at L2 to some other MAC — poll's process_ethernet
        // drops it (not our hardware address), so the peek must too.
        let mut frame = craft(GUEST_IP, SERVER_IP, &syn());
        frame[0..6].copy_from_slice(&[0x02, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA]);
        assert_eq!(peek_tcp_syn(&frame, GW_MAC), None);
    }

    // --- The peek must not accept what the datapath (poll) would drop. Each of
    // these was proven to slip past the pre-fix peek by the scrutinize panel. ---

    #[test]
    fn ignores_bad_ipv4_checksum() {
        let mut frame = craft(GUEST_IP, SERVER_IP, &syn());
        Ipv4Packet::new_unchecked(&mut frame[IP_OFF..]).set_checksum(0xDEAD);
        assert_eq!(peek_tcp_syn(&frame, GW_MAC), None);
    }

    #[test]
    fn ignores_bad_tcp_checksum() {
        let mut frame = craft(GUEST_IP, SERVER_IP, &syn());
        TcpPacket::new_unchecked(&mut frame[TCP_OFF..]).set_checksum(0xDEAD);
        assert_eq!(peek_tcp_syn(&frame, GW_MAC), None);
    }

    #[test]
    fn ignores_ipv4_fragments() {
        let mut frame = craft(GUEST_IP, SERVER_IP, &syn());
        // A first fragment with a VALID checksum, so only the fragment flag —
        // not a checksum error — is what rejects it.
        let mut ip = Ipv4Packet::new_unchecked(&mut frame[IP_OFF..]);
        ip.set_more_frags(true);
        ip.fill_checksum();
        assert_eq!(peek_tcp_syn(&frame, GW_MAC), None);
    }

    #[test]
    fn ignores_non_unicast_source() {
        // Multicast source — the datapath's ingress gate drops it.
        let frame = craft(Ipv4Address::new(224, 0, 0, 5), SERVER_IP, &syn());
        assert_eq!(peek_tcp_syn(&frame, GW_MAC), None);
    }

    #[test]
    fn ignores_non_unicast_destination() {
        // Broadcast destination is not a real egress connection.
        let frame = craft(GUEST_IP, Ipv4Address::new(255, 255, 255, 255), &syn());
        assert_eq!(peek_tcp_syn(&frame, GW_MAC), None);
    }

    #[test]
    fn ignores_port_zero() {
        let frame = craft(GUEST_IP, SERVER_IP, &tcp(TcpControl::Syn, None, 0));
        assert_eq!(peek_tcp_syn(&frame, GW_MAC), None);
    }
}
