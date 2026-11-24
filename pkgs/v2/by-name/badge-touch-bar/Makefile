CC ?= cc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -Os
CPPFLAGS += -D_GNU_SOURCE $(shell $(PKG_CONFIG) --cflags json-c)
CFLAGS += -std=c11 -Wall -Wextra -Werror -ffunction-sections -fdata-sections
LDLIBS += $(shell $(PKG_CONFIG) --libs json-c)
LDFLAGS += -Wl,--gc-sections
SOURCES = apps.c state.c sway.c units.c bar.c process.c

all: badge-touch-bar
badge-touch-bar: main.c $(SOURCES) bar.h
	$(CC) $(CPPFLAGS) $(CFLAGS) main.c $(SOURCES) $(LDFLAGS) $(LDLIBS) -o $@
state-test: tests/state.c $(SOURCES) bar.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -I. tests/state.c $(SOURCES) $(LDFLAGS) $(LDLIBS) -o $@
check: state-test
	./state-test
.PHONY: all check
