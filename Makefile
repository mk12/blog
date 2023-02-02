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
default_font_url := ../../fonts

DESTDIR ?= $(default_destdir)
FONT_URL ?= $(default_font_url)

src_posts := $(wildcard content/post/*.md)
src_assets := $(wildcard assets/img/*.jpg)
src_css := assets/css/style.css

posts := $(src_posts:content/%.md=$(DESTDIR)/%/index.html)
assets := $(src_assets:assets/%=$(DESTDIR)/%)
css := $(DESTDIR)/style.css

directories := $(DESTDIR) $(sort $(dir $(assets)))
directories := $(directories:%/=%)

.SUFFIXES:

all:
	@echo TODO

help:
	$(info $(usage))
	@:

check: all validate

validate: all
	fd -g '*.html' $(DESTDIR) | xargs vnu

clean:
	rm -rf $(default_destdir)

$(assets): $(DESTDIR)/%: | assets/%
	ln -sfn $(CURDIR)/$(firstword $|) $@

$(css): $(src_css)
	sed 's#$$FONT_URL#$(FONT_URL)#' $< > $@

$(directories):
	mkdir -p $@

.SECONDEXPANSION:

$(assets) $(css) $(directories): | $$(@D)
