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

pandoc_flags := -M year=$$(date +%Y)
ifdef HOME_URL
pandoc_flags += -M site_home_url=$(HOME_URL)
endif
ifdef ANALYTICS
pandoc_flags += -M analytics_file=$(ANALYTICS)
endif

src_posts := $(wildcard posts/*.md)
src_assets := $(wildcard assets/img/*.jpg)
src_css := assets/css/style.css

posts := $(src_posts:posts/%.md=$(DESTDIR)/post/%/index.html)
assets := $(src_assets:assets/%=$(DESTDIR)/%)
css := $(DESTDIR)/style.css

directories := $(DESTDIR) $(DESTDIR)/post \
	$(sort $(dir $(posts)) $(dir $(assets)))
directories := $(directories:%/=%)

.SUFFIXES:

all: $(posts) $(assets) $(css)
	@echo TODO

help:
	$(info $(usage))
	@:

check: all validate

validate: all
	fd -g '*.html' $(DESTDIR) | xargs vnu

clean:
	rm -rf $(default_destdir)

# TODO: write depfile containing templates, SVGs, ...
$(posts): $(DESTDIR)/post/%/index.html: posts/%.md writer.lua
	pandoc -t $(word 2,$^) -M root=../../ $(pandoc_flags) -o $@ $<

$(assets): $(DESTDIR)/%: | assets/%
	ln -sfn $(CURDIR)/$(firstword $|) $@

$(css): $(src_css)
	sed 's#$$FONT_URL#$(FONT_URL)#' $< > $@

$(directories):
	mkdir -p $@

.SECONDEXPANSION:

$(posts) $(assets) $(css) $(directories): | $$(@D)
