TAG ?= latest
PAK_NAME := $(shell jq -r .label config.json)

PLATFORMS := tg5040
MINUI_LIST_VERSION := 0.4.0
COREUTILS_VERSION := 0.0.28

clean:
	rm -f bin/7zzs* || true 
	rm -f bin/evtest || true
	rm -f bin/sdl2imgshow || true
	rm -f bin/coreutils || true
	rm -f bin/coreutils.LICENSE || true
	rm -f bin/minui-list-* || true
	rm -f res/fonts/BPreplayBold.otf || true

build: $(foreach platform,$(PLATFORMS),bin/minui-list-$(platform)) bin/7zzs bin/evtest bin/sdl2imgshow bin/coreutils bin/gptokeyb2.LICENSE res/fonts/BPreplayBold.otf

bin/7zzs:
	curl -sSL -o bin/7z.tar.xz "https://www.7-zip.org/a/7z2409-linux-arm64.tar.xz"
	mkdir -p bin/7z
	tar -xJf bin/7z.tar.xz -C bin/7z
	mv bin/7z/7zzs bin/7zzs
	mv bin/7z/License.txt bin/7zzs.LICENSE
	rm -rf bin/7z bin/7z.tar.xz

bin/coreutils:
	curl -sSL -o bin/coreutils.tar.gz "https://github.com/uutils/coreutils/releases/download/$(COREUTILS_VERSION)/coreutils-$(COREUTILS_VERSION)-aarch64-unknown-linux-gnu.tar.gz"
	tar -xzf bin/coreutils.tar.gz -C bin --strip-components=1
	rm bin/coreutils.tar.gz
	chmod +x bin/coreutils
	mv bin/LICENSE bin/coreutils.LICENSE
	rm bin/README.md bin/README.package.md || true

bin/evtest:
	docker buildx build --platform linux/arm64 --load -f Dockerfile.evtest --progress plain -t app/evtest:$(TAG) .
	docker container create --name extract app/evtest:$(TAG)
	docker container cp extract:/go/src/github.com/freedesktop/evtest/evtest bin/evtest
	docker container rm extract
	chmod +x bin/evtest

bin/gptokeyb2.LICENSE:
	curl -sSL -o bin/gptokeyb2.LICENSE "https://raw.githubusercontent.com/PortsMaster/gptokeyb2/refs/heads/master/LICENSE.txt"

bin/minui-list-%:
	curl -f -o bin/minui-list-$* -sSL https://github.com/josegonzalez/minui-list/releases/download/$(MINUI_LIST_VERSION)/minui-list-$*
	chmod +x bin/minui-list-$*

bin/sdl2imgshow:
	docker buildx build --platform linux/arm64 --load -f Dockerfile.sdl2imgshow --progress plain -t app/sdl2imgshow:$(TAG) .
	docker container create --name extract app/sdl2imgshow:$(TAG)
	docker container cp extract:/go/src/github.com/kloptops/sdl2imgshow/build/sdl2imgshow bin/sdl2imgshow
	docker container rm extract
	chmod +x bin/sdl2imgshow

res/fonts/BPreplayBold.otf:
	mkdir -p res/fonts
	curl -sSL -o res/fonts/BPreplayBold.otf "https://raw.githubusercontent.com/shauninman/MinUI/refs/heads/main/skeleton/SYSTEM/res/BPreplayBold-unhinted.otf"

release: build
	mkdir -p dist
	git archive --format=zip --output "dist/$(PAK_NAME).pak.zip" HEAD
	while IFS= read -r file; do zip -r "dist/$(PAK_NAME).pak.zip" "$$file"; done < .gitarchiveinclude
	ls -lah dist
