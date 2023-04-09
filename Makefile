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
html := $(pages) $(posts)
assets := $(src_assets:assets/%=$(DESTDIR)/%)
css := $(DESTDIR)/style.css
artifacts := $(html) $(assets) $(css)

prebuild := build/prebuild.mk
manifest := build/manifest.json
depfiles = $(html:$(DESTDIR)/%.html=build/%.d)
auxiliary := $(prebuild) $(manifest) $(depfiles)

sock := highlight.sock
fifo := highlight.fifo

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
	bun run $< manifest -o $(manifest) $(src_posts)
	touch $@

$(foreach var,index archive categories,$(eval $($(var)): name := $(var)))

$(pages): gen.ts $(manifest)
	bun run $< page $(name) -o $@ -d build/$(name).d $(manifest)

$(posts): $(DESTDIR)/post/%/index.html: gen.ts posts/%.md build/%.json | $(sock)
	bun run $< post -o $@ -d build/$*.d -s $(sock) posts/$*.md build/$*.json

$(assets): $(DESTDIR)/%: | assets/%
	ln -sfn $(CURDIR)/$(firstword $|) $@

$(css): $(src_css)
	sed 's#$$FONT_URL#$(FONT_URL)#' $< > $@

.INTERMEDIATE: $(sock) $(fifo)

build/highlight: highlight/main.go
	cd $(dir $<) && go build -o ../$@

$(sock): build/highlight $(fifo)
	$< $@ $(fifo) &
	< $(fifo)

$(fifo):
	mkfifo $@

$(directories):
	mkdir -p $@

ifeq (,$(filter help clean,$(MAKECMDGOALS)))
include $(prebuild)
-include $(depfiles)
endif

.SECONDEXPANSION:

$(artifacts) $(auxiliary) $(directories): | $$(@D)
