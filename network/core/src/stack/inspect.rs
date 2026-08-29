//! Validated inspection of new guest TCP flows.
//!
//! Parsing uses smoltcp's checksum and fragment checks. Source classification
//! also uses the configured link CIDR, so a reported SYN can enter the datapath.

use smoltcp::phy::ChecksumCapabilities;
use smoltcp::wire::{
    EthernetAddress, EthernetFrame, EthernetProtocol, IpAddress, IpProtocol, Ipv4Address, Ipv4Cidr,
    Ipv4Packet, Ipv4Repr, TcpControl, TcpPacket, TcpRepr,
};

/// Complete identity of one guest-initiated IPv4/TCP flow.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct TcpFlowKey {
    pub src_addr: Ipv4Address,
    pub src_port: u16,
    pub dst_addr: Ipv4Address,
    pub dst_port: u16,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum IngressInspection {
    Other,
    InvalidDestination,
    InvalidSource,
    TcpSyn(TcpFlowKey),
}

fn is_unicast(addr: Ipv4Address, link_cidr: Ipv4Cidr) -> bool {
    !(addr.is_broadcast()
        || addr.is_multicast()
        || addr.is_unspecified()
        || link_cidr.broadcast() == Some(addr))
}

fn is_guest_source(addr: Ipv4Address, link_cidr: Ipv4Cidr) -> bool {
    is_unicast(addr, link_cidr)
        && link_cidr.contains_addr(&addr)
        && addr != link_cidr.network().address()
        && addr != link_cidr.address()
}

pub(super) fn inspect_ingress(
    frame: &[u8],
    gateway_mac: EthernetAddress,
    link_cidr: Ipv4Cidr,
) -> IngressInspection {
    let caps = ChecksumCapabilities::default();

    let Ok(eth) = EthernetFrame::new_checked(frame) else {
        return IngressInspection::Other;
    };
    if eth.ethertype() != EthernetProtocol::Ipv4 {
        return IngressInspection::Other;
    }
    if eth.dst_addr() != gateway_mac {
        return IngressInspection::InvalidDestination;
    }

    let Ok(ipv4) = Ipv4Packet::new_checked(eth.payload()) else {
        return IngressInspection::Other;
    };
    let Ok(ip) = Ipv4Repr::parse(&ipv4, &caps) else {
        return IngressInspection::Other;
    };
    if !is_guest_source(ip.src_addr, link_cidr) {
        return IngressInspection::InvalidSource;
    }
    if ip.next_header != IpProtocol::Tcp {
        return IngressInspection::Other;
    }
    if !is_unicast(ip.dst_addr, link_cidr) {
        return IngressInspection::Other;
    }

    let Ok(tcp) = TcpPacket::new_checked(ipv4.payload()) else {
        return IngressInspection::Other;
    };
    let Ok(seg) = TcpRepr::parse(
        &tcp,
        &IpAddress::Ipv4(ip.src_addr),
        &IpAddress::Ipv4(ip.dst_addr),
        &caps,
    ) else {
        return IngressInspection::Other;
    };
    if seg.control != TcpControl::Syn
        || seg.ack_number.is_some()
        || seg.src_port == 0
        || seg.dst_port == 0
    {
        return IngressInspection::Other;
    }

    IngressInspection::TcpSyn(TcpFlowKey {
        src_addr: ip.src_addr,
        src_port: seg.src_port,
        dst_addr: ip.dst_addr,
        dst_port: seg.dst_port,
    })
}

#[cfg(test)]
fn peek_tcp_syn(
    frame: &[u8],
    gateway_mac: EthernetAddress,
    link_cidr: Ipv4Cidr,
) -> Option<TcpFlowKey> {
    match inspect_ingress(frame, gateway_mac, link_cidr) {
        IngressInspection::TcpSyn(flow) => Some(flow),
        IngressInspection::Other
        | IngressInspection::InvalidDestination
        | IngressInspection::InvalidSource => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{is_guest_source, is_unicast, peek_tcp_syn, TcpFlowKey};
    use smoltcp::phy::ChecksumCapabilities;
    use smoltcp::wire::{
        EthernetAddress, EthernetFrame, EthernetProtocol, EthernetRepr, IpAddress, IpProtocol,
        Ipv4Address, Ipv4Cidr, Ipv4Packet, Ipv4Repr, TcpControl, TcpPacket, TcpRepr, TcpSeqNumber,
    };

    const GUEST_MAC: EthernetAddress = EthernetAddress([0x02, 0, 0, 0, 0, 0x02]);
    const GW_MAC: EthernetAddress = EthernetAddress([0x02, 0, 0, 0, 0, 0x01]);
    const GUEST_IP: Ipv4Address = Ipv4Address::new(10, 0, 0, 2);
    const SERVER_IP: Ipv4Address = Ipv4Address::new(93, 184, 216, 34);
    const LINK_CIDR: Ipv4Cidr = Ipv4Cidr::new(Ipv4Address::new(10, 0, 0, 1), 24);
    const IP_OFF: usize = 14;
    const TCP_OFF: usize = 34;

    fn tcp_with_ports(
        control: TcpControl,
        ack: Option<TcpSeqNumber>,
        src_port: u16,
        dst_port: u16,
    ) -> TcpRepr<'static> {
        TcpRepr {
            src_port,
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

    fn tcp(control: TcpControl, ack: Option<TcpSeqNumber>, dst_port: u16) -> TcpRepr<'static> {
        tcp_with_ports(control, ack, 49152, dst_port)
    }

    fn syn() -> TcpRepr<'static> {
        tcp(TcpControl::Syn, None, 80)
    }

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
        assert!(is_unicast(SERVER_IP, LINK_CIDR));
        assert!(!is_unicast(Ipv4Address::new(224, 0, 0, 5), LINK_CIDR));
        assert!(!is_unicast(Ipv4Address::new(255, 255, 255, 255), LINK_CIDR));
        assert!(!is_unicast(Ipv4Address::UNSPECIFIED, LINK_CIDR));
        assert!(!is_unicast(Ipv4Address::new(10, 0, 0, 255), LINK_CIDR));
    }

    #[test]
    fn guest_source_is_a_host_on_the_configured_link() {
        assert!(is_guest_source(GUEST_IP, LINK_CIDR));
        assert!(!is_guest_source(Ipv4Address::new(192, 0, 2, 1), LINK_CIDR));
        assert!(!is_guest_source(Ipv4Address::new(10, 0, 0, 0), LINK_CIDR));
        assert!(!is_guest_source(LINK_CIDR.address(), LINK_CIDR));
        assert!(!is_guest_source(Ipv4Address::new(10, 0, 0, 255), LINK_CIDR));
    }

    #[test]
    fn peeks_a_tcp_syn() {
        let frame = craft(GUEST_IP, SERVER_IP, &syn());
        assert_eq!(
            peek_tcp_syn(&frame, GW_MAC, LINK_CIDR),
            Some(TcpFlowKey {
                src_addr: GUEST_IP,
                src_port: 49152,
                dst_addr: SERVER_IP,
                dst_port: 80,
            }),
        );
    }

    #[test]
    fn flow_key_distinguishes_sources_to_the_same_destination() {
        let baseline = craft(
            GUEST_IP,
            SERVER_IP,
            &tcp_with_ports(TcpControl::Syn, None, 49152, 443),
        );
        let changed_port = craft(
            GUEST_IP,
            SERVER_IP,
            &tcp_with_ports(TcpControl::Syn, None, 49153, 443),
        );
        let changed_addr = craft(
            Ipv4Address::new(10, 0, 0, 3),
            SERVER_IP,
            &tcp_with_ports(TcpControl::Syn, None, 49152, 443),
        );

        let baseline = peek_tcp_syn(&baseline, GW_MAC, LINK_CIDR).unwrap();
        let changed_port = peek_tcp_syn(&changed_port, GW_MAC, LINK_CIDR).unwrap();
        let changed_addr = peek_tcp_syn(&changed_addr, GW_MAC, LINK_CIDR).unwrap();
        assert_ne!(baseline, changed_port);
        assert_ne!(baseline, changed_addr);
        assert_eq!((baseline.src_addr, baseline.src_port), (GUEST_IP, 49152));
        assert_eq!(
            (changed_port.src_addr, changed_port.src_port),
            (GUEST_IP, 49153)
        );
        assert_eq!(
            (changed_addr.src_addr, changed_addr.src_port),
            (Ipv4Address::new(10, 0, 0, 3), 49152)
        );
        assert_eq!(
            (baseline.dst_addr, baseline.dst_port),
            (changed_addr.dst_addr, changed_addr.dst_port)
        );
    }

    #[test]
    fn retransmitted_syn_has_the_same_flow_key() {
        let frame = craft(GUEST_IP, SERVER_IP, &syn());
        let first = peek_tcp_syn(&frame, GW_MAC, LINK_CIDR);
        let retry = peek_tcp_syn(&frame, GW_MAC, LINK_CIDR);
        assert_eq!(first, retry);
    }

    #[test]
    fn ignores_a_syn_ack() {
        let frame = craft(
            GUEST_IP,
            SERVER_IP,
            &tcp(TcpControl::Syn, Some(TcpSeqNumber(1)), 80),
        );
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
    }

    #[test]
    fn ignores_a_bare_ack() {
        let frame = craft(
            GUEST_IP,
            SERVER_IP,
            &tcp(TcpControl::None, Some(TcpSeqNumber(1)), 80),
        );
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
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
        assert_eq!(peek_tcp_syn(&arp, GW_MAC, LINK_CIDR), None);
        assert_eq!(peek_tcp_syn(&[0x00, 0x11, 0x22], GW_MAC, LINK_CIDR), None);
    }

    #[test]
    fn ignores_a_frame_for_a_different_mac() {
        let mut frame = craft(GUEST_IP, SERVER_IP, &syn());
        frame[0..6].copy_from_slice(&[0x02, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA]);
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
    }

    #[test]
    fn ignores_bad_ipv4_checksum() {
        let mut frame = craft(GUEST_IP, SERVER_IP, &syn());
        Ipv4Packet::new_unchecked(&mut frame[IP_OFF..]).set_checksum(0xDEAD);
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
    }

    #[test]
    fn ignores_bad_tcp_checksum() {
        let mut frame = craft(GUEST_IP, SERVER_IP, &syn());
        TcpPacket::new_unchecked(&mut frame[TCP_OFF..]).set_checksum(0xDEAD);
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
    }

    #[test]
    fn ignores_ipv4_fragments() {
        let mut frame = craft(GUEST_IP, SERVER_IP, &syn());
        let mut ip = Ipv4Packet::new_unchecked(&mut frame[IP_OFF..]);
        ip.set_more_frags(true);
        ip.fill_checksum();
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
    }

    #[test]
    fn ignores_non_unicast_source() {
        let frame = craft(Ipv4Address::new(224, 0, 0, 5), SERVER_IP, &syn());
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
    }

    #[test]
    fn ignores_link_directed_broadcast_source() {
        let frame = craft(Ipv4Address::new(10, 0, 0, 255), SERVER_IP, &syn());
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
    }

    #[test]
    fn ignores_sources_outside_the_guest_host_range() {
        for source in [
            Ipv4Address::new(192, 0, 2, 1),
            Ipv4Address::new(10, 0, 0, 0),
            LINK_CIDR.address(),
        ] {
            let frame = craft(source, SERVER_IP, &syn());
            assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
        }
    }

    #[test]
    fn ignores_non_unicast_destination() {
        let frame = craft(GUEST_IP, Ipv4Address::new(255, 255, 255, 255), &syn());
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);

        let frame = craft(GUEST_IP, Ipv4Address::new(10, 0, 0, 255), &syn());
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
    }

    #[test]
    fn ignores_zero_ports() {
        let frame = craft(GUEST_IP, SERVER_IP, &tcp(TcpControl::Syn, None, 0));
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);

        let frame = craft(
            GUEST_IP,
            SERVER_IP,
            &tcp_with_ports(TcpControl::Syn, None, 0, 80),
        );
        assert_eq!(peek_tcp_syn(&frame, GW_MAC, LINK_CIDR), None);
    }
}
