# extract name from package.json
PACKAGE_NAME := $(shell awk '/"name":/ {gsub(/[",]/, "", $$2); print $$2}' package.json)
RPM_NAME := cockpit-$(PACKAGE_NAME)
VERSION := $(shell T=$$(git describe 2>/dev/null) || T=1; echo $$T | tr '-' '.')
ifeq ($(TEST_OS),)
TEST_OS = fedora-30
endif
export TEST_OS
VM_IMAGE=$(CURDIR)/test/images/$(TEST_OS)
# stamp file to check if/when npm install ran
NODE_MODULES_TEST=package-lock.json
# one example file in dist/ from webpack to check if that already ran
WEBPACK_TEST=dist/index.html

all: $(WEBPACK_TEST)

#
# i18n
#

LINGUAS=$(basename $(notdir $(wildcard po/*.po)))

po/POTFILES.js.in:
	mkdir -p $(dir $@)
	find src/ -name '*.js' -o -name '*.jsx' > $@

po/$(PACKAGE_NAME).js.pot: po/POTFILES.js.in
	xgettext --default-domain=cockpit --output=$@ --language=C --keyword= \
		--keyword=_:1,1t --keyword=_:1c,2,1t --keyword=C_:1c,2 \
		--keyword=N_ --keyword=NC_:1c,2 \
		--keyword=gettext:1,1t --keyword=gettext:1c,2,2t \
		--keyword=ngettext:1,2,3t --keyword=ngettext:1c,2,3,4t \
		--keyword=gettextCatalog.getString:1,3c --keyword=gettextCatalog.getPlural:2,3,4c \
		--from-code=UTF-8 --files-from=$^

po/POTFILES.html.in:
	mkdir -p $(dir $@)
	find src -name '*.html' > $@

po/$(PACKAGE_NAME).html.pot: po/POTFILES.html.in $(NODE_MODULES_TEST)
	po/html2po -f $^ -o $@

po/$(PACKAGE_NAME).manifest.pot: $(NODE_MODULES_TEST)
	po/manifest2po src/manifest.json -o $@

po/$(PACKAGE_NAME).pot: po/$(PACKAGE_NAME).html.pot po/$(PACKAGE_NAME).js.pot po/$(PACKAGE_NAME).manifest.pot
	msgcat --sort-output --output-file=$@ $^

# Update translations against current PO template
update-po: po/$(PACKAGE_NAME).pot
	for lang in $(LINGUAS); do \
		msgmerge --output-file=po/$$lang.po po/$$lang.po $<; \
	done

dist/po.%.js: po/%.po $(NODE_MODULES_TEST)
	mkdir -p $(dir $@)
	po/po2json -m po/po.empty.js -o $@.js.tmp $<
	mv $@.js.tmp $@

ZANATA_CLI = LANG=C.UTF-8 LC_ALL=C.UTF-8 zanata

upload-pot: po/$(PACKAGE_NAME).pot
	$(ZANATA_CLI) push -f --srcdir=./po --push-type=source --project-config=./po/zanata.xml $(PACKAGE_NAME).pot

clean-po:
	rm ./po/*.po

download-po:
	$(ZANATA_CLI) pull --min-doc-percent 50 --transdir=./po --project-config=./po/zanata.xml

#
# Build/Install/dist
#

%.spec: %.spec.in
	sed -e 's/@VERSION@/$(VERSION)/g' $< > $@

$(WEBPACK_TEST): $(NODE_MODULES_TEST) $(shell find src/ -type f) package.json webpack.config.js $(patsubst %,dist/po.%.js,$(LINGUAS))
	NODE_ENV=$(NODE_ENV) npm run build

watch:
	NODE_ENV=$(NODE_ENV) npm run watch

clean:
	rm -rf dist/
	[ ! -e $(RPM_NAME).spec.in ] || rm -f $(RPM_NAME).spec

install: $(WEBPACK_TEST)
	mkdir -p $(DESTDIR)/usr/share/cockpit/$(PACKAGE_NAME)
	cp -r dist/* $(DESTDIR)/usr/share/cockpit/$(PACKAGE_NAME)
	mkdir -p $(DESTDIR)/usr/share/metainfo/
	cp org.cockpit-project.$(PACKAGE_NAME).metainfo.xml $(DESTDIR)/usr/share/metainfo/

# this requires a built source tree and avoids having to install anything system-wide
devel-install: $(WEBPACK_TEST)
	mkdir -p ~/.local/share/cockpit
	ln -s `pwd`/dist ~/.local/share/cockpit/$(PACKAGE_NAME)

# when building a distribution tarball, call webpack with a 'production' environment
# # we don't ship node_modules for license and compactness reasons; we ship a
# pre-built dist/ (so it's not necessary) and ship packge-lock.json (so that
# node_modules/ can be reconstructed if necessary)
dist-gzip: NODE_ENV=production
dist-gzip: all $(RPM_NAME).spec
	mv node_modules node_modules.release
	touch -r package.json $(NODE_MODULES_TEST)
	touch dist/*
	tar czf cockpit-$(PACKAGE_NAME)-$(VERSION).tar.gz --transform 's,^,cockpit-$(PACKAGE_NAME)/,' \
		--exclude $(RPM_NAME).spec.in \
		$$(git ls-files) package-lock.json $(RPM_NAME).spec dist/
	mv node_modules.release node_modules

srpm: dist-gzip $(RPM_NAME).spec
	rpmbuild -bs \
	  --define "_sourcedir `pwd`" \
	  --define "_srcrpmdir `pwd`" \
	  $(RPM_NAME).spec

rpm: dist-gzip $(RPM_NAME).spec
	mkdir -p "`pwd`/output"
	mkdir -p "`pwd`/rpmbuild"
	rpmbuild -bb \
	  --define "_sourcedir `pwd`" \
	  --define "_specdir `pwd`" \
	  --define "_builddir `pwd`/rpmbuild" \
	  --define "_srcrpmdir `pwd`" \
	  --define "_rpmdir `pwd`/output" \
	  --define "_buildrootdir `pwd`/build" \
	  $(RPM_NAME).spec
	find `pwd`/output -name '*.rpm' -printf '%f\n' -exec mv {} . \;
	rm -r "`pwd`/rpmbuild"
	rm -r "`pwd`/output" "`pwd`/build"

# build a VM with locally built rpm installed
$(VM_IMAGE): rpm bots
	rm -f $(VM_IMAGE) $(VM_IMAGE).qcow2
	# HACK: https://bugzilla.redhat.com/show_bug.cgi?id=1762663
	if [ $(TEST_OS) = "fedora-31" ]; then bots/image-customize -v -r 'grub2-editenv - set "$$(grub2-editenv list | grep ^kernelopts) debug"' $(TEST_OS); fi
	bots/image-customize -v -i cockpit-ws -i `pwd`/$(RPM_NAME)-*.noarch.rpm -s $(CURDIR)/test/vm.install $(TEST_OS)
	if [ $(TEST_OS) = "fedora-31" ]; then bots/image-customize -v -r 'grub2-editenv - set "$$(grub2-editenv list | grep ^kernelopts | sed "s/debug//")"' $(TEST_OS); fi

# convenience target for the above
vm: $(VM_IMAGE)
	echo $(VM_IMAGE)

# run the browser integration tests; skip check for SELinux denials
check: $(NODE_MODULES_TEST) $(VM_IMAGE) test/common
	TEST_AUDIT_NO_SELINUX=1 test/check-application

# checkout Cockpit's bots for standard test VM images and API to launch them
# must be from master, as only that has current and existing images; but testvm.py API is stable
# support CI testing against a bots change
bots:
	git clone --quiet --reference-if-able $${XDG_CACHE_HOME:-$$HOME/.cache}/cockpit-project/bots https://github.com/cockpit-project/bots.git
	if [ -n "$$COCKPIT_BOTS_REF" ]; then git -C bots fetch --quiet --depth=1 origin "$$COCKPIT_BOTS_REF"; git -C bots checkout --quiet FETCH_HEAD; fi
	@echo "checked out bots/ ref $$(git -C bots rev-parse HEAD)"

# checkout Cockpit's test API; this has no API stability guarantee, so check out a stable tag
# when you start a new project, use the latest relese, and update it from time to time
test/common:
	git fetch --depth=1 https://github.com/cockpit-project/cockpit.git 205
	git checkout --force FETCH_HEAD -- test/common
	git reset test/common

$(NODE_MODULES_TEST): package.json
	# if it exists already, npm install won't update it; force that so that we always get up-to-date packages
	rm -f package-lock.json
	# unset NODE_ENV, skips devDependencies otherwise
	env -u NODE_ENV npm install
	env -u NODE_ENV npm prune

.PHONY: all clean install devel-install dist-gzip srpm rpm check vm update-po
