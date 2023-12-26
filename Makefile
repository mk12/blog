# Copyright 2022 Mitchell Kember. Subject to the MIT License.

define usage
Targets:
	all       Build the blog
	help      Show this help message
	check     Run before committing
	serve     Serve the blog locally
	fmt       Format source files
	validate  Validate HTML files
	clean     Remove website and build output

Variables:
	DESTDIR    Destination directory (default: $(default_destdir))
	FONT_URL   WOFF2 font directory URL (default: $(default_font_url))
	PORT       Port to serve on (default: $(default_port))
	BASE_URL   Base URL where the blog is hosted
	HOME_URL   Homepage URL to link to when embedding in a larger site
	ANALYTICS  HTML file to include for analytics
endef

.PHONY: all help check serve fmt validate clean

default_destdir := public
default_font_url := ../fonts
default_port := 8080

export DESTDIR ?= $(default_destdir)
export FONT_URL ?= $(default_font_url)
export PORT ?= $(default_port)

bin := zig-out/bin/genblog

.SUFFIXES:

all: $(bin)
	$^ $(DESTDIR)

help:
	$(info $(usage))
	@:

check: all fmt validate

$(bin): build.zig $(wildcard src/*.zig)
	env -u DESTDIR zig build

serve:
	bun run serve.ts

fmt:
	zig fmt src

validate: all
	vnu --skip-non-html $(DESTDIR)

clean:
	rm -rf $(default_destdir) zig-out zig-cache
