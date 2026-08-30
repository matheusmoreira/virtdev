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

scripts := $(wildcard bin/virtdev bin/virtdev-*)
compiled_helpers := libexec/virtdev/virtdev-copy-tree \
	libexec/virtdev/virtdev-archive-gate \
	libexec/virtdev/virtdev-exchange \
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

libexec/virtdev/virtdev-remove-tree: source/virtdev/remove-tree.c
	$(CC) -std=c99 $(CFLAGS) $(LDFLAGS) -o $@ $<

man/%: man/%.scd
	$(SCDOC) < $< > $@

clean:
	rm -f $(compiled_helpers) $(manpages)

check: $(compiled_helpers)
	bash -n $(scripts) $(private_scripts) $(libraries) $(iso_scripts) $(test_scripts)
	shellcheck $(scripts) $(private_scripts) $(libraries) $(iso_scripts) $(test_scripts)
	bash tests/run
	cargo fmt --manifest-path network/Cargo.toml --all -- --check
	cargo build --manifest-path network/Cargo.toml --workspace --locked --offline
	cargo test --manifest-path network/Cargo.toml --all-targets --locked --offline

.PHONY: all clean check
