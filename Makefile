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
# pages := $(patsubst %,$(DESTDIR)/%.html,index post/index categories/index)
posts := $(src_posts:posts/%.md=$(DESTDIR)/post/%/index.html)
extra_depfiles := build/index.d build/post/index.d build/categories/index.d
depfiles := $(src_posts:posts/%.md=build/post/%.d) $(extra_depfiles)
assets := $(src_assets:assets/%=$(DESTDIR)/%)
css := $(DESTDIR)/style.css
pages := $(index) $(archive) $(categories)
html := $(posts) $(pages)

reload := build/reload.mk
order := build/order.json
neighbours := $(src_posts:posts/%.md=build/post/%.json)
auxiliary := $(reload) $(order) $(neighbours)

directories := $(sort $(dir $(html) $(assets) $(depfiles)))
directories := $(directories:%/=%)

.SUFFIXES:

all: $(html)

help:
	$(info $(usage))
	@:

check: all validate

validate: $(html)
	vnu $(html)

clean:
	rm -rf $(default_destdir) build

$(reload): gen.ts posts $(src_posts) | build/post
	bun run $< -k order -o $(order) $(src_posts)
	touch $@

$(html): $(DESTDIR)/%.html: gen.ts | $(css) $(dir build/%.d)
	bun run $< -o $@ -d build/$*.d $(gen_args)

$(index) $(posts): | highlight.sock
$(index) $(posts): gen_args += -s highlight.sock

$(pages): $(order)
$(pages): gen_args += -r $(order)

$(index): gen_args += -k index
$(archive): gen_args += -k archive
$(categories): gen_args += -k categories
$(categories): | build/categories

$(posts): $(DESTDIR)/post/%/index.html: posts/%.md build/post/%.json
$(posts): gen_args += -k post -i $(@:$(DESTDIR)/post/%/index.html=posts/%.md) -j $(@:$(DESTDIR)/post/%/index.html=build/post/%.json)

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
include $(reload)
-include $(depfiles)
endif

.SECONDEXPANSION:

$(html) $(assets) $(css) $(auxiliary) $(directories): | $$(@D)
