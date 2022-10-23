# Copyright 2022 Mitchell Kember. Subject to the MIT License.

define usage
Targets:
	all    Build the blog
	help   Show this help message
	check  Run before committing
	serve  Serve the blog locally
	clean  Remove build output

Variables:
	DESTDIR    Destination directory
	BASE_URL   Base URL of blog in website
	FONT_PATH  Path to WOFF2 fonts relative to DESTDIR
	ANALYTICS  HTML file to include for analytics
endef

.PHONY: all help check serve clean hugo

BASE_URL ?= /
DESTDIR ?= public
FONT_PATH ?= ../fonts

fonts_basename := $(shell rg '/([^/]+\.woff2)' -r '$$1' -o assets/css/style.css)
fonts := $(abspath $(fonts_basename:%=$(DESTDIR)/$(FONT_PATH)/%))

define config
baseURL = "$(BASE_URL)"
[params]
fontPath = "$(FONT_PATH)"
$(if $(ANALYTICS),$(analytics_config),)
endef

define analytics_config
[[module.mounts]]
source = "layouts"
target = "layouts"
[[module.mounts]]
source = "$(ANALYTICS)"
target = "layouts/_default/analytics.html"
endef

define serve_config
[parmas]
fontPath = "fonts"
[[module.mounts]]
source = "$(realpath $(DESTDIR)/$(FONT_PATH))"
target = "static/fonts"
includeFiles = "/*.woff2"
endef

.SUFFIXES:

all: hugo_args := --quiet -d $(DESTDIR)
all: hugo

help:
	$(info $(usage))
	@:

check: all

serve: config += $(serve_config)
serve: hugo_args := serve -w
serve: hugo

clean:
	rm -rf public resources

$(fonts):
	$(if $(wildcard $@),,$(error Missing font file $@))

hugo: extra.toml $(fonts)
	hugo --config config.toml,$< $(hugo_args)

.INTERMEDIATE: extra.toml
extra.toml:
	$(file >$@,$(config))
