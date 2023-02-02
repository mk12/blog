# Copyright 2022 Mitchell Kember. Subject to the MIT License.

define usage
Targets:
	all    Build the blog
	help   Show this help message
	check  Run before committing
	clean  Remove build output

Variables:
	DESTDIR    Destination directory (default: $(default_destdir))
	FONT_URL   WOFF2 font directory URL (default: $(default_font_url))
	HOME_URL   Homepage URL to link to when embedding in a larger site
	ANALYTICS  HTML file to include for analytics
endef

.PHONY: all help check clean

default_destdir := public
default_font_url := ../../fonts

DESTDIR ?= $(default_destdir)
FONT_URL ?= $(default_font_url)

.SUFFIXES:

all:
	@echo TODO

help:
	$(info $(usage))
	@:

check: all

clean:
	rm -rf $(default_destdir)

