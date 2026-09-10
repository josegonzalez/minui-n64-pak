PAK_NAME := $(shell jq -r .name pak.json)
PAK_TYPE := $(shell jq -r .type pak.json)
PAK_FOLDER := $(shell echo $(PAK_TYPE) | cut -c1)$(shell echo $(PAK_TYPE) | tr '[:upper:]' '[:lower:]' | cut -c2-)s

PUSH_SDCARD_PATH ?= /mnt/sdcard
PUSH_PLATFORM ?= my355

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
MY355_IMAGE  := ghcr.io/loveretro/my355-toolchain:latest
# The h700 image is the tg5040 image plus a patched mali-fbdev SDL2 under
# /opt/nextui: same cross compiler, same TrimUI SDK sysroot.
H700_IMAGE   := ghcr.io/loveretro/h700-toolchain:latest

# ── Platform specific CPU flags ───────────────────────────────────────────────
TG5040_CPUFLAGS := -mcpu=cortex-a53 -mtune=cortex-a53
TG5050_CPUFLAGS := -mcpu=cortex-a55 -mtune=cortex-a55
MY355_CPUFLAGS  := -mcpu=cortex-a55 -mtune=cortex-a55
H700_CPUFLAGS   := -mcpu=cortex-a53 -mtune=cortex-a53

# ── Paths ─────────────────────────────────────────────────────────────────────
ROOT     := $(shell pwd)
SRC      := $(ROOT)/src
DIST     := $(ROOT)/dist/N64.pak
BUILD    := $(ROOT)/build
PATCHES  := $(ROOT)/patches/shared
CONFIG   := $(ROOT)/config

# ── Cross-compile variables ───────────────────────────────────────────────────
CROSS    := aarch64-nextui-linux-gnu-
HOST_CPU := aarch64

# Common make flags for core (no SDL needed)
CORE_FLAGS := CROSS_COMPILE=$(CROSS) HOST_CPU=$(HOST_CPU) \
	USE_GLES=1 NEON=1 PIE=1 VULKAN=0 \
	PKG_CONFIG=pkg-config

# Docker run helper script — sets up env, then runs the given command.
DOCKER_SCRIPT := /build/scripts/docker-env.sh

# ══════════════════════════════════════════════════════════════════════════════
# Top-level targets
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: all build tg5040 tg5050 my355 h700 gliden64 rice dist clone patch patches \
	   clean ini-tg5040 ini-tg5050 ini-my355 ini-h700 \
	   stage-tg5040 stage-tg5050 stage-my355 stage-h700

# The emulator components share source output paths.  Build and stage each
# platform before compiling the next one so dist never copies another
# platform's binaries.
build: clone patch gliden64
	$(MAKE) stage-tg5040
	$(MAKE) stage-tg5050
	$(MAKE) stage-my355
	$(MAKE) stage-h700

all: dist

# ── Clone ─────────────────────────────────────────────────────────────────────

clone: $(SRC)/mupen64plus-core $(SRC)/mupen64plus-ui-console \
       $(SRC)/mupen64plus-audio-sdl $(SRC)/mupen64plus-input-sdl \
       $(SRC)/mupen64plus-rsp-hle $(SRC)/GLideN64 \
       $(SRC)/mupen64plus-video-rice $(SRC)/nx-redux \
       $(SRC)/zlib $(SRC)/7zip/7zzs
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
# DOCKER_RUN_TG5040 / DOCKER_RUN_TG5050: run a command inside the toolchain container
# The .docker-env.sh script sets up the cross-compile environment then exec's the arg.

DOCKER_RUN_TG5040  := docker run --rm -v $(ROOT):/build $(TG5040_IMAGE) $(DOCKER_SCRIPT)
DOCKER_RUN_TG5050  := docker run --rm -v $(ROOT):/build $(TG5050_IMAGE) $(DOCKER_SCRIPT)
DOCKER_RUN_MY355   := docker run --rm -v $(ROOT):/build $(MY355_IMAGE) $(DOCKER_SCRIPT)
DOCKER_RUN_H700    := docker run --rm -v $(ROOT):/build $(H700_IMAGE) $(DOCKER_SCRIPT)

# Common plugin make flags (SDL_CFLAGS/SDL_LDLIBS exported by docker-env.sh)
PLUGIN_MAKE := CROSS_COMPILE=$(CROSS) HOST_CPU=$(HOST_CPU) PIE=1 \
	PKG_CONFIG=pkg-config \
	APIDIR=/build/src/mupen64plus-core/src/api

# ── TG5040 build ──────────────────────────────────────────────────────────────

.PHONY: tg5040 tg5040-core tg5040-ui tg5040-audio tg5040-input tg5040-rsp

tg5040: tg5040-core tg5040-ui tg5040-audio tg5040-input tg5040-rsp

tg5040-core: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5040) bash -c 'cd /build/src/mupen64plus-core/projects/unix && rm -rf _obj libmupen64plus.so* ../../src/asm_defines/asm_defines_gas.h ../../src/asm_defines/asm_defines_nasm.h && make -j$$(nproc) all $(CORE_FLAGS) OPTFLAGS="-O3 $(TG5040_CPUFLAGS)"'

tg5040-ui: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5040) bash -c 'cd /build/src/mupen64plus-ui-console/projects/unix && rm -rf _obj mupen64plus && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5040_CPUFLAGS)" COREDIR="./" PLUGINDIR="./"'

tg5040-audio: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5040) bash -c 'cd /build/src/mupen64plus-audio-sdl/projects/unix && rm -rf _obj mupen64plus-audio-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5040_CPUFLAGS)"'

tg5040-input: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5040) bash -c 'cd /build/src/mupen64plus-input-sdl/projects/unix && rm -rf _obj mupen64plus-input-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5040_CPUFLAGS)"'

tg5040-rsp: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5040) bash -c 'cd /build/src/mupen64plus-rsp-hle/projects/unix && rm -rf _obj mupen64plus-rsp-hle.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5040_CPUFLAGS)"'

# ── TG5050 build ──────────────────────────────────────────────────────────────

.PHONY: tg5050 tg5050-core tg5050-ui tg5050-audio tg5050-input tg5050-rsp tg5050-libpng-headers

# libpng headers workaround for broken TG5050 toolchain symlinks
TG5050_LIBPNG_DIR := $(SRC)/libpng-headers/libpng-1.6.37

tg5050-libpng-headers: $(TG5050_LIBPNG_DIR)/pnglibconf.h

$(TG5050_LIBPNG_DIR)/pnglibconf.h:
	mkdir -p $(SRC)/libpng-headers
	cd $(SRC)/libpng-headers && \
		curl -sL https://github.com/glennrp/libpng/archive/refs/tags/v1.6.37.tar.gz -o libpng.tar.gz && \
		tar xf libpng.tar.gz && \
		cp libpng-1.6.37/scripts/pnglibconf.h.prebuilt libpng-1.6.37/pnglibconf.h

tg5050: tg5050-core tg5050-ui tg5050-audio tg5050-input tg5050-rsp

tg5050-core: $(PATCH_STAMP) tg5050-libpng-headers
	$(DOCKER_RUN_TG5050) bash -c 'cd /build/src/mupen64plus-core/projects/unix && rm -rf _obj libmupen64plus.so* ../../src/asm_defines/asm_defines_gas.h ../../src/asm_defines/asm_defines_nasm.h && make -j$$(nproc) all $(CORE_FLAGS) OPTFLAGS="-O3 $(TG5050_CPUFLAGS)" LIBPNG_CFLAGS="-I/build/src/libpng-headers/libpng-1.6.37" LIBPNG_LDLIBS="-lpng16 -lz"'

tg5050-ui: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5050) bash -c 'cd /build/src/mupen64plus-ui-console/projects/unix && rm -rf _obj mupen64plus && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5050_CPUFLAGS)" COREDIR="./" PLUGINDIR="./"'

tg5050-audio: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5050) bash -c 'cd /build/src/mupen64plus-audio-sdl/projects/unix && rm -rf _obj mupen64plus-audio-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5050_CPUFLAGS)"'

tg5050-input: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5050) bash -c 'cd /build/src/mupen64plus-input-sdl/projects/unix && rm -rf _obj mupen64plus-input-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5050_CPUFLAGS)"'

tg5050-rsp: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5050) bash -c 'cd /build/src/mupen64plus-rsp-hle/projects/unix && rm -rf _obj mupen64plus-rsp-hle.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5050_CPUFLAGS)"'

# ── MY355 build ──────────────────────────────────────────────────────────────

.PHONY: my355 my355-core my355-ui my355-audio my355-input my355-rsp my355-libpng

MY355_LIBPNG_DIR := $(SRC)/libpng-build/libpng-1.6.37

my355-libpng: $(MY355_LIBPNG_DIR)/.libs/libpng16.a

$(MY355_LIBPNG_DIR)/.libs/libpng16.a:
	mkdir -p $(SRC)/libpng-build
	cd $(SRC)/libpng-build && \
		curl -sL https://github.com/glennrp/libpng/archive/refs/tags/v1.6.37.tar.gz -o libpng.tar.gz && \
		tar xf libpng.tar.gz
	$(DOCKER_RUN_MY355) bash -c 'cd /build/src/libpng-build/libpng-1.6.37 && \
		CC=aarch64-nextui-linux-gnu-gcc \
		AR=aarch64-nextui-linux-gnu-ar \
		RANLIB=aarch64-nextui-linux-gnu-ranlib \
		CFLAGS="-O3 -fPIC" \
		./configure --host=aarch64-nextui-linux-gnu --enable-static --disable-shared --with-pic && \
		make -j$$(nproc)'

my355: my355-core my355-ui my355-audio my355-input my355-rsp

my355-core: $(PATCH_STAMP) my355-libpng
	$(DOCKER_RUN_MY355) bash -c 'cd /build/src/mupen64plus-core/projects/unix && rm -rf _obj libmupen64plus.so* ../../src/asm_defines/asm_defines_gas.h ../../src/asm_defines/asm_defines_nasm.h && make -j$$(nproc) all $(CORE_FLAGS) OPTFLAGS="-O3 $(MY355_CPUFLAGS)" LIBPNG_CFLAGS="-I/build/src/libpng-build/libpng-1.6.37" LIBPNG_LDLIBS="/build/src/libpng-build/libpng-1.6.37/.libs/libpng16.a -lz"'

my355-ui: $(PATCH_STAMP)
	$(DOCKER_RUN_MY355) bash -c 'cd /build/src/mupen64plus-ui-console/projects/unix && rm -rf _obj mupen64plus && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(MY355_CPUFLAGS)" COREDIR="./" PLUGINDIR="./"'

my355-audio: $(PATCH_STAMP)
	$(DOCKER_RUN_MY355) bash -c 'cd /build/src/mupen64plus-audio-sdl/projects/unix && rm -rf _obj mupen64plus-audio-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(MY355_CPUFLAGS)"'

my355-input: $(PATCH_STAMP)
	$(DOCKER_RUN_MY355) bash -c 'cd /build/src/mupen64plus-input-sdl/projects/unix && rm -rf _obj mupen64plus-input-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(MY355_CPUFLAGS)"'

my355-rsp: $(PATCH_STAMP)
	$(DOCKER_RUN_MY355) bash -c 'cd /build/src/mupen64plus-rsp-hle/projects/unix && rm -rf _obj mupen64plus-rsp-hle.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(MY355_CPUFLAGS)"'

# ── H700 build ───────────────────────────────────────────────────────────────
# Same cross compiler and sysroot as tg5040, so no libpng workaround is needed.
# docker-env.sh points SDL at the toolchain's patched /opt/nextui build.

.PHONY: h700 h700-core h700-ui h700-audio h700-input h700-rsp

h700: h700-core h700-ui h700-audio h700-input h700-rsp

h700-core: $(PATCH_STAMP)
	$(DOCKER_RUN_H700) bash -c 'cd /build/src/mupen64plus-core/projects/unix && rm -rf _obj libmupen64plus.so* ../../src/asm_defines/asm_defines_gas.h ../../src/asm_defines/asm_defines_nasm.h && make -j$$(nproc) all $(CORE_FLAGS) OPTFLAGS="-O3 $(H700_CPUFLAGS)"'

h700-ui: $(PATCH_STAMP)
	$(DOCKER_RUN_H700) bash -c 'cd /build/src/mupen64plus-ui-console/projects/unix && rm -rf _obj mupen64plus && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(H700_CPUFLAGS)" COREDIR="./" PLUGINDIR="./"'

h700-audio: $(PATCH_STAMP)
	$(DOCKER_RUN_H700) bash -c 'cd /build/src/mupen64plus-audio-sdl/projects/unix && rm -rf _obj mupen64plus-audio-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(H700_CPUFLAGS)"'

h700-input: $(PATCH_STAMP)
	$(DOCKER_RUN_H700) bash -c 'cd /build/src/mupen64plus-input-sdl/projects/unix && rm -rf _obj mupen64plus-input-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(H700_CPUFLAGS)"'

h700-rsp: $(PATCH_STAMP)
	$(DOCKER_RUN_H700) bash -c 'cd /build/src/mupen64plus-rsp-hle/projects/unix && rm -rf _obj mupen64plus-rsp-hle.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(H700_CPUFLAGS)"'

# ── GLideN64 (shared — built with tg5040 toolchain) ──────────────────────────

.PHONY: gliden64

gliden64: $(PATCH_STAMP)
	@# Cross-compile zlib from source (tg5040 toolchain has 1.2.8, too old for GLideN64)
	$(DOCKER_RUN_TG5040) bash -c 'cd /build/src/zlib && [ -f libz.a ] || (CC=aarch64-nextui-linux-gnu-gcc AR=aarch64-nextui-linux-gnu-ar RANLIB=aarch64-nextui-linux-gnu-ranlib ./configure --static && make -j$$(nproc))'
	@# Replace bundled static libs with ARM64 versions:
	@#   libpng16.a from tg5050 sysroot (tg5040 only has libpng12)
	@#   libz.a from zlib source build above
	$(DOCKER_RUN_TG5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng16.a /build/src/GLideN64/src/GLideNHQ/lib/libpng.a
	cp $(SRC)/zlib/libz.a $(SRC)/GLideN64/src/GLideNHQ/lib/libz.a
	$(DOCKER_RUN_TG5040) bash -c 'cd /build/src/GLideN64/src && mkdir -p build && cd build && cmake -DCMAKE_TOOLCHAIN_FILE=../../toolchain-aarch64.cmake -DMUPENPLUSAPI=ON -DEGL=ON -DMESA=ON -DNEON_OPT=ON -DCRC_ARMV8=ON .. && make -j$$(nproc) mupen64plus-video-GLideN64'

# ── Rice video plugin (built per-platform toolchain) ─────────────────────────

.PHONY: rice-tg5040 rice-tg5050 rice-my355 rice-h700

rice-tg5040: $(PATCH_STAMP)
	$(DOCKER_RUN_TG5040) bash -c 'cd /build/src/mupen64plus-video-rice/projects/unix && rm -rf _obj mupen64plus-video-rice.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5040_CPUFLAGS)" USE_GLES=1'

rice-tg5050: $(PATCH_STAMP) tg5050-libpng-headers
	$(DOCKER_RUN_TG5050) bash -c 'cd /build/src/mupen64plus-video-rice/projects/unix && rm -rf _obj mupen64plus-video-rice.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(TG5050_CPUFLAGS)" USE_GLES=1 CPPFLAGS="-I/build/include" LIBPNG_CFLAGS="-I/build/src/libpng-headers/libpng-1.6.37" LIBPNG_LDLIBS="-lpng16 -lz"'

rice-my355: $(PATCH_STAMP) my355-libpng
	$(DOCKER_RUN_MY355) bash -c 'cd /build/src/mupen64plus-video-rice/projects/unix && rm -rf _obj mupen64plus-video-rice.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(MY355_CPUFLAGS)" USE_GLES=1 CPPFLAGS="-I/build/include" LIBPNG_CFLAGS="-I/build/src/libpng-build/libpng-1.6.37" LIBPNG_LDLIBS="/build/src/libpng-build/libpng-1.6.37/.libs/libpng16.a -lz"'

rice-h700: $(PATCH_STAMP)
	$(DOCKER_RUN_H700) bash -c 'cd /build/src/mupen64plus-video-rice/projects/unix && rm -rf _obj mupen64plus-video-rice.so && make -j$$(nproc) all $(PLUGIN_MAKE) OPTFLAGS="-O3 $(H700_CPUFLAGS)" USE_GLES=1'

# ── INI CLI tool (pure C, no SDK dependencies) ──────────────────────────────

ini-tg5040:
	$(DOCKER_RUN_TG5040) bash -c 'cd /build/tools/ini && make clean all CROSS_COMPILE=$(CROSS)'
	mkdir -p $(ROOT)/tools/ini/dist/tg5040
	cp $(ROOT)/tools/ini/build/ini $(ROOT)/tools/ini/dist/tg5040/ini

ini-tg5050:
	$(DOCKER_RUN_TG5050) bash -c 'cd /build/tools/ini && make clean all CROSS_COMPILE=$(CROSS)'
	mkdir -p $(ROOT)/tools/ini/dist/tg5050
	cp $(ROOT)/tools/ini/build/ini $(ROOT)/tools/ini/dist/tg5050/ini

ini-my355:
	$(DOCKER_RUN_MY355) bash -c 'cd /build/tools/ini && make clean all CROSS_COMPILE=$(CROSS)'
	mkdir -p $(ROOT)/tools/ini/dist/my355
	cp $(ROOT)/tools/ini/build/ini $(ROOT)/tools/ini/dist/my355/ini

ini-h700:
	$(DOCKER_RUN_H700) bash -c 'cd /build/tools/ini && make clean all CROSS_COMPILE=$(CROSS)'
	mkdir -p $(ROOT)/tools/ini/dist/h700
	cp $(ROOT)/tools/ini/build/ini $(ROOT)/tools/ini/dist/h700/ini

# ── Platform artifact staging ────────────────────────────────────────────────

define STAGE_PLATFORM
	mkdir -p $(BUILD)/$(1)
	cp $(SRC)/mupen64plus-core/projects/unix/libmupen64plus.so.2.0.0 $(BUILD)/$(1)/libmupen64plus.so.2
	cp $(SRC)/mupen64plus-ui-console/projects/unix/mupen64plus       $(BUILD)/$(1)/
	cp $(SRC)/mupen64plus-audio-sdl/projects/unix/mupen64plus-audio-sdl.so $(BUILD)/$(1)/
	cp $(SRC)/mupen64plus-input-sdl/projects/unix/mupen64plus-input-sdl.so $(BUILD)/$(1)/
	cp $(SRC)/mupen64plus-rsp-hle/projects/unix/mupen64plus-rsp-hle.so     $(BUILD)/$(1)/
	cp $(SRC)/mupen64plus-video-rice/projects/unix/mupen64plus-video-rice.so $(BUILD)/$(1)/
	cp $(ROOT)/tools/ini/dist/$(1)/ini $(BUILD)/$(1)/
endef

stage-tg5040: tg5040 rice-tg5040 ini-tg5040
	$(call STAGE_PLATFORM,tg5040)

stage-tg5050: tg5050 rice-tg5050 ini-tg5050
	$(call STAGE_PLATFORM,tg5050)

stage-my355: my355 rice-my355 ini-my355
	$(call STAGE_PLATFORM,my355)

stage-h700: h700 rice-h700 ini-h700
	$(call STAGE_PLATFORM,h700)

# ── Dist assembly ─────────────────────────────────────────────────────────────

.PHONY: dist dist-tg5040 dist-tg5050 dist-my355 dist-h700

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
	cp pak.json $(1)/
endef

dist:
	$(MAKE) dist-tg5040
	$(MAKE) dist-tg5050
	$(MAKE) dist-my355
	$(MAKE) dist-h700
	@echo "=== dist/N64.pak/ assembled ==="
	@find $(DIST) -type f | sort

dist-tg5040: stage-tg5040 gliden64
	mkdir -p $(DIST)/tg5040
	cp $(CONFIG)/shared/launch.sh $(DIST)/launch.sh
	cp $(CONFIG)/shared/platform.sh $(DIST)/platform.sh
	cp $(BUILD)/tg5040/libmupen64plus.so.2 $(DIST)/tg5040/
	cp $(BUILD)/tg5040/mupen64plus $(DIST)/tg5040/
	cp $(BUILD)/tg5040/mupen64plus-audio-sdl.so $(DIST)/tg5040/
	cp $(BUILD)/tg5040/mupen64plus-input-sdl.so $(DIST)/tg5040/
	cp $(BUILD)/tg5040/mupen64plus-rsp-hle.so $(DIST)/tg5040/
	cp $(BUILD)/tg5040/mupen64plus-video-rice.so $(DIST)/tg5040/
	$(call DIST_COMMON,$(DIST)/tg5040)
	cp $(BUILD)/tg5040/ini $(DIST)/tg5040/
	@# The tg5040 sysroot carries libpng12, so that is what the core and Rice link
	@# against. The libpng16 shipped here previously was never loaded.
	$(DOCKER_RUN_TG5040) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng12.so.0.56.0 /build/dist/N64.pak/tg5040/libpng12.so.0
	@# libmupen64plus links libz.so.1; ship the tg5050 sysroot's 1.2.12 rather than
	@# the 1.2.8 in this one.
	$(DOCKER_RUN_TG5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libz.so.1.2.12 /build/dist/N64.pak/tg5040/libz.so.1

dist-tg5050: stage-tg5050 gliden64
	mkdir -p $(DIST)/tg5050
	cp $(CONFIG)/shared/launch.sh $(DIST)/launch.sh
	cp $(CONFIG)/shared/platform.sh $(DIST)/platform.sh
	cp $(BUILD)/tg5050/libmupen64plus.so.2 $(DIST)/tg5050/
	cp $(BUILD)/tg5050/mupen64plus $(DIST)/tg5050/
	cp $(BUILD)/tg5050/mupen64plus-audio-sdl.so $(DIST)/tg5050/
	cp $(BUILD)/tg5050/mupen64plus-input-sdl.so $(DIST)/tg5050/
	cp $(BUILD)/tg5050/mupen64plus-rsp-hle.so $(DIST)/tg5050/
	cp $(BUILD)/tg5050/mupen64plus-video-rice.so $(DIST)/tg5050/
	$(call DIST_COMMON,$(DIST)/tg5050)
	cp $(BUILD)/tg5050/ini $(DIST)/tg5050/
	$(DOCKER_RUN_TG5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng16.so.16.37.0 /build/dist/N64.pak/tg5050/libpng16.so.16
	$(DOCKER_RUN_TG5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libz.so.1.2.12 /build/dist/N64.pak/tg5050/libz.so.1

dist-my355: stage-my355 gliden64
	mkdir -p $(DIST)/my355
	cp $(CONFIG)/shared/launch.sh $(DIST)/launch.sh
	cp $(CONFIG)/shared/platform.sh $(DIST)/platform.sh
	cp $(BUILD)/my355/libmupen64plus.so.2 $(DIST)/my355/
	cp $(BUILD)/my355/mupen64plus $(DIST)/my355/
	cp $(BUILD)/my355/mupen64plus-audio-sdl.so $(DIST)/my355/
	cp $(BUILD)/my355/mupen64plus-input-sdl.so $(DIST)/my355/
	cp $(BUILD)/my355/mupen64plus-rsp-hle.so $(DIST)/my355/
	cp $(BUILD)/my355/mupen64plus-video-rice.so $(DIST)/my355/
	$(call DIST_COMMON,$(DIST)/my355)
	cp $(BUILD)/my355/ini $(DIST)/my355/
	$(DOCKER_RUN_MY355) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libz.so.1.3.1 /build/dist/N64.pak/my355/libz.so.1

dist-h700: stage-h700 gliden64
	mkdir -p $(DIST)/h700
	cp $(CONFIG)/shared/launch.sh $(DIST)/launch.sh
	cp $(CONFIG)/shared/platform.sh $(DIST)/platform.sh
	cp $(BUILD)/h700/libmupen64plus.so.2 $(DIST)/h700/
	cp $(BUILD)/h700/mupen64plus $(DIST)/h700/
	cp $(BUILD)/h700/mupen64plus-audio-sdl.so $(DIST)/h700/
	cp $(BUILD)/h700/mupen64plus-input-sdl.so $(DIST)/h700/
	cp $(BUILD)/h700/mupen64plus-rsp-hle.so $(DIST)/h700/
	cp $(BUILD)/h700/mupen64plus-video-rice.so $(DIST)/h700/
	$(call DIST_COMMON,$(DIST)/h700)
	cp $(BUILD)/h700/ini $(DIST)/h700/
	@# The h700 sysroot carries libpng12, so that is what the core and Rice link
	@# against. Bundle it: the H700 stock OS only ships a 32-bit libpng12 under
	@# /mnt/vendor/lib, and relying on NextUI to supply the 64-bit one would make
	@# the pak depend on which NextUI build the user installed.
	$(DOCKER_RUN_H700) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng12.so.0.56.0 /build/dist/N64.pak/h700/libpng12.so.0
	@# libpng12 wants libz.so.1; the h700 sysroot has 1.2.8, so take the newer
	@# tg5050 copy as the other platforms do.
	$(DOCKER_RUN_TG5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libz.so.1.2.12 /build/dist/N64.pak/h700/libz.so.1

# ── Release ──────────────────────────────────────────────────────────────────

release: dist
	$(MAKE) bump-version
	cp pak.json $(DIST)/
	cd $(DIST) && zip -r "../$(PAK_NAME).pak.zip" .
	ls -lah dist

bump-version:
	jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp
	mv pak.json.tmp pak.json

push: release
	rm -rf "dist/$(PAK_NAME).pak"
	cd dist && unzip "$(PAK_NAME).pak.zip" -d "$(PAK_NAME).pak"
	adb push "dist/$(PAK_NAME).pak/." "$(PUSH_SDCARD_PATH)/$(PAK_FOLDER)/$(PUSH_PLATFORM)/$(PAK_NAME).pak"

# ── Introspection ────────────────────────────────────────────────────────────
# Print the value of any make variable, e.g. `make print-H700_IMAGE`.
# Used by tests/makefile.bats to assert the per-platform build wiring.
print-%:
	@echo '$*=$($*)'

# ── Regenerate patches from current source trees ─────────────────────────────

patches:
	cd $(SRC)/GLideN64 && git add -N . && git diff -- . ':!src/GLideNHQ/lib/*.a' > $(PATCHES)/GLideN64-standalone.patch && git reset -q
	cd $(SRC)/mupen64plus-core && git add -N . && git diff > $(PATCHES)/mupen64plus-core.patch && git reset -q
	cd $(SRC)/mupen64plus-ui-console && git add -N . && git diff > $(PATCHES)/mupen64plus-ui-console.patch && git reset -q
	cd $(SRC)/mupen64plus-input-sdl && git add -N . && git diff > $(PATCHES)/mupen64plus-input-sdl.patch && git reset -q
	cd $(SRC)/mupen64plus-video-rice && git add -N . && git diff > $(PATCHES)/mupen64plus-video-rice.patch && git reset -q

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -rf $(SRC) $(ROOT)/build $(ROOT)/dist $(ROOT)/include
	rm -f $(PATCHES)/mupen64plus-audio-sdl.patch
	cd $(ROOT)/tools/ini && make clean
	rm -rf $(ROOT)/tools/ini/dist
