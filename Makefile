# Copyright 2022 Mitchell Kember. Subject to the MIT License.

define usage
Targets:
	all       Build the blog
	help      Show this help message
	check     Run before committing
	validate  Validate HTML files
	clean     Remove build output

Variables:
	DESTDIR    Destination directory (default: $(default_destdir))
	FONT_URL   WOFF2 font directory URL (default: $(default_font_url))
	HOME_URL   Homepage URL to link to when embedding in a larger site
	ANALYTICS  HTML file to include for analytics
endef

.PHONY: all help check validate clean

default_destdir := public
default_font_url := ../fonts

export DESTDIR ?= $(default_destdir)
FONT_URL ?= $(default_font_url)

src_post := $(wildcard posts/*.md)
src_asset := $(wildcard assets/img/*.jpg)
src_css := assets/css/style.css

page := $(patsubst %,$(DESTDIR)/%.html,index post/index categories/index)
post := $(src_post:posts/%.md=$(DESTDIR)/post/%/index.html)
html := $(page) $(post)
asset := $(src_asset:assets/%=$(DESTDIR)/%)
css := $(DESTDIR)/style.css
all := $(html) $(assets) $(css)

stamp := build/stamp
gen := $(stamp) $(html)
dep := $(stamp) $(html:$(DESTDIR)/%.html=build/%.d)

.SUFFIXES:

all: $(all)

help:
	$(info $(usage))
	@:

check: all validate

validate: $(html)
	vnu $^

clean:
	rm -rf $(default_destdir) build

$(stamp): posts $(src_post)
$(post): | hlsvc.sock

$(gen): gen.ts
	bun run $< $@

$(asset): $(DESTDIR)/%: | assets/%
	ln -sfn $(CURDIR)/(firstword $|) $@

$(css): $(src_css)
	sed 's#$$FONT_URL#$(FONT_URL)#' $< > $@

.INTERMEDIATE: hlsvc.sock hlsvc.fifo

build/hlsvc: hlsvc/main.go
	cd $(dir $<) && go build -o ../$@

hlsvc.sock: build/hlsvc hlsvc.fifo
	$< $@ $(word 2,$^) &
	< $(word 2,$^)

hlsvc.fifo:
	mkfifo $@

$(sort $(dir $(all))):
	mkdir -p $@

ifeq (,$(filter help clean,$(MAKECMDGOALS)))
-include $(dep)
endif

.SECONDEXPANSION:

$(all): | $$(@D)/
