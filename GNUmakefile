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
manpages := $(patsubst %.scd,%,$(wildcard man/*.scd))

all: bin/virtdev-exchange $(manpages)

bin/virtdev-exchange: source/virtdev/exchange.c
	$(CC) -std=c99 $(CFLAGS) $(LDFLAGS) -o $@ $<

man/%: man/%.scd
	$(SCDOC) < $< > $@

clean:
	rm -f bin/virtdev-exchange $(manpages)

check: bin/virtdev-exchange
	bash -n $(scripts) $(libraries)
	shellcheck $(scripts) $(libraries)

.PHONY: all clean check
