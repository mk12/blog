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

DESTDIR ?= $(default_destdir)
FONT_URL ?= $(default_font_url)

src_posts := $(wildcard posts/*.md)
src_assets := $(wildcard assets/img/*.jpg)
src_css := assets/css/style.css

pages := $(patsubst %,$(DESTDIR)/%.html,index post/index categories/index)
posts := $(src_posts:posts/%.md=$(DESTDIR)/post/%/index.html)
assets := $(src_assets:assets/%=$(DESTDIR)/%)
css := $(DESTDIR)/style.css

html := $(pages) $(posts)

depfiles := $(src_posts:posts/%.md=build/%.d)

directories := build $(DESTDIR) $(DESTDIR)/post \
	$(sort $(dir $(posts)) $(dir $(assets)))
directories := $(directories:%/=%)

.SUFFIXES:

all: $(html) $(assets) $(css)
	@echo TODO

help:
	$(info $(usage))
	@:

check: all validate

validate: $(html)
	vnu $(html)

clean:
	rm -rf $(default_destdir) build

# $(html): gen.ts | build highlight.sock

$(posts): $(DESTDIR)/post/%/index.html: gen.ts posts/%.md build/highlight \
		| highlight.sock build
	bun run $< -i $(word 2,$^) -o $@ -d build/$*.d -s $(word 1,$|)

$(assets): $(DESTDIR)/%: | assets/%
	ln -sfn $(CURDIR)/$(firstword $|) $@

$(css): $(src_css)
	sed 's#$$FONT_URL#$(FONT_URL)#' $< > $@

.INTERMEDIATE: highlight.sock highlight.fifo

build/highlight: highlight/main.go
	cd $(dir $<) && go build -o ../$@

highlight.sock: build/highlight highlight.fifo
	$< $@ $(word 2,$^) &
	< $(word 2,$^)

highlight.fifo:
	mkfifo $@

$(directories):
	mkdir -p $@

-include $(depfiles)

.SECONDEXPANSION:

$(html) $(assets) $(css) $(directories): | $$(@D)
