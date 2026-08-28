//! The guest's L3: a smoltcp `Interface` that terminates the guest's traffic.
//!
//! We present the guest a gateway at `GATEWAY_IP`/`GATEWAY_MAC` and run
//! smoltcp in **AnyIP** mode. In smoltcp 0.13.1 `set_any_ip(true)` makes the
//! interface accept and locally terminate **every unicast IPv4 destination** —
//! `has_ip_addr` short-circuits to `true` under AnyIP (the `set_any_ip` doc
//! comment's route-gated wording is stale vs the code; confirmed via CHANGELOG
//! #1119). So the guest's traffic to the whole internet lands on us: the
//! transparent-termination linchpin (design spec §5.1). The catch-all default
//! route via our own IP governs the *reply* direction (source selection +
//! next-hop), not ingress acceptance.
//!
//! Because AnyIP acceptance is deliberately wide open, **the egress allow-list
//! lives in our code**, not in smoltcp's gate: we inspect each new flow, consult
//! policy, and only then provision a socket / dial the real host. smoltcp
//! terminating a flow is not permission for it to leave the machine.

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

/// The guest's network stack: the smoltcp interface plus our device. Owns both;
/// `poll` drives them together via a split borrow. The flow sockets and their
/// buffers are owned by the caller (the reactor) and passed to `poll`.
pub struct NetStack {
    iface: Interface,
    device: QemuDevice,
}

impl NetStack {
    /// Build the interface in AnyIP mode with a catch-all default route, so it
    /// terminates traffic to any destination. `now` seeds smoltcp's clock.
    pub fn new(now: Instant) -> Self {
        let mut device = QemuDevice::new();

        let config = Config::new(HardwareAddress::Ethernet(GATEWAY_MAC));
        let mut iface = Interface::new(config, &mut device, now);

        // Assign the gateway address to the interface.
        iface.update_ip_addrs(|addrs| {
            addrs
                .push(IpCidr::Ipv4(Ipv4Cidr::new(GATEWAY_IP, SUBNET_PREFIX_LEN)))
                .expect("one IP fits the interface address table");
        });

        // AnyIP: accept + locally terminate any unicast destination. The default
        // route (gateway = our own IP) is for the reply direction.
        iface.set_any_ip(true);
        iface
            .routes_mut()
            .add_default_ipv4_route(GATEWAY_IP)
            .expect("the route table holds one default route");

        Self { iface, device }
    }

    /// The datapath device, for the reactor to load inbound frames into and
    /// drain outbound frames from.
    pub fn device_mut(&mut self) -> &mut QemuDevice {
        &mut self.device
    }

    /// Drive one poll: smoltcp consumes any frame parked in the device's inbound
    /// slot and emits responses into its outbound slot. `sockets` (the flow
    /// sockets + their buffers) is owned by the caller. The `&mut self.iface` and
    /// `&mut self.device` borrows are disjoint fields, so this split borrows.
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

    /// Build a raw `Ethernet | IPv4 | TCP(SYN)` frame from the guest to
    /// `server_ip:dst_port`, addressed at L2 to our gateway MAC. Real checksums.
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

    /// The guest's ARP reply to our "who-has GATEWAY_IP" — tells smoltcp the
    /// guest's MAC so it can address the SYN/ACK back.
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
    fn builds_an_anyip_interface_with_a_default_route() {
        let stack = NetStack::new(Instant::ZERO);
        // AnyIP is enabled...
        assert!(stack.iface.any_ip());
        // ...and the gateway address is actually assigned. (`has_ip_addr` is
        // vacuous under AnyIP — it returns true for *any* address — so assert the
        // address table directly, which AnyIP does not gate.)
        assert_eq!(stack.iface.ipv4_addr(), Some(GATEWAY_IP));
    }

    /// THE SPIKE (design spec §9.1): prove transparent termination end-to-end.
    /// With AnyIP on, a TCP socket listening on an address the interface does NOT
    /// own accepts the guest's SYN to that address, and — after the ARP round-trip
    /// the reply requires — emits the real SYN/ACK back to the guest.
    #[test]
    fn anyip_terminates_a_flow_to_a_non_owned_destination() {
        let guest_mac = EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x02]);
        let guest_ip = Ipv4Address::new(10, 0, 0, 2); // in our subnet (no gateway hop)
        let server_ip = Ipv4Address::new(93, 184, 216, 34); // NOT owned by the interface

        let mut stack = NetStack::new(Instant::ZERO);

        // A TCP socket listening on the arbitrary destination. Borrowed (no-alloc)
        // storage: the socket set and the ring buffers all live in this frame.
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

        // Poll 1: feed the guest's SYN to 93.184.216.34:80.
        let syn = craft_syn(guest_mac, guest_ip, server_ip, 49152, 80);
        stack.device_mut().load_inbound(&syn);
        stack.poll(Instant::ZERO, &mut sockets);

        // smoltcp accepted a SYN to an IP it does not own (AnyIP) and entered the
        // handshake — the acceptance half of transparent termination.
        assert_eq!(
            sockets.get::<tcp::Socket>(handle).state(),
            tcp::State::SynReceived,
        );
        // It cannot send the SYN/ACK yet: it has never seen the guest's MAC, so
        // the FIRST outbound frame is an ARP request to resolve the guest.
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

        // The reactor sends the ARP and drains the slot; the guest ARP-replies.
        stack.device_mut().clear_outbound();
        let arp_reply = craft_arp_reply(guest_mac, guest_ip);
        stack.device_mut().load_inbound(&arp_reply);
        stack.poll(Instant::from_millis(250), &mut sockets);

        // NOW the reply datapath completes: the outbound frame is the IPv4 TCP
        // SYN/ACK from 93.184.216.34:80 back to the guest.
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
