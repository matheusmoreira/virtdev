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

The ruleset is fixed and project-agnostic. One base rule narrows to the user's
_virtdev.slice_ - every machine, matched by cgroup ancestry - then one rule per
relaxation zone matches that zone's shared slice. Identity stays in the unit
name _virtdev-<project>.service_; there is no per-project slice.

This command is normally reached through the *virtdev*(1) dispatcher
(_virtdev firewall <subcommand>_) rather than run directly.

# COMMANDS

*apply*
	Generate, validate, atomically install, and load the ruleset. Requires
	*root* via *sudo*, run as your normal user: it reads *SUDO_UID* to learn
	whose machines to protect and refuses to run as bare root. The target user
	must have *lingering* enabled (see *loginctl*(1)) so the resident units run
	from boot to shutdown. apply installs the holder and the per-zone _pin_
	units, starts the pins (which materialise the per-zone cgroup
	directories), generates the ruleset to _/etc/virtdev/firewall.nft_,
	validates it with _nft -c_, installs it with an atomic _rename_(2), and
	restarts the holder to load it. Re-running apply is safe and idempotent.

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
the per-project zone file, or defaulting to *none*. Zones are a fixed registry;
each maps to a shared slice _virtdev-<zone>.slice_.

*none*
	Deny by default. Nothing is reachable except the inbound SSH session -
	_virtdev ssh_ still works, because its reply rides host loopback, which
	every zone permits. This is the default when _--zone_ is omitted and when
	the project zone file is absent or invalid.

*wan*
	Adds the WAN (the public internet). The host and the LAN stay blocked. The
	zone for ordinary development that needs package registries but must remain
	isolated from the host.

*full*
	Adds the local environment: host *and* LAN *and* WAN. The explicit opt-out
	of host isolation; host and LAN move together.

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
window between the check and the launch.

# FILES

_/etc/virtdev/firewall.nft_
	The generated ruleset. Admin state, kept under _/etc_, never the
	package-managed _/usr/lib_. Installed atomically, so the previous good file
	survives a failed apply.

_/etc/virtdev/firewall.base_
	The recorded baseline, _<uid> <virtdev.slice-inode>_, written by the holder
	after each load. The rootless guard and _status_ read it.

_/usr/lib/systemd/system/virtdev-firewall.service_
	The resident holder. A packaged install ships it here; a source checkout's
	_apply_ copies it to _/etc/systemd/system_ instead.

_/usr/lib/systemd/user/virtdev-firewall-pin@.service_
	The per-zone resident pin template (a *--user* unit). One instance per
	relaxation zone (_wan_, _full_) keeps that zone's cgroup directory present
	so the ruleset can reference it. Requires lingering.

# EXIT STATUS

*status* exits *0* if the lockdown is active and *1* if it is not. *apply* and
*hold* exit *0* on success, or one of:

*64*
	Usage error: unknown subcommand.

*92*
	apply: not run via *sudo*, or the target identity is indeterminate.

*93*
	apply: the generated ruleset was rejected by _nft -c_, or a registry zone
	has no policy case.

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

The launch guard in *virtdev-start*(1) and *virtdev-maintain*(1) returns *88*
when the lockdown is not active.

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
