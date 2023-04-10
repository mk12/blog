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

posts_wildcard := posts/*.md
src_posts := $(wildcard $(posts_wildcard))
src_assets := $(wildcard assets/img/*.jpg)
src_css := assets/css/style.css

page_names := index archive categories
post_names := $(src_posts:posts/%.md=%)
html_names := $(page_names) $(post_names)

index := $(DESTDIR)/index.html
archive := $(DESTDIR)/post/index.html
categories := $(DESTDIR)/categories/index.html
pages := $(foreach n,$(page_names),$($(n)))
posts := $(post_names:%=$(DESTDIR)/post/%/index.html)
html := $(pages) $(posts)
assets := $(src_assets:assets/%=$(DESTDIR)/%)
css := $(DESTDIR)/style.css
all := $(html) $(assets) $(css)

prebuild := build/prebuild.mk
manifest := build/manifest.json
depfiles = $(html_names:%=build/%.d)
aux := $(prebuild) $(manifest) $(depfiles)

sock := highlight.sock
fifo := highlight.fifo

.SUFFIXES:

all: $(all)

help:
	$(info $(usage))
	@:

check: all validate

validate: $(html)
	vnu $(html)

clean:
	rm -rf $(default_destdir) build

$(prebuild): gen.ts posts $(src_posts)
	bun run $< manifest -o $(manifest) $(posts_wildcard)
	touch $@

$(foreach n,$(page_names),$(eval $($(n)): name := $(n)))
$(posts): name = $*
depflags = -d build/$(name).d -t $(@:$(DESTDIR)/%='$$(DESTDIR)/%')

$(pages): gen.ts $(manifest)
	bun run $< page $(name) $(manifest) -o $@ $(depflags)

$(posts): $(DESTDIR)/post/%/index.html: gen.ts posts/%.md build/%.json | $(sock)
	bun run $< post posts/$*.md build/$*.json -o $@ -s $(sock) $(depflags)

$(assets): $(DESTDIR)/%: | assets/%
	ln -sfn $(CURDIR)/assets/$* $@

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

$(sort $(dir $(all) $(aux))):
	mkdir -p $@

ifeq (,$(filter help clean,$(MAKECMDGOALS)))
-include $(prebuild)
-include $(depfiles)
endif

.SECONDEXPANSION:

$(all) $(aux): | $$(@D)/
