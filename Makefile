PAK_NAME := $(shell jq -r .name pak.json)
PAK_TYPE := $(shell jq -r .type pak.json)
PAK_FOLDER := $(shell echo $(PAK_TYPE) | cut -c1)$(shell echo $(PAK_TYPE) | tr '[:upper:]' '[:lower:]' | cut -c2-)s

PUSH_SDCARD_PATH ?= /mnt/SDCARD
PUSH_PLATFORM ?= tg5040

SHELL := /bin/bash

# ── Upstream repos and pinned versions ────────────────────────────────────────
CORE_REPO    := https://github.com/mupen64plus/mupen64plus-core
CORE_TAG     := 2.6.0

UI_REPO      := https://github.com/mupen64plus/mupen64plus-ui-console
UI_TAG       := 2.6.0

AUDIO_REPO   := https://github.com/mupen64plus/mupen64plus-audio-sdl
AUDIO_TAG    := 2.6.0

INPUT_REPO   := https://github.com/mupen64plus/mupen64plus-input-sdl
INPUT_TAG    := 2.6.0

RSP_REPO     := https://github.com/mupen64plus/mupen64plus-rsp-hle
RSP_TAG      := 2.6.0

GLIDEN64_REPO := https://github.com/gonetz/GLideN64
GLIDEN64_REV  := c8ef81c7d9aede9f67f6ed3d3426c90541f9f13e

RICE_REPO    := https://github.com/mupen64plus/mupen64plus-video-rice
RICE_TAG     := 2.6.0

NX_REDUX_REPO := https://github.com/mohammadsyuhada/nx-redux
NX_REDUX_TAG  := v1.1.1

ZLIB_REPO     := https://github.com/madler/zlib
ZLIB_TAG      := v1.3.2

# 7-Zip standalone binary for ZIP/7Z ROM extraction. Pre-built AArch64 blob
# published by the upstream 7-Zip project on GitHub. Sha256-verified.
SEVENZ_VERSION := 26.00
SEVENZ_TAG     := 2600
SEVENZ_URL     := https://github.com/ip7z/7zip/releases/download/$(SEVENZ_VERSION)/7z$(SEVENZ_TAG)-linux-arm64.tar.xz
SEVENZ_SHA256  := aa8f3d0a19af9674d3af0ec788b4e261501071e626cd75ad149f1c2c176cc87d

# ── Docker toolchain images ───────────────────────────────────────────────────
TG5040_IMAGE := ghcr.io/loveretro/tg5040-toolchain:latest
TG5050_IMAGE := ghcr.io/loveretro/tg5050-toolchain:latest

# ── Paths ─────────────────────────────────────────────────────────────────────
ROOT     := $(shell pwd)
SRC      := $(ROOT)/src
DIST     := $(ROOT)/dist/N64.pak
PATCHES  := $(ROOT)/patches/shared
CONFIG   := $(ROOT)/config

# ── Cross-compile variables ───────────────────────────────────────────────────
CROSS    := aarch64-nextui-linux-gnu-
HOST_CPU := aarch64

# Common make flags for core (no SDL needed)
CORE_FLAGS := CROSS_COMPILE=$(CROSS) HOST_CPU=$(HOST_CPU) \
	USE_GLES=1 NEON=1 PIE=1 VULKAN=0 \
	PKG_CONFIG=pkg-config OPTFLAGS="-O3 -mcpu=cortex-a53"

# Docker run helper script — sets up env, then runs the given command.
# Written to src/.docker-env.sh during clone phase.
DOCKER_SCRIPT := /build/src/.docker-env.sh

# ══════════════════════════════════════════════════════════════════════════════
# Top-level targets
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: all build tg5040 tg5050 gliden64 rice dist clone patch patches clean

build: clone patch
	$(MAKE) tg5040
	$(MAKE) tg5050
	$(MAKE) gliden64
	$(MAKE) rice-tg5040
	$(MAKE) rice-tg5050

# Build both platforms sequentially, staging outputs between builds since they
# share source directories.
all:
	$(MAKE) dist-tg5040
	$(MAKE) dist-tg5050
	@echo "=== Build complete. dist/N64.pak/ assembled ==="
	@find $(DIST) -type f | sort

# ── Clone ─────────────────────────────────────────────────────────────────────

clone: $(SRC)/mupen64plus-core $(SRC)/mupen64plus-ui-console \
       $(SRC)/mupen64plus-audio-sdl $(SRC)/mupen64plus-input-sdl \
       $(SRC)/mupen64plus-rsp-hle $(SRC)/GLideN64 \
       $(SRC)/mupen64plus-video-rice $(SRC)/nx-redux \
       $(SRC)/zlib $(SRC)/7zip/7zzs
	@# Write Docker env helper script (sets up cross-compile env, then exec's args)
	@printf '#!/bin/bash\nsource ~/.bashrc\nexport PKG_CONFIG_PATH=/opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/pkgconfig\nexport PKG_CONFIG_SYSROOT_DIR=/opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc\nexport SDL_CFLAGS="$$(pkg-config --cflags sdl2)"\nexport SDL_LDLIBS="$$(pkg-config --libs sdl2)"\nexec "$$@"\n' > $(SRC)/.docker-env.sh
	@chmod +x $(SRC)/.docker-env.sh
	@# Populate GLES headers and unmodified patches from nx-redux
	@# (overlay/ sources are vendored in the repo — not pulled from nx-redux)
	@mkdir -p $(ROOT)/include
	@cp -r $(SRC)/nx-redux/workspace/all/include/EGL $(ROOT)/include/
	@cp -r $(SRC)/nx-redux/workspace/all/include/GLES2 $(ROOT)/include/
	@cp -r $(SRC)/nx-redux/workspace/all/include/GLES3 $(ROOT)/include/
	@cp -r $(SRC)/nx-redux/workspace/all/include/KHR $(ROOT)/include/
	@# mupen64plus-ui-console.patch is committed (customized with romfilename support)
	@cp $(SRC)/nx-redux/workspace/tg5040/other/mupen64plus/mupen64plus-audio-sdl.patch $(PATCHES)/

$(SRC)/mupen64plus-core:
	git clone --depth 1 --branch $(CORE_TAG) $(CORE_REPO) $@

$(SRC)/mupen64plus-ui-console:
	git clone --depth 1 --branch $(UI_TAG) $(UI_REPO) $@

$(SRC)/mupen64plus-audio-sdl:
	git clone --depth 1 --branch $(AUDIO_TAG) $(AUDIO_REPO) $@

$(SRC)/mupen64plus-input-sdl:
	git clone --depth 1 --branch $(INPUT_TAG) $(INPUT_REPO) $@

$(SRC)/mupen64plus-rsp-hle:
	git clone --depth 1 --branch $(RSP_TAG) $(RSP_REPO) $@

$(SRC)/GLideN64:
	git clone $(GLIDEN64_REPO) $@
	cd $@ && git checkout $(GLIDEN64_REV)

$(SRC)/mupen64plus-video-rice:
	git clone --depth 1 --branch $(RICE_TAG) $(RICE_REPO) $@

$(SRC)/nx-redux:
	git clone --depth 1 --branch $(NX_REDUX_TAG) $(NX_REDUX_REPO) $@

$(SRC)/zlib:
	git clone --depth 1 --branch $(ZLIB_TAG) $(ZLIB_REPO) $@

# 7-Zip standalone static binary for ZIP/7Z ROM extraction at launch time.
# Downloaded pre-built from upstream and sha256-verified. Only 7zzs and the
# License.txt are needed; everything else in the tarball is discarded.
$(SRC)/7zip/7zzs:
	@mkdir -p $(SRC)/7zip
	@echo "Fetching 7-Zip $(SEVENZ_VERSION) (arm64) from upstream…"
	@curl -fsSL -o $(SRC)/7zip/7z-linux-arm64.tar.xz $(SEVENZ_URL)
	@echo "$(SEVENZ_SHA256)  $(SRC)/7zip/7z-linux-arm64.tar.xz" | shasum -a 256 -c -
	@tar -xJf $(SRC)/7zip/7z-linux-arm64.tar.xz -C $(SRC)/7zip 7zzs License.txt
	@chmod +x $(SRC)/7zip/7zzs
	@rm -f $(SRC)/7zip/7z-linux-arm64.tar.xz

# ── Patch ─────────────────────────────────────────────────────────────────────

PATCH_STAMP := $(SRC)/.patched

patch: $(PATCH_STAMP)

$(PATCH_STAMP): | clone
	@if [ ! -f $(PATCH_STAMP) ]; then \
		echo "Applying patches..."; \
		cd $(SRC)/mupen64plus-ui-console && git apply $(PATCHES)/mupen64plus-ui-console.patch; \
		if [ -s $(PATCHES)/mupen64plus-audio-sdl.patch ]; then \
			cd $(SRC)/mupen64plus-audio-sdl && git apply $(PATCHES)/mupen64plus-audio-sdl.patch; \
		fi; \
		cd $(SRC)/mupen64plus-core && git apply $(PATCHES)/mupen64plus-core.patch; \
		cd $(SRC)/GLideN64 && git apply --exclude='src/GLideNHQ/lib/*.a' $(PATCHES)/GLideN64-standalone.patch; \
		cd $(SRC)/mupen64plus-input-sdl && git apply $(PATCHES)/mupen64plus-input-sdl.patch; \
		cd $(SRC)/mupen64plus-video-rice && git apply $(PATCHES)/mupen64plus-video-rice.patch; \
		touch $(PATCH_STAMP); \
	fi

# ── Docker helpers ────────────────────────────────────────────────────────────
# DOCKER_RUN_5040 / DOCKER_RUN_5050: run a command inside the toolchain container
# The .docker-env.sh script sets up the cross-compile environment then exec's the arg.

DOCKER_RUN_5040 := docker run --rm -v $(ROOT):/build $(TG5040_IMAGE) $(DOCKER_SCRIPT)
DOCKER_RUN_5050 := docker run --rm -v $(ROOT):/build $(TG5050_IMAGE) $(DOCKER_SCRIPT)

# Common plugin make flags (SDL_CFLAGS/SDL_LDLIBS exported by docker-env.sh)
PLUGIN_MAKE := CROSS_COMPILE=$(CROSS) HOST_CPU=$(HOST_CPU) PIE=1 \
	PKG_CONFIG=pkg-config \
	APIDIR=/build/src/mupen64plus-core/src/api \
	OPTFLAGS="-O3 -mcpu=cortex-a53"

# ── TG5040 build ──────────────────────────────────────────────────────────────

.PHONY: tg5040 tg5040-core tg5040-ui tg5040-audio tg5040-input tg5040-rsp

tg5040: tg5040-core tg5040-ui tg5040-audio tg5040-input tg5040-rsp

tg5040-core: $(PATCH_STAMP)
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/mupen64plus-core/projects/unix && make -j$$(nproc) all $(CORE_FLAGS)'

tg5040-ui: $(PATCH_STAMP)
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/mupen64plus-ui-console/projects/unix && make -j$$(nproc) all $(PLUGIN_MAKE) COREDIR="./" PLUGINDIR="./"'

tg5040-audio: $(PATCH_STAMP)
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/mupen64plus-audio-sdl/projects/unix && make -j$$(nproc) all $(PLUGIN_MAKE)'

tg5040-input: $(PATCH_STAMP)
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/mupen64plus-input-sdl/projects/unix && make -j$$(nproc) all $(PLUGIN_MAKE)'

tg5040-rsp: $(PATCH_STAMP)
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/mupen64plus-rsp-hle/projects/unix && make -j$$(nproc) all $(PLUGIN_MAKE)'

# ── TG5050 build ──────────────────────────────────────────────────────────────

.PHONY: tg5050 tg5050-core tg5050-ui tg5050-audio tg5050-input tg5050-rsp tg5050-libpng-headers

# libpng headers workaround for broken TG5050 toolchain symlinks
LIBPNG_DIR := $(SRC)/libpng-headers/libpng-1.6.37

tg5050-libpng-headers: $(LIBPNG_DIR)/pnglibconf.h

$(LIBPNG_DIR)/pnglibconf.h:
	mkdir -p $(SRC)/libpng-headers
	cd $(SRC)/libpng-headers && \
		curl -sL https://github.com/glennrp/libpng/archive/refs/tags/v1.6.37.tar.gz -o libpng.tar.gz && \
		tar xf libpng.tar.gz && \
		cp libpng-1.6.37/scripts/pnglibconf.h.prebuilt libpng-1.6.37/pnglibconf.h

tg5050: tg5050-core tg5050-ui tg5050-audio tg5050-input tg5050-rsp

tg5050-core: $(PATCH_STAMP) tg5050-libpng-headers
	$(DOCKER_RUN_5050) bash -c 'cd /build/src/mupen64plus-core/projects/unix && rm -rf _obj libmupen64plus.so* ../../src/asm_defines/asm_defines_gas.h ../../src/asm_defines/asm_defines_nasm.h && make -j$$(nproc) all $(CORE_FLAGS) LIBPNG_CFLAGS="-I/build/src/libpng-headers/libpng-1.6.37" LIBPNG_LDLIBS="-lpng16 -lz"'

tg5050-ui: $(PATCH_STAMP)
	$(DOCKER_RUN_5050) bash -c 'cd /build/src/mupen64plus-ui-console/projects/unix && rm -rf _obj mupen64plus && make -j$$(nproc) all $(PLUGIN_MAKE) COREDIR="./" PLUGINDIR="./"'

tg5050-audio: $(PATCH_STAMP)
	$(DOCKER_RUN_5050) bash -c 'cd /build/src/mupen64plus-audio-sdl/projects/unix && rm -rf _obj mupen64plus-audio-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE)'

tg5050-input: $(PATCH_STAMP)
	$(DOCKER_RUN_5050) bash -c 'cd /build/src/mupen64plus-input-sdl/projects/unix && rm -rf _obj mupen64plus-input-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE)'

tg5050-rsp: $(PATCH_STAMP)
	$(DOCKER_RUN_5050) bash -c 'cd /build/src/mupen64plus-rsp-hle/projects/unix && rm -rf _obj mupen64plus-rsp-hle.so && make -j$$(nproc) all $(PLUGIN_MAKE)'

# ── GLideN64 (shared — built with tg5040 toolchain) ──────────────────────────

.PHONY: gliden64

gliden64: $(PATCH_STAMP)
	@# Cross-compile zlib from source (tg5040 toolchain has 1.2.8, too old for GLideN64)
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/zlib && [ -f libz.a ] || (CC=aarch64-nextui-linux-gnu-gcc AR=aarch64-nextui-linux-gnu-ar RANLIB=aarch64-nextui-linux-gnu-ranlib ./configure --static && make -j$$(nproc))'
	@# Replace bundled static libs with ARM64 versions:
	@#   libpng16.a from tg5050 sysroot (tg5040 only has libpng12)
	@#   libz.a from zlib source build above
	$(DOCKER_RUN_5050) cp /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng16.a /build/src/GLideN64/src/GLideNHQ/lib/libpng.a
	cp $(SRC)/zlib/libz.a $(SRC)/GLideN64/src/GLideNHQ/lib/libz.a
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/GLideN64/src && mkdir -p build && cd build && cmake -DCMAKE_TOOLCHAIN_FILE=../../toolchain-aarch64.cmake -DMUPENPLUSAPI=ON -DEGL=ON -DMESA=ON -DNEON_OPT=ON -DCRC_ARMV8=ON .. && make -j$$(nproc) mupen64plus-video-GLideN64'

# ── Rice video plugin (built per-platform toolchain) ─────────────────────────

.PHONY: rice-tg5040 rice-tg5050

rice-tg5040: $(PATCH_STAMP)
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/mupen64plus-video-rice/projects/unix && rm -rf _obj mupen64plus-video-rice.so && make -j$$(nproc) all $(PLUGIN_MAKE) USE_GLES=1'

rice-tg5050: $(PATCH_STAMP) tg5050-libpng-headers
	$(DOCKER_RUN_5050) bash -c 'cd /build/src/mupen64plus-video-rice/projects/unix && rm -rf _obj mupen64plus-video-rice.so && make -j$$(nproc) all $(PLUGIN_MAKE) USE_GLES=1 CPPFLAGS="-I/build/include" LIBPNG_CFLAGS="-I/build/src/libpng-headers/libpng-1.6.37" LIBPNG_LDLIBS="-lpng16 -lz"'

# ── Dist assembly ─────────────────────────────────────────────────────────────

.PHONY: dist dist-tg5040 dist-tg5050

# Shared data/config files copied into each platform dir
define DIST_COMMON
	cp $(CONFIG)/shared/default.cfg $(1)/
	cp $(CONFIG)/shared/overlay_settings.json $(1)/
	cp $(SRC)/GLideN64/src/build/plugin/Release/mupen64plus-video-GLideN64.so $(1)/
	cp $(SRC)/mupen64plus-core/data/mupen64plus.ini    $(1)/
	cp $(SRC)/mupen64plus-input-sdl/data/InputAutoCfg.ini $(1)/
	cp $(SRC)/mupen64plus-core/data/mupencheat.txt     $(1)/
	cp $(SRC)/mupen64plus-video-rice/data/RiceVideoLinux.ini $(1)/
	cp $(SRC)/7zip/7zzs                                $(1)/
	cp $(SRC)/7zip/License.txt                         $(1)/7zzs.LICENSE
	cp $(SRC)/nx-redux/skeleton/SYSTEM/res/nav_button_a.png $(1)/
	cp $(SRC)/nx-redux/skeleton/SYSTEM/res/nav_button_b.png $(1)/
	cp $(SRC)/nx-redux/skeleton/SYSTEM/res/nav_dpad_horizontal.png $(1)/
	cp pak.json $(1)/
endef

dist: dist-tg5040 dist-tg5050
	@echo "=== dist/N64.pak/ assembled ==="
	@find $(DIST) -type f | sort

dist-tg5040:
	mkdir -p $(DIST)/tg5040
	cp $(CONFIG)/shared/launch.sh $(DIST)/launch.sh
	cp $(SRC)/mupen64plus-core/projects/unix/libmupen64plus.so.2.0.0 $(DIST)/tg5040/libmupen64plus.so.2
	cp $(SRC)/mupen64plus-ui-console/projects/unix/mupen64plus       $(DIST)/tg5040/
	cp $(SRC)/mupen64plus-audio-sdl/projects/unix/mupen64plus-audio-sdl.so $(DIST)/tg5040/
	cp $(SRC)/mupen64plus-input-sdl/projects/unix/mupen64plus-input-sdl.so $(DIST)/tg5040/
	cp $(SRC)/mupen64plus-rsp-hle/projects/unix/mupen64plus-rsp-hle.so     $(DIST)/tg5040/
	cp $(SRC)/mupen64plus-video-rice/projects/unix/mupen64plus-video-rice.so $(DIST)/tg5040/
	$(call DIST_COMMON,$(DIST)/tg5040)
	$(DOCKER_RUN_5050) cp /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng16.so.16.37.0 /build/dist/N64.pak/tg5040/libpng16.so.16
	$(DOCKER_RUN_5050) cp /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libz.so.1.2.12 /build/dist/N64.pak/tg5040/libz.so.1

dist-tg5050:
	mkdir -p $(DIST)/tg5050
	cp $(CONFIG)/shared/launch.sh $(DIST)/launch.sh
	cp $(SRC)/mupen64plus-core/projects/unix/libmupen64plus.so.2.0.0 $(DIST)/tg5050/libmupen64plus.so.2
	cp $(SRC)/mupen64plus-ui-console/projects/unix/mupen64plus       $(DIST)/tg5050/
	cp $(SRC)/mupen64plus-audio-sdl/projects/unix/mupen64plus-audio-sdl.so $(DIST)/tg5050/
	cp $(SRC)/mupen64plus-input-sdl/projects/unix/mupen64plus-input-sdl.so $(DIST)/tg5050/
	cp $(SRC)/mupen64plus-rsp-hle/projects/unix/mupen64plus-rsp-hle.so     $(DIST)/tg5050/
	cp $(SRC)/mupen64plus-video-rice/projects/unix/mupen64plus-video-rice.so $(DIST)/tg5050/
	$(call DIST_COMMON,$(DIST)/tg5050)
	$(DOCKER_RUN_5050) cp /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng16.so.16.37.0 /build/dist/N64.pak/tg5050/libpng16.so.16
	$(DOCKER_RUN_5050) cp /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libz.so.1.2.12 /build/dist/N64.pak/tg5050/libz.so.1

release: build dist
	$(MAKE) bump-version
	cd dist && zip -r "$(PAK_NAME).pak.zip" "$(PAK_NAME).pak"
	ls -lah dist

bump-version:
	jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp
	mv pak.json.tmp pak.json

# ── Regenerate patches from current source trees ─────────────────────────────

patches:
	cd $(SRC)/GLideN64 && git add -N . && git diff -- . ':!src/GLideNHQ/lib/*.a' > $(PATCHES)/GLideN64-standalone.patch && git reset -q
	cd $(SRC)/mupen64plus-core && git add -N . && git diff > $(PATCHES)/mupen64plus-core.patch && git reset -q
	cd $(SRC)/mupen64plus-ui-console && git add -N . && git diff > $(PATCHES)/mupen64plus-ui-console.patch && git reset -q
	cd $(SRC)/mupen64plus-input-sdl && git add -N . && git diff > $(PATCHES)/mupen64plus-input-sdl.patch && git reset -q
	cd $(SRC)/mupen64plus-video-rice && git add -N . && git diff > $(PATCHES)/mupen64plus-video-rice.patch && git reset -q

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -rf $(SRC) $(ROOT)/dist $(ROOT)/include
	rm -f $(PATCHES)/mupen64plus-audio-sdl.patch
