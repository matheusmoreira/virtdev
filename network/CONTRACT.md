# Replacement network contract

This file defines the behavior the freestanding Rust backend must preserve
before it can replace passt and the temporary host firewall. The current
launcher remains authoritative until the replacement passes the migration gate
below.

## Isolation and policy

- Each VM has its own backend process and bounded state. No flow, DNS, or log
  state is shared between projects.
- Host and inter-project isolation are hard boundaries. Parse errors, resource
  exhaustion, and missing policy deny new traffic rather than widening access.
- Zone selection precedence is explicit `--zone`, then the host-controlled
  project `zone` file, then `none`. An absent or invalid file selects `none`.
- The public meanings of `none`, `wan`, `lan`, `full`, and custom host-port
  zones remain unchanged. Host-to-guest SSH replies remain available in every
  zone; they do not authorize guest-initiated host access.
- A denied TCP flow is silently dropped. The backend does not synthesize a RST
  that could disclose policy or destination state.

IPv4/TCP admission is keyed by source address and port plus destination address
and port. Retransmitted SYNs are idempotent for that key. UDP and IPv6 flow
admission are future extensions and must define equally complete identities
before they are enabled.

## DNS authority

The install-time guest resolver is independent from backend DHCP or DNS
observation. Per-domain egress policy is future work: no domain rule is part of
the current CLI or configuration contract, and no precedence relative to zones
is implied yet.

## Transport and lifecycle

- QEMU framing, maximum frame size, and negotiated offloads are explicit and
  tested. Incomplete reads and writes never publish or discard a partial frame.
- Backend readiness is proven before the SSH port or launch success is
  published.
- If a ready backend later dies, the VM continues running offline. Network
  state is fail-closed, status must expose the degraded condition, and recovery
  requires a bounded backend or VM restart. Backend death never widens policy.
- Shutdown and cleanup remain per-VM and must not delete controls owned by an
  indeterminate or live process.

## Migration gate

The Rust backend becomes the default only after the canonical gate covers zone
semantics, full flow identity, bounded parser and resource failure, stream
short-I/O, exact QEMU feature arguments, readiness, backend death, cleanup, and
packaged execution. The temporary firewall stays untouched until that behavior
is implemented and verified; removal is a separate migration.
