# Copyright 2022 Mitchell Kember. Subject to the MIT License.

define usage
Targets:
	all    Build the blog
	help   Show this help message
	check  Run before committing
	serve  Serve the blog locally
	clean  Remove build output

Variables:
	DESTDIR    Destination directory (default: $(default_destdir))
	BASE_URL   Base URL of blog in website (default: $(default_base_url))
	FONT_PATH  Path to WOFF2 fonts (default: $(default_font_path))
	ANALYTICS  HTML file to include for analytics
endef

.PHONY: all help check serve clean hugo

default_destdir := public
default_base_url := /
default_font_path := fonts

DESTDIR ?= $(default_destdir)
BASE_URL ?= $(default_base_url)
FONT_PATH ?= $(default_font_path)

fonts_basename := $(shell rg '/([^/]+\.woff2)' -r '$$1' -o assets/css/style.css)
fonts := $(fonts_basename:%=$(FONT_PATH)/%)

define config
baseURL = "$(BASE_URL)"
[params]
fontPath = "$(shell python3 -c '$\
	import os.path; $\
	print(os.path.relpath("$(FONT_PATH)", "$(DESTDIR)")) $\
')"
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
# Use realpath because Hugo does not allow mounting from symlinks.
source = "$(realpath $(FONT_PATH))"
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
	rm -rf $(default_destdir) resources

$(fonts):
	$(if $(wildcard $@),,$(error Missing font file $@))

hugo: extra.toml $(fonts)
	hugo --config config.toml,$< $(hugo_args)

.INTERMEDIATE: extra.toml
extra.toml:
	$(file >$@,$(config))
