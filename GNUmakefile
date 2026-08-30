# SPDX-License-Identifier: AGPL-3.0-or-later

MAKEFLAGS += --no-builtin-variables --no-builtin-rules

CC ?= cc
CC := $(CC)

CFLAGS ?= -Wall -Wextra -Wpedantic -O2
CFLAGS := $(CFLAGS)

LDFLAGS ?=
LDFLAGS := $(LDFLAGS)

SCDOC ?= scdoc
SCDOC := $(SCDOC)

PREFIX ?= /usr
DESTDIR ?=
bindir ?= $(PREFIX)/bin
libdir ?= $(PREFIX)/lib/virtdev
libexecdir ?= $(PREFIX)/libexec/virtdev
datadir ?= $(PREFIX)/share
docdir ?= $(datadir)/doc/virtdev
licensedir ?= $(datadir)/licenses/virtdev
mandir ?= $(datadir)/man
profiledir ?= $(datadir)/virtdev/profile
systemdsystemunitdir ?= /usr/lib/systemd/system
systemduserunitdir ?= /usr/lib/systemd/user

scripts := $(wildcard bin/virtdev bin/virtdev-*)
compiled_helpers := libexec/virtdev/virtdev-copy-tree \
	libexec/virtdev/virtdev-archive-gate \
	libexec/virtdev/virtdev-exchange \
	libexec/virtdev/virtdev-file-state \
	libexec/virtdev/virtdev-publish \
	libexec/virtdev/virtdev-remove-tree
private_scripts := $(filter-out $(compiled_helpers),$(wildcard libexec/virtdev/*))
libraries := $(wildcard lib/virtdev/*)
iso_scripts := iso/profiledef.sh \
	iso/airootfs/root/virtdev/install.sh \
	iso/airootfs/root/virtdev/timezone \
	iso/airootfs/root/virtdev/virtdev-ssh-hostkeys
test_scripts := $(wildcard tests/run tests/test-*.bash tests/fixtures/*)
manpages := $(patsubst %.scd,%,$(wildcard man/*.scd))

all: $(compiled_helpers) $(manpages)

libexec/virtdev/virtdev-copy-tree: source/virtdev/copy-tree.c
	$(CC) -std=c99 $(CFLAGS) $(LDFLAGS) -o $@ $<

libexec/virtdev/virtdev-archive-gate: source/virtdev/archive-gate.c
	$(CC) -std=c99 $(CFLAGS) $(LDFLAGS) -o $@ $<

libexec/virtdev/virtdev-exchange: source/virtdev/exchange.c
	$(CC) -std=c99 $(CFLAGS) $(LDFLAGS) -o $@ $<

libexec/virtdev/virtdev-file-state: source/virtdev/file-state.c
	$(CC) -std=c99 $(CFLAGS) $(LDFLAGS) -o $@ $<

libexec/virtdev/virtdev-publish: source/virtdev/publish.c
	$(CC) -std=c99 $(CFLAGS) $(LDFLAGS) -o $@ $<

libexec/virtdev/virtdev-remove-tree: source/virtdev/remove-tree.c
	$(CC) -std=c99 $(CFLAGS) $(LDFLAGS) -o $@ $<

man/%: man/%.scd
	$(SCDOC) < $< > $@

install: all
	install -d "$(DESTDIR)$(bindir)" "$(DESTDIR)$(libdir)" \
		"$(DESTDIR)$(libexecdir)" "$(DESTDIR)$(profiledir)"
	install -m 0755 $(scripts) "$(DESTDIR)$(bindir)"
	install -m 0755 $(compiled_helpers) $(private_scripts) \
		"$(DESTDIR)$(libexecdir)"
	install -m 0644 $(libraries) "$(DESTDIR)$(libdir)"
	install -Dm0644 systemd/virtdev-firewall.service \
		"$(DESTDIR)$(systemdsystemunitdir)/virtdev-firewall.service"
	sed -i 's|/usr/bin/virtdev-firewall|$(bindir)/virtdev-firewall|g' \
		"$(DESTDIR)$(systemdsystemunitdir)/virtdev-firewall.service"
	install -Dm0644 systemd/virtdev-firewall-pin@.service \
		"$(DESTDIR)$(systemduserunitdir)/virtdev-firewall-pin@.service"
	cp -a --no-preserve=ownership -- iso/. "$(DESTDIR)$(profiledir)/"
	install -Dm0644 README.md "$(DESTDIR)$(docdir)/README.md"
	install -Dm0644 DESIGN.md "$(DESTDIR)$(docdir)/DESIGN.md"
	install -Dm0644 LICENSE.AGPLv3 "$(DESTDIR)$(licensedir)/LICENSE"
	@for page in $(manpages); do \
		section=$${page##*.}; \
		install -Dm0644 "$${page}" \
			"$(DESTDIR)$(mandir)/man$${section}/$${page##*/}"; \
	done

clean:
	rm -f $(compiled_helpers) $(manpages)

check: $(compiled_helpers)
	bash -n $(scripts) $(private_scripts) $(libraries) $(iso_scripts) $(test_scripts)
	shellcheck $(scripts) $(private_scripts) $(libraries) $(iso_scripts) $(test_scripts)
	bash tests/run
	cargo fmt --manifest-path network/Cargo.toml --all -- --check
	cargo build --manifest-path network/Cargo.toml --workspace --locked --offline
	cargo test --manifest-path network/Cargo.toml --all-targets --locked --offline

.PHONY: all install clean check
