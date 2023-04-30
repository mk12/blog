# Copyright 2022 Mitchell Kember. Subject to the MIT License.

define usage
Targets:
	all       Build the blog
	help      Show this help message
	check     Run before committing
	serve     Serve the blog locally
	fmt       Format source files
	lint 	  Lint source files
	validate  Validate HTML files
	clean     Remove website output
	clobber   Remove website and build output

Variables:
	DESTDIR    Destination directory (default: $(default_destdir))
	FONT_URL   WOFF2 font directory URL (default: $(default_font_url))
	PORT       Port to serve on (default: $(default_port))
	BASE_URL   Base URL where the blog is hosted
	HOME_URL   Homepage URL to link to when embedding in a larger site
	ANALYTICS  HTML file to include for analytics
endef

.PHONY: all help check serve fmt lint validate clean clobber

default_destdir := public
default_font_url := ../fonts
default_port := 8080

export DESTDIR ?= $(default_destdir)
export FONT_URL ?= $(default_font_url)
export PORT ?= $(default_port)

page := $(patsubst %,$(DESTDIR)%index.html,/ /post/ /categories/)
post := $(shell zig-out/bin/list-posts)
html := $(page) $(post)
xml := $(DESTDIR)/index.xml
all := $(html) $(xml)

src_css := assets/css/style.css
css := $(DESTDIR)/style.css

.SUFFIXES:

all: $(all)

help:
	$(info $(usage))
	@:

check: all fmt lint validate

serve:
	bun run bun-src/serve.ts

fmt:
	bunx prettier -w bun-src/*.ts
	go fmt -C hlsvc

lint:
	bunx eslint --fix bun-src/*.ts
	go mod tidy -C hlsvc
	go vet -C hlsvc
	go fix -C hlsvc

validate: $(html)
	vnu $^

clean:
	rm -rf $(default_destdir)

clobber: clean
	rm -rf build

$(html): | $(css)
$(post): | hlsvc.sock

$(all): $(DESTDIR)/%: bun-src/main.ts $(wildcard bun-src/*.ts)
	bun run $< $(DESTDIR) $*

$(css): $(src_css)
	mkdir -p $(dir $@)
	sed 's#$$FONT_URL#$(FONT_URL)#' $< > $@

build/hlsvc: hlsvc/main.go
	cd $(dir $<) && go build -o ../$@

.INTERMEDIATE: hlsvc.sock hlsvc.fifo

hlsvc.sock: build/hlsvc hlsvc.fifo
	$< $@ $(word 2,$^) &
	< $(word 2,$^)

hlsvc.fifo:
	mkfifo $@

-include $(all:%=%.d)
