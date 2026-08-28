//! AnyIP interface that terminates guest traffic addressed to arbitrary IPv4
//! destinations. Acceptance by smoltcp is not policy authorization; the flow
//! layer must admit a connection before opening a host socket.

use smoltcp::iface::{Config, Interface, PollResult, SocketSet};
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, HardwareAddress, IpCidr, Ipv4Address, Ipv4Cidr};

use super::device::QemuDevice;

/// The gateway IP we present to the guest (its default route and, later, DNS).
/// The guest link is `10.0.0.0/24`; the guest will lease `10.0.0.2` via DHCP.
const GATEWAY_IP: Ipv4Address = Ipv4Address::new(10, 0, 0, 1);

/// Prefix length of the guest link subnet.
const SUBNET_PREFIX_LEN: u8 = 24;

/// The gateway MAC we present to the guest. Locally-administered (bit `0x02` of
/// the first octet) and unicast; otherwise arbitrary.
const GATEWAY_MAC: EthernetAddress = EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x01]);

/// smoltcp interface and its single-frame device.
pub struct NetStack {
    iface: Interface,
    device: QemuDevice,
}

impl NetStack {
    /// Build an AnyIP interface. `now` seeds smoltcp's clock.
    pub fn new(now: Instant) -> Self {
        let mut device = QemuDevice::new();

        let config = Config::new(HardwareAddress::Ethernet(GATEWAY_MAC));
        let mut iface = Interface::new(config, &mut device, now);

        iface.update_ip_addrs(|addrs| {
            addrs
                .push(IpCidr::Ipv4(Ipv4Cidr::new(GATEWAY_IP, SUBNET_PREFIX_LEN)))
                .expect("one IP fits the interface address table");
        });

        iface.set_any_ip(true);

        Self { iface, device }
    }

    /// Access the framed transport device.
    pub fn device_mut(&mut self) -> &mut QemuDevice {
        &mut self.device
    }

    /// Consume a queued inbound frame and produce any response.
    pub fn poll(&mut self, now: Instant, sockets: &mut SocketSet<'_>) -> PollResult {
        self.iface.poll(now, &mut self.device, sockets)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use smoltcp::iface::SocketStorage;
    use smoltcp::phy::ChecksumCapabilities;
    use smoltcp::socket::tcp;
    use smoltcp::wire::{
        ArpOperation, ArpPacket, ArpRepr, EthernetFrame, EthernetProtocol, EthernetRepr, IpAddress,
        IpProtocol, Ipv4Packet, Ipv4Repr, TcpControl, TcpPacket, TcpRepr, TcpSeqNumber,
    };

    fn craft_syn(
        guest_mac: EthernetAddress,
        guest_ip: Ipv4Address,
        server_ip: Ipv4Address,
        src_port: u16,
        dst_port: u16,
    ) -> Vec<u8> {
        let tcp_repr = TcpRepr {
            src_port,
            dst_port,
            control: TcpControl::Syn,
            seq_number: TcpSeqNumber(0x1000),
            ack_number: None,
            window_len: 1024,
            window_scale: None,
            max_seg_size: None,
            sack_permitted: false,
            sack_ranges: [None, None, None],
            timestamp: None,
            payload: &[],
        };
        let ip_repr = Ipv4Repr {
            src_addr: guest_ip,
            dst_addr: server_ip,
            next_header: IpProtocol::Tcp,
            payload_len: tcp_repr.buffer_len(),
            hop_limit: 64,
        };
        let eth_repr = EthernetRepr {
            src_addr: guest_mac,
            dst_addr: GATEWAY_MAC,
            ethertype: EthernetProtocol::Ipv4,
        };

        let mut buf =
            vec![0u8; eth_repr.buffer_len() + ip_repr.buffer_len() + tcp_repr.buffer_len()];
        eth_repr.emit(&mut EthernetFrame::new_unchecked(&mut buf[..]));
        let ip_off = eth_repr.buffer_len();
        {
            let mut packet = Ipv4Packet::new_unchecked(&mut buf[ip_off..]);
            ip_repr.emit(&mut packet, &ChecksumCapabilities::default());
        }
        {
            let tcp_off = ip_off + ip_repr.buffer_len();
            let mut packet = TcpPacket::new_unchecked(&mut buf[tcp_off..]);
            tcp_repr.emit(
                &mut packet,
                &IpAddress::Ipv4(guest_ip),
                &IpAddress::Ipv4(server_ip),
                &ChecksumCapabilities::default(),
            );
        }
        buf
    }

    fn craft_arp_reply(guest_mac: EthernetAddress, guest_ip: Ipv4Address) -> Vec<u8> {
        let arp = ArpRepr::EthernetIpv4 {
            operation: ArpOperation::Reply,
            source_hardware_addr: guest_mac,
            source_protocol_addr: guest_ip,
            target_hardware_addr: GATEWAY_MAC,
            target_protocol_addr: GATEWAY_IP,
        };
        let eth = EthernetRepr {
            src_addr: guest_mac,
            dst_addr: GATEWAY_MAC,
            ethertype: EthernetProtocol::Arp,
        };
        let mut buf = vec![0u8; eth.buffer_len() + arp.buffer_len()];
        eth.emit(&mut EthernetFrame::new_unchecked(&mut buf[..]));
        {
            let mut packet = ArpPacket::new_unchecked(&mut buf[eth.buffer_len()..]);
            arp.emit(&mut packet);
        }
        buf
    }

    #[test]
    fn builds_an_anyip_interface() {
        let stack = NetStack::new(Instant::ZERO);
        assert!(stack.iface.any_ip());
        assert_eq!(stack.iface.ipv4_addr(), Some(GATEWAY_IP));
    }

    #[test]
    fn anyip_terminates_a_flow_to_a_non_owned_destination() {
        let guest_mac = EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x02]);
        let guest_ip = Ipv4Address::new(10, 0, 0, 2);
        let server_ip = Ipv4Address::new(93, 184, 216, 34);

        let mut stack = NetStack::new(Instant::ZERO);

        let mut sock_storage = [SocketStorage::EMPTY; 1];
        let mut sockets = SocketSet::new(&mut sock_storage[..]);
        let mut rx = [0u8; 1500];
        let mut tx = [0u8; 1500];
        let socket = tcp::Socket::new(
            tcp::SocketBuffer::new(&mut rx[..]),
            tcp::SocketBuffer::new(&mut tx[..]),
        );
        let handle = sockets.add(socket);
        sockets
            .get_mut::<tcp::Socket>(handle)
            .listen((server_ip, 80))
            .expect("port is non-zero and the socket is fresh");
        assert_eq!(
            sockets.get::<tcp::Socket>(handle).state(),
            tcp::State::Listen
        );

        let syn = craft_syn(guest_mac, guest_ip, server_ip, 49152, 80);
        stack.device_mut().load_inbound(&syn);
        stack.poll(Instant::ZERO, &mut sockets);

        assert_eq!(
            sockets.get::<tcp::Socket>(handle).state(),
            tcp::State::SynReceived,
        );
        {
            let out = stack
                .device_mut()
                .outbound()
                .expect("an ARP request is queued");
            let eth = EthernetFrame::new_checked(out).unwrap();
            assert_eq!(eth.ethertype(), EthernetProtocol::Arp);
            let arp = ArpPacket::new_checked(eth.payload()).unwrap();
            assert_eq!(arp.operation(), ArpOperation::Request);
        }

        stack.device_mut().clear_outbound();
        let arp_reply = craft_arp_reply(guest_mac, guest_ip);
        stack.device_mut().load_inbound(&arp_reply);
        stack.poll(Instant::from_millis(250), &mut sockets);

        let out = stack
            .device_mut()
            .outbound()
            .expect("the SYN/ACK is now queued");
        let eth = EthernetFrame::new_checked(out).unwrap();
        assert_eq!(eth.ethertype(), EthernetProtocol::Ipv4);
        let ipv4 = Ipv4Packet::new_checked(eth.payload()).unwrap();
        assert_eq!(ipv4.src_addr(), server_ip);
        let seg = TcpPacket::new_checked(ipv4.payload()).unwrap();
        assert!(seg.syn() && seg.ack(), "reply is a SYN/ACK");
        assert_eq!(seg.src_port(), 80);
    }
}
