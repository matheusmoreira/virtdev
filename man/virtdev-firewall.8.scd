virtdev-firewall(8) "virtdev" "virtdev Manual"

# NAME

virtdev-firewall - host egress lockdown for virtdev virtual machines

# SYNOPSIS

*sudo virtdev firewall apply*++
*virtdev firewall status*

# DESCRIPTION

*virtdev-firewall* manages the host-root *nftables* _inet virtdev_ table that
filters the egress of virtdev virtual machines by *zone*. Each machine's network
backend (*passt*(1)) runs as host sockets inside the machine's systemd *--user*
slice cgroup, so a host-root ruleset matched to those cgroups can filter guest
traffic by destination - which passt itself cannot do.

The table carries the nftables *owner* and *persist* flags and is held open by a
resident system service, *virtdev-firewall.service* (the _holder_). While the
holder runs, another process's _nft flush ruleset_ - a host firewall reload -
skips the owned table instead of wiping it, so no reassert timer is needed. The
holder being active is the signal the launch guard checks; see *THE LAUNCH
GUARD* below.

The ruleset is project-agnostic - there is no per-project rule or slice; identity
stays in the unit name _virtdev-<project>.service_. One base rule narrows to the
user's _virtdev.slice_ (every machine, by cgroup ancestry), then one rule per
slice-owning zone - the four built-ins and any user-defined *custom zones* (see
*ZONES*) - jumps to that zone's policy chain.

This command is normally reached through the *virtdev*(1) dispatcher
(_virtdev firewall <subcommand>_) rather than run directly.

# COMMANDS

*apply*
	Generate, validate, atomically install, and load the ruleset. Requires
	*root* via *sudo*, run as your normal user: it reads *SUDO_UID* to learn
	whose machines to protect (and to find that user's custom-zone files) and
	refuses to run as bare root. The target user must have *lingering* enabled
	(see *loginctl*(1)) so the resident units run from boot to shutdown. apply
	parses the user's custom zone-definition files first (a malformed file aborts
	with exit *89* before any change is made), refuses (exit *100*) if removing
	the last host-hole zone would strand a running machine whose passt
	host-loopback map is open (again before any change), installs the holder and
	the per-zone _pin_ units, starts and *reconciles* the pins (materialising each
	zone's cgroup directory; a pin for a removed zone is disabled), generates the
	ruleset to _/etc/virtdev/firewall.nft_, validates it with _nft -c_, installs
	it with an atomic _rename_(2), restarts the holder to load it, and finally
	writes the realized-zone manifest _/etc/virtdev/firewall.zones_. Re-running
	apply is safe and idempotent, and is *required* after adding or editing a
	custom zone. Removing the last custom host hole while a machine still runs in
	it requires stopping that machine first (see exit *100*).

*status*
	Report whether the lockdown is active. Prints _active_ or _inactive_ to
	standard output and exits *0* or *1* accordingly. Rootless: any user may
	query it. This is the *default* subcommand - _virtdev firewall_ with no
	argument runs _status_. "Active" means the holder is running *and* the
	recorded cgroup baseline still matches the live _virtdev.slice_; it fails
	closed on a stale baseline, such as after a user-manager teardown churns
	the cgroup inode.

*hold*
	Internal. The _ExecStart_ of *virtdev-firewall.service*. Loads the
	installed ruleset into the owner,persist table, waits for the pin-backed
	zone cgroups, records the baseline, and holds the owning socket open for
	the unit's lifetime. Not meant to be run by hand; listed for completeness.

# ZONES

A machine launches into exactly one zone, chosen by _virtdev start --zone_, by
the per-project zone file, or defaulting to *none*. Each zone maps to a shared
slice _virtdev-<zone>.slice_. There are four built-ins, plus any *custom zones*.

*none*
	Deny by default. Nothing is reachable except the inbound SSH session -
	_virtdev ssh_ still works, because its reply rides host loopback, which
	every zone permits. This is the default when _--zone_ is omitted and when
	the project zone file is absent or invalid.

*wan*
	Adds the WAN (the public internet). The host and the LAN stay blocked. The
	zone for ordinary development that needs package registries but must remain
	isolated from the host.

*lan*
	Adds the local environment - host *and* LAN - but *not* the WAN. For work
	against a LAN mirror or NAS with no internet access.

*full*
	Adds the local environment AND the WAN: host, LAN, and internet. The explicit
	opt-out of host isolation; host and LAN move together.

A *custom zone* is a user file _~/.config/virtdev/zones/<name>_ declaring a
*base* (one of the built-ins) and one or more *port* lines - e.g. _base wan_ and
_port 1234 tcp udp_. It opens those host ports (reaching a host service the guest
drives, such as a gdbserver) on top of the base, without granting the whole LAN.
The launch enables passt's host-loopback map for the zone, so the guest reaches
the host at its default gateway; the per-port limit is enforced in nft. Names are
lowercase letters, digits, and underscore (no dashes or dots). A custom zone takes
effect only after
*apply* (its rules live in the root ruleset) and is a deliberate breach of host
isolation: driving a host service grants the untrusted guest whatever it permits.
Selecting a zone that is not applied refuses the launch (*virtdev-start*(1) exit
*22*).

The per-project default lives in a host-controlled file,
_$XDG_CONFIG_HOME/virtdev/projects/<name>/zone_, holding a single zone name. It
fails closed to *none* on anything unexpected, and the guest has no path to it.
_virtdev start --unfiltered_ bypasses the lockdown entirely, with a loud
warning.

# THE LAUNCH GUARD

*virtdev-start*(1) and *virtdev-maintain*(1) consult the guard before booting a
machine. It refuses to launch (exit *88*) unless the lockdown is active, its
baseline matches the live cgroup, *and* the caller is the user the firewall was
applied for. Once the machine's unit is active they re-verify its live cgroup
against the baseline - tearing the machine down on a mismatch - to close the
window between the check and the launch. Separately, *virtdev-start*(1) refuses
(exit *22*) a resolved zone that is not in the realized manifest - a custom zone
defined but not yet applied - instead of launching into an empty slice that would
silently lock the machine down.

# FILES

_/etc/virtdev/firewall.nft_
	The generated ruleset. Admin state, kept under _/etc_, never the
	package-managed _/usr/lib_. Installed atomically, so the previous good file
	survives a failed apply.

_/etc/virtdev/firewall.base_
	The recorded baseline, _<uid> <virtdev.slice-inode>_, written by the holder
	after each load. The rootless guard and _status_ read it.

_/etc/virtdev/firewall.zones_
	The realized-zone manifest: one _<zonename> <needs-hostmap>_ line per zone
	(built-ins and customs), written by _apply_ after the holder load succeeds.
	The rootless launch and _list_/_recreate_/_upgrade_ read it to validate a
	zone and decide the host-loopback map; the user's _zones/_ config itself is
	read only by _apply_.

_~/.config/virtdev/zones/<name>_
	A custom zone-definition file (a *base* line and one or more *port* lines).
	Read by _apply_ only, resolved from the target user's home via _SUDO_UID_ — the
	default _~/.config_ location; a non-default _XDG_CONFIG_HOME_ is *not* honored
	for zone definitions. Commit it to your dotfiles.

_/usr/lib/systemd/system/virtdev-firewall.service_
	The resident holder. A packaged install ships it here; a source checkout's
	_apply_ copies it to _/etc/systemd/system_ instead.

_/usr/lib/systemd/user/virtdev-firewall-pin@.service_
	The per-zone resident pin template (a *--user* unit). One instance per
	relaxation zone (_wan_, _lan_, _full_, and each custom zone) keeps that
	zone's cgroup directory present so the ruleset can reference it. Requires
	lingering.

# EXIT STATUS

*status* exits *0* if the lockdown is active and *1* if it is not. *apply* and
*hold* exit *0* on success, or one of:

*64*
	Usage error: unknown subcommand.

*89*
	apply: a custom zone-definition file is invalid (bad directive, missing or
	non-built-in base, bad port or protocol, symlink, oversize, or an illegal
	zone name).

*92*
	apply: not run via *sudo*, or the target identity is indeterminate.

*93*
	apply: the generated ruleset was rejected by _nft -c_.

*94*
	apply: unit install, daemon-reload, or enable failed.

*95*
	apply: the ruleset installed on disk but the holder failed to load it.

*96*
	hold: the ruleset file is missing, or the uid and base cannot be derived
	from it.

*97*
	hold: the table did not come up, or the baseline could not be recorded.

*98*
	apply: lingering is not enabled for the target user.

*99*
	hold: the per-zone cgroup directories never appeared (the pins are not
	running).

*100*
	apply: refused because removing the last custom host-hole zone would strand a
	running machine whose passt host-loopback map is open, widening it to every
	host loopback port. Stop the named machine(s) and re-apply. Nothing is changed.

The launch guard in *virtdev-start*(1) and *virtdev-maintain*(1) returns *88*
when the lockdown is not active; *virtdev-start*(1) returns *22* when the resolved
zone is defined but not applied.

# EXAMPLES

Enable lingering once, so the resident units survive logout, then apply the
lockdown:

```
loginctl enable-linger
sudo virtdev firewall apply
```

Confirm it is active:

```
$ virtdev firewall status
active
```

Launch a machine that can reach the internet but not the host or the LAN:

```
virtdev start myproject --zone wan
```

# SEE ALSO

*virtdev*(1), *virtdev-start*(1), *virtdev-maintain*(1), *nft*(8), *passt*(1),
*loginctl*(1), *systemctl*(1)

The project's _DESIGN.md_ documents the threat model and the complete ruleset.

# AUTHORS

Matheus Afonso Martins Moreira <matheus@matheusmoreira.com>
