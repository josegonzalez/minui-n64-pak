PAK_NAME := $(shell jq -r .name pak.json)
PAK_TYPE := $(shell jq -r .type pak.json)
PAK_FOLDER := $(shell echo $(PAK_TYPE) | cut -c1)$(shell echo $(PAK_TYPE) | tr '[:upper:]' '[:lower:]' | cut -c2-)s

PUSH_SDCARD_PATH ?= /mnt/SDCARD
PUSH_PLATFORM ?= tg5040

ARCHITECTURES := arm64
PLATFORMS := tg5040

COREUTILS_VERSION := 0.0.28
EMIT_KEY_VERSION := 0.2.1
EVTEST_VERSION := 0.1.0
JQ_VERSION := 1.7
MINUI_LIST_VERSION := 0.11.4
MINUI_PRESENTER_VERSION := 0.7.0

clean:
	rm -f bin/*/7zzs || true 
	rm -f bin/*/evtest || true
	rm -f bin/*/jq || true
	rm -f bin/*/minui-list || true
	rm -f bin/*/minui-presenter || true
	rm -f bin/*/coreutils || true
	rm -f bin/*/coreutils.LICENSE || true
	rm -f bin/*/emit-key || true

build: $(foreach platform,$(PLATFORMS),bin/$(platform)/minui-list bin/$(platform)/minui-presenter bin/$(platform)/emit-key) $(foreach arch,$(ARCHITECTURES),bin/$(arch)/7zzs bin/$(arch)/evtest bin/$(arch)/coreutils bin/$(arch)/jq) bin/arm64/gptokeyb2.LICENSE

bin/arm64/7zzs:
	mkdir -p bin/arm64
	curl -sSL -o bin/arm64/7z.tar.xz "https://www.7-zip.org/a/7z2409-linux-arm64.tar.xz"
	mkdir -p bin/arm64/7z
	tar -xJf bin/arm64/7z.tar.xz -C bin/arm64/7z
	mv bin/arm64/7z/7zzs bin/arm64/7zzs
	mv bin/arm64/7z/License.txt bin/arm64/7zzs.LICENSE
	rm -rf bin/7z bin/7z.tar.xz

bin/arm64/coreutils:
	mkdir -p bin/arm64
	curl -sSL -o bin/arm64/coreutils.tar.gz "https://github.com/uutils/coreutils/releases/download/$(COREUTILS_VERSION)/coreutils-$(COREUTILS_VERSION)-aarch64-unknown-linux-gnu.tar.gz"
	tar -xzf bin/arm64/coreutils.tar.gz -C bin/arm64 --strip-components=1
	rm bin/arm64/coreutils.tar.gz
	chmod +x bin/arm64/coreutils
	mv bin/arm64/LICENSE bin/arm64/coreutils.LICENSE
	rm bin/arm64/README.md bin/arm64/README.package.md || true

bin/%/evtest:
	mkdir -p bin/$*
	curl -sSL -o bin/$*/evtest https://github.com/josegonzalez/compiled-evtest/releases/download/$(EVTEST_VERSION)/evtest-$*
	curl -sSL -o bin/$*/evtest.LICENSE "https://raw.githubusercontent.com/freedesktop-unofficial-mirror/evtest/refs/heads/master/COPYING"
	chmod +x bin/$*/evtest

bin/arm64/gptokeyb2.LICENSE:
	mkdir -p bin/arm64
	curl -sSL -o bin/arm64/gptokeyb2.LICENSE "https://raw.githubusercontent.com/PortsMaster/gptokeyb2/refs/heads/master/LICENSE.txt"

bin/arm64/jq:
	mkdir -p bin/arm64
	curl -f -o bin/arm64/jq -sSL https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-arm64
	curl -sSL -o bin/arm64/jq.LICENSE "https://raw.githubusercontent.com/jqlang/jq/refs/heads/$(JQ_VERSION)/COPYING"

bin/%/emit-key:
	mkdir -p bin/$*
	curl -f -o bin/$*/emit-key -sSL https://github.com/josegonzalez/emit-key/releases/download/$(EMIT_KEY_VERSION)/emit-key-$*
	chmod +x bin/$*/emit-key

bin/%/minui-list:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-list -sSL https://github.com/josegonzalez/minui-list/releases/download/$(MINUI_LIST_VERSION)/minui-list-$*
	chmod +x bin/$*/minui-list

bin/%/minui-presenter:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-presenter -sSL https://github.com/josegonzalez/minui-presenter/releases/download/$(MINUI_PRESENTER_VERSION)/minui-presenter-$*
	chmod +x bin/$*/minui-presenter

release: build
	mkdir -p dist
	git archive --format=zip --output "dist/$(PAK_NAME).pak.zip" HEAD
	while IFS= read -r file; do zip -r "dist/$(PAK_NAME).pak.zip" "$$file"; done < .gitarchiveinclude
	jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp
	mv pak.json.tmp pak.json
	zip -r "dist/$(PAK_NAME).pak.zip" pak.json
	ls -lah dist

push: release
	rm -rf "dist/$(PAK_NAME).pak"
	cd dist && unzip "$(PAK_NAME).pak.zip" -d "$(PAK_NAME).pak"
	adb push "dist/$(PAK_NAME).pak/." "$(PUSH_SDCARD_PATH)/$(PAK_FOLDER)/$(PUSH_PLATFORM)/$(PAK_NAME).pak"
