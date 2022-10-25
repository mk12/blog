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
	FONT_URL   WOFF2 font directory URL
	HOME_URL   Homepage URL to link to when embedding in a larger site
	ANALYTICS  HTML file to include for analytics
endef

.PHONY: all help check serve clean

default_destdir := public
default_base_url := /

DESTDIR ?= $(default_destdir)
BASE_URL ?= $(default_base_url)
FONT_URL ?= $(error FONT_URL is required)

config := base.toml prod.toml serve.toml

define base_config
baseURL = "$(BASE_URL)"
[params]
$(if $(HOME_URL),homepage = "$(HOME_URL)",)
$(if $(ANALYTICS),$(base_config_analytics),)
endef

define base_config_analytics
[[module.mounts]]
source = "layouts"
target = "layouts"
[[module.mounts]]
source = "$(ANALYTICS)"
target = "layouts/_default/analytics.html"
endef

define prod_config
[params]
fontURL = "$(FONT_URL)"
endef

define serve_config
[params]
fontURL = "$(BASE_URL)fonts"
[[module.mounts]]
# Use realpath because Hugo does not allow mounting from symlinks.
source = "$(realpath fonts)"
target = "static/fonts"
includeFiles = "/*.woff2"
endef

.SUFFIXES:

all: config.toml base.toml prod.toml
	hugo --config $(shell echo $^ | tr ' ' ',')  --quiet -d $(DESTDIR)

help:
	$(info $(usage))
	@:

check: all

serve: config.toml base.toml serve.toml
	hugo --config $(shell echo $^ | tr ' ' ',') serve -w

clean:
	rm -rf $(default_destdir) resources

.INTERMEDIATE: $(config)
$(config):
	$(file >$@,$($(basename $@)_config))
