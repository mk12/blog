# Copyright 2022 Mitchell Kember. Subject to the MIT License.

# This Makefile is only used by the mk12/mitchellkember.com repository.

env := $\
	HUGO_BASEURL=$(BASE_URL) $\
	HUGO_PARAMS_FONTPATH=$(FONT_PATH)

define module_config
[[mounts]]
source = "layouts"
target = "layouts"

[[mounts]]
source = "$(ANALYTICS)"
target = "layouts/_default/analytics.html"
endef

all: config/production/module.toml
	$(env) hugo --quiet -d $(DESTDIR)

config/production/module.toml: config/production
	$(file >$@,$(module_config))

config/production:
	mkdir $@
