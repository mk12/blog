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

index := $(DESTDIR)/index.html
archive := $(DESTDIR)/post/index.html
categories := $(DESTDIR)/categories/index.html

pages := $(index) $(archive) $(categories)
posts := $(src_posts:posts/%.md=$(DESTDIR)/post/%/index.html)
html := $(posts) $(pages)
assets := $(src_assets:assets/%=$(DESTDIR)/%)
css := $(DESTDIR)/style.css
artifacts := $(html) $(assets) $(css)

prebuild := build/prebuild.mk
manifest := build/manifest.json
dep = $(patsubst %,build/%.d,$(subst /,_,$(1:$(DESTDIR)/%.html=%)))
depfiles := $(call dep,$(html))
auxiliary := $(prebuild) $(manifest) $(depfiles)

directories := $(sort $(dir $(artifacts) $(auxiliary)))
directories := $(directories:%/=%)

.SUFFIXES:

all: $(artifacts)

help:
	$(info $(usage))
	@:

check: all validate

validate: $(html)
	vnu $(html)

clean:
	rm -rf $(default_destdir) build

$(prebuild): gen.ts posts $(src_posts)
	bun run $< -k manifest -o $(manifest) $(src_posts)
	touch $@

$(index): kind := index
$(archive): kind := archive
$(categories): kind := categories
$(posts): kind := post

$(pages): gen.ts $(manifest)
$(pages): inputs = $(word 2,$^)
$(posts): $(DESTDIR)/post/%/index.html: gen.ts posts/%.md build/%.json
$(posts): inputs = $(wordlist 2,3,$^)
$(index) $(posts): | highlight.sock

highlight_flag = $(if $(filter highlight.sock,$|),-s highlight.sock)

$(html):
	bun run $< $(inputs) -k $(kind) -o $@ -d $(call dep,$@) $(highlight_flag)

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

ifeq (,$(filter help clean,$(MAKECMDGOALS)))
include $(prebuild)
-include $(depfiles)
endif

.SECONDEXPANSION:

$(artifacts) $(auxiliary) $(directories): | $$(@D)
