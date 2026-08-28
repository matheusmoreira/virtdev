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

scripts := $(filter-out bin/virtdev-exchange,$(wildcard bin/virtdev bin/virtdev-*))
libraries := $(wildcard lib/virtdev/*)
iso_scripts := iso/profiledef.sh \
	iso/airootfs/root/virtdev/install.sh \
	iso/airootfs/root/virtdev/virtdev-ssh-hostkeys
test_scripts := $(wildcard tests/run tests/test-*.bash tests/fixtures/*)
manpages := $(patsubst %.scd,%,$(wildcard man/*.scd))

all: bin/virtdev-exchange $(manpages)

bin/virtdev-exchange: source/virtdev/exchange.c
	$(CC) -std=c99 $(CFLAGS) $(LDFLAGS) -o $@ $<

man/%: man/%.scd
	$(SCDOC) < $< > $@

clean:
	rm -f bin/virtdev-exchange $(manpages)

check: bin/virtdev-exchange
	bash -n $(scripts) $(libraries) $(iso_scripts) $(test_scripts)
	shellcheck $(scripts) $(libraries) $(iso_scripts) $(test_scripts)
	bash tests/run
	cargo fmt --manifest-path network/Cargo.toml --all -- --check
	cargo build --manifest-path network/Cargo.toml --workspace --locked --offline
	cargo test --manifest-path network/Cargo.toml --all-targets --locked --offline

.PHONY: all clean check
