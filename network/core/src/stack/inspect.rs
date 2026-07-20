//! Flow inspection: peek a new TCP flow's destination off an inbound frame.
//!
//! The reactor peeks each inbound frame *before* `poll`, so the flow manager can
//! learn the `(dst, port)` a new connection is dialing, consult policy, and — if
//! allowed — provision a smoltcp listening socket on that exact destination on
//! demand (AnyIP transparent termination; design spec §5.1). Because smoltcp
//! accepts *any* destination under AnyIP, this peek plus the policy gate are what
//! actually decide what may leave the machine.
//!
//! We parse with smoltcp's audited, bounds-checked, `#![deny(unsafe_code)]`
//! `wire` parsers — the same ones `poll` uses — reading a few header fields they
//! already validate, rather than a hand-rolled IP/TCP parser that would duplicate
//! that parsing. (The DNS parser we still own — a distinct untrusted surface, M3.)

use smoltcp::wire::{
    EthernetFrame, EthernetProtocol, IpProtocol, Ipv4Address, Ipv4Packet, TcpPacket,
};

/// A guest-initiated TCP connection attempt: the destination the guest is
/// dialing. `(dst, dst_port)` is what the flow manager provisions a listening
/// socket on; smoltcp learns the source from the frame itself.
#[derive(Debug, PartialEq)]
pub struct SynFlow {
    pub dst: Ipv4Address,
    pub dst_port: u16,
}

/// Peek a new-flow TCP SYN off the front of an L2 frame. Returns `Some` only for
/// a *pure* SYN (connection open) over IPv4/Ethernet; `None` for anything else —
/// not IPv4, not TCP, a SYN/ACK or mid-connection segment, or malformed input.
/// The parsers are bounds-checked, so hostile bytes yield `None`, never a
/// panic or overread.
pub fn peek_tcp_syn(frame: &[u8]) -> Option<SynFlow> {
    let eth = EthernetFrame::new_checked(frame).ok()?;
    if eth.ethertype() != EthernetProtocol::Ipv4 {
        return None;
    }
    let ipv4 = Ipv4Packet::new_checked(eth.payload()).ok()?;
    if ipv4.next_header() != IpProtocol::Tcp {
        return None;
    }
    let tcp = TcpPacket::new_checked(ipv4.payload()).ok()?;
    // A connection open is SYN set and ACK clear; a SYN/ACK (both) or a bare ACK
    // is not a new flow.
    if !tcp.syn() || tcp.ack() {
        return None;
    }
    Some(SynFlow {
        dst: ipv4.dst_addr(),
        dst_port: tcp.dst_port(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use smoltcp::phy::ChecksumCapabilities;
    use smoltcp::wire::{
        EthernetAddress, EthernetRepr, IpAddress, Ipv4Repr, TcpControl, TcpRepr, TcpSeqNumber,
    };

    const GUEST_MAC: EthernetAddress = EthernetAddress([0x02, 0, 0, 0, 0, 0x02]);
    const GW_MAC: EthernetAddress = EthernetAddress([0x02, 0, 0, 0, 0, 0x01]);
    const GUEST_IP: Ipv4Address = Ipv4Address::new(10, 0, 0, 2);
    const SERVER_IP: Ipv4Address = Ipv4Address::new(93, 184, 216, 34);

    fn repr(control: TcpControl, ack: Option<TcpSeqNumber>) -> TcpRepr<'static> {
        TcpRepr {
            src_port: 49152,
            dst_port: 80,
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

    fn craft_tcp(tcp_repr: &TcpRepr) -> Vec<u8> {
        let ip_repr = Ipv4Repr {
            src_addr: GUEST_IP,
            dst_addr: SERVER_IP,
            next_header: IpProtocol::Tcp,
            payload_len: tcp_repr.buffer_len(),
            hop_limit: 64,
        };
        let eth_repr = EthernetRepr {
            src_addr: GUEST_MAC,
            dst_addr: GW_MAC,
            ethertype: EthernetProtocol::Ipv4,
        };
        let mut buf =
            vec![0u8; eth_repr.buffer_len() + ip_repr.buffer_len() + tcp_repr.buffer_len()];
        {
            let mut f = EthernetFrame::new_unchecked(&mut buf[..]);
            eth_repr.emit(&mut f);
        }
        let ip_off = eth_repr.buffer_len();
        {
            let mut p = Ipv4Packet::new_unchecked(&mut buf[ip_off..]);
            ip_repr.emit(&mut p, &ChecksumCapabilities::default());
        }
        {
            let tcp_off = ip_off + ip_repr.buffer_len();
            let mut p = TcpPacket::new_unchecked(&mut buf[tcp_off..]);
            tcp_repr.emit(
                &mut p,
                &IpAddress::Ipv4(GUEST_IP),
                &IpAddress::Ipv4(SERVER_IP),
                &ChecksumCapabilities::default(),
            );
        }
        buf
    }

    #[test]
    fn peeks_a_tcp_syn() {
        let frame = craft_tcp(&repr(TcpControl::Syn, None));
        assert_eq!(
            peek_tcp_syn(&frame),
            Some(SynFlow {
                dst: SERVER_IP,
                dst_port: 80,
            }),
        );
    }

    #[test]
    fn ignores_a_syn_ack() {
        // SYN+ACK (both flags) is a handshake reply, not a new-flow open.
        let frame = craft_tcp(&repr(TcpControl::Syn, Some(TcpSeqNumber(1))));
        assert_eq!(peek_tcp_syn(&frame), None);
    }

    #[test]
    fn ignores_a_bare_ack() {
        // A pure ACK (no SYN) is mid-connection.
        let frame = craft_tcp(&repr(TcpControl::None, Some(TcpSeqNumber(1))));
        assert_eq!(peek_tcp_syn(&frame), None);
    }

    #[test]
    fn ignores_non_ipv4_and_truncated() {
        // Non-IPv4 ethertype (an ARP-typed header).
        let mut arp = vec![0u8; 14];
        EthernetRepr {
            src_addr: GUEST_MAC,
            dst_addr: GW_MAC,
            ethertype: EthernetProtocol::Arp,
        }
        .emit(&mut EthernetFrame::new_unchecked(&mut arp[..]));
        assert_eq!(peek_tcp_syn(&arp), None);
        // Fewer bytes than even an Ethernet header — bounds-checked to None.
        assert_eq!(peek_tcp_syn(&[0x00, 0x11, 0x22]), None);
    }
}
