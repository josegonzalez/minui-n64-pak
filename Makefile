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

# 7-Zip standalone binary for ZIP/7Z ROM extraction. Pre-built blobs
# published by the upstream 7-Zip project on GitHub. Sha256-verified.
SEVENZ_VERSION := 26.00
SEVENZ_TAG     := 2600
SEVENZ_URL          := https://github.com/ip7z/7zip/releases/download/$(SEVENZ_VERSION)/7z$(SEVENZ_TAG)-linux-arm64.tar.xz
SEVENZ_SHA256       := aa8f3d0a19af9674d3af0ec788b4e261501071e626cd75ad149f1c2c176cc87d
SEVENZ_URL_ARM32    := https://github.com/ip7z/7zip/releases/download/$(SEVENZ_VERSION)/7z$(SEVENZ_TAG)-linux-arm.tar.xz
SEVENZ_SHA256_ARM32 := 54755c32564c5966ab6ddeca376472e1d146b3b76648184f6a7797a7fab3af52

# ── Docker toolchain images ───────────────────────────────────────────────────
TG5040_IMAGE      := ghcr.io/loveretro/tg5040-toolchain:latest
TG5050_IMAGE      := ghcr.io/loveretro/tg5050-toolchain:latest
RG35XXPLUS_IMAGE  := savant/minui-toolchain:rg35xxplus

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

# ── rg35xxplus cross-compile variables (ARM32) ───────────────────────────────
CROSS_RG35XXPLUS    := arm-buildroot-linux-gnueabihf-
HOST_CPU_RG35XXPLUS := arm

CORE_FLAGS_RG35XXPLUS := CROSS_COMPILE=$(CROSS_RG35XXPLUS) HOST_CPU=$(HOST_CPU_RG35XXPLUS) \
	USE_GLES=1 NEON=1 PIE=1 VULKAN=0 \
	PKG_CONFIG=pkg-config OPTFLAGS="-O3 -marm -mtune=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard"

# Docker run helper script — sets up env, then runs the given command.
# Written to src/.docker-env.sh during clone phase.
DOCKER_SCRIPT := /build/src/.docker-env.sh

# ══════════════════════════════════════════════════════════════════════════════
# Top-level targets
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: all build tg5040 tg5050 rg35xxplus gliden64 gliden64-arm32 rice dist clone patch patches clean \
       ini-tg5040 ini-tg5050 ini-rg35xxplus rice-tg5040 rice-tg5050 rice-rg35xxplus \
       dist-tg5040 dist-tg5050 dist-rg35xxplus

build: clone patch
	$(MAKE) tg5040
	$(MAKE) tg5050
	$(MAKE) gliden64
	$(MAKE) rice-tg5040
	$(MAKE) rice-tg5050
	$(MAKE) ini-tg5040
	$(MAKE) ini-tg5050
	$(MAKE) rg35xxplus
	$(MAKE) gliden64-arm32
	$(MAKE) rice-rg35xxplus
	$(MAKE) ini-rg35xxplus

# Build all platforms sequentially, staging outputs between builds since they
# share source directories.
all:
	$(MAKE) dist-tg5040
	$(MAKE) dist-tg5050
	$(MAKE) dist-rg35xxplus
	@echo "=== Build complete. dist/N64.pak/ assembled ==="
	@find $(DIST) -type f | sort

# ── Clone ─────────────────────────────────────────────────────────────────────

clone: $(SRC)/mupen64plus-core $(SRC)/mupen64plus-ui-console \
       $(SRC)/mupen64plus-audio-sdl $(SRC)/mupen64plus-input-sdl \
       $(SRC)/mupen64plus-rsp-hle $(SRC)/GLideN64 \
       $(SRC)/mupen64plus-video-rice $(SRC)/nx-redux \
       $(SRC)/zlib $(SRC)/7zip/7zzs $(SRC)/7zip-arm32/7zzs
	@# Write Docker env helper script (sets up cross-compile env, then exec's args)
	@printf '#!/bin/bash\nsource ~/.bashrc\nexport PKG_CONFIG_PATH=/opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/pkgconfig\nexport PKG_CONFIG_SYSROOT_DIR=/opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc\nexport SDL_CFLAGS="$$(pkg-config --cflags sdl2)"\nexport SDL_LDLIBS="$$(pkg-config --libs sdl2)"\nexec "$$@"\n' > $(SRC)/.docker-env.sh
	@chmod +x $(SRC)/.docker-env.sh
	@# rg35xxplus Docker env (ARM32 — no pkg-config available, hardcode SDL flags)
	@printf '#!/bin/bash\nexport PATH=/opt/rg35xxplus-toolchain/usr/bin:$$PATH\nexport SDL_CFLAGS="-I/opt/rg35xxplus-toolchain/usr/arm-buildroot-linux-gnueabihf/sysroot/usr/include/SDL2 -D_REENTRANT"\nexport SDL_LDLIBS="-lSDL2"\nexec "$$@"\n' > $(SRC)/.docker-env-rg35xxplus.sh
	@chmod +x $(SRC)/.docker-env-rg35xxplus.sh
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

$(SRC)/7zip-arm32/7zzs:
	@mkdir -p $(SRC)/7zip-arm32
	@echo "Fetching 7-Zip $(SEVENZ_VERSION) (arm32) from upstream…"
	@curl -fsSL -o $(SRC)/7zip-arm32/7z-linux-arm.tar.xz $(SEVENZ_URL_ARM32)
	@echo "$(SEVENZ_SHA256_ARM32)  $(SRC)/7zip-arm32/7z-linux-arm.tar.xz" | shasum -a 256 -c -
	@tar -xJf $(SRC)/7zip-arm32/7z-linux-arm.tar.xz -C $(SRC)/7zip-arm32 7zzs License.txt
	@chmod +x $(SRC)/7zip-arm32/7zzs
	@rm -f $(SRC)/7zip-arm32/7z-linux-arm.tar.xz

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

DOCKER_SCRIPT_RG35XXPLUS := /build/src/.docker-env-rg35xxplus.sh
DOCKER_RUN_RG35XXPLUS    := docker run --rm -v $(ROOT):/build $(RG35XXPLUS_IMAGE) $(DOCKER_SCRIPT_RG35XXPLUS)

# Common plugin make flags (SDL_CFLAGS/SDL_LDLIBS exported by docker-env.sh)
PLUGIN_MAKE := CROSS_COMPILE=$(CROSS) HOST_CPU=$(HOST_CPU) PIE=1 \
	PKG_CONFIG=pkg-config \
	APIDIR=/build/src/mupen64plus-core/src/api \
	OPTFLAGS="-O3 -mcpu=cortex-a53"

PLUGIN_MAKE_RG35XXPLUS := CROSS_COMPILE=$(CROSS_RG35XXPLUS) HOST_CPU=$(HOST_CPU_RG35XXPLUS) PIE=1 \
	PKG_CONFIG=pkg-config \
	APIDIR=/build/src/mupen64plus-core/src/api \
	OPTFLAGS="-O3 -marm -mtune=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard"

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

# ── rg35xxplus build (ARM32) ─────────────────────────────────────────────────

.PHONY: rg35xxplus rg35xxplus-core rg35xxplus-ui rg35xxplus-audio rg35xxplus-input rg35xxplus-rsp

rg35xxplus: rg35xxplus-core rg35xxplus-ui rg35xxplus-audio rg35xxplus-input rg35xxplus-rsp

rg35xxplus-core: $(PATCH_STAMP)
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/src/mupen64plus-core/projects/unix && rm -rf _obj libmupen64plus.so* ../../src/asm_defines/asm_defines_gas.h ../../src/asm_defines/asm_defines_nasm.h && make -j$$(nproc) all $(CORE_FLAGS_RG35XXPLUS)'

rg35xxplus-ui: $(PATCH_STAMP)
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/src/mupen64plus-ui-console/projects/unix && rm -rf _obj mupen64plus && make -j$$(nproc) all $(PLUGIN_MAKE_RG35XXPLUS) COREDIR="./" PLUGINDIR="./"'

rg35xxplus-audio: $(PATCH_STAMP)
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/src/mupen64plus-audio-sdl/projects/unix && rm -rf _obj mupen64plus-audio-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE_RG35XXPLUS)'

rg35xxplus-input: $(PATCH_STAMP)
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/src/mupen64plus-input-sdl/projects/unix && rm -rf _obj mupen64plus-input-sdl.so && make -j$$(nproc) all $(PLUGIN_MAKE_RG35XXPLUS)'

rg35xxplus-rsp: $(PATCH_STAMP)
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/src/mupen64plus-rsp-hle/projects/unix && rm -rf _obj mupen64plus-rsp-hle.so && make -j$$(nproc) all $(PLUGIN_MAKE_RG35XXPLUS)'

# ── GLideN64 (shared — built with tg5040 toolchain) ──────────────────────────

.PHONY: gliden64

gliden64: $(PATCH_STAMP)
	@# Cross-compile zlib from source (tg5040 toolchain has 1.2.8, too old for GLideN64)
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/zlib && [ -f libz.a ] || (CC=aarch64-nextui-linux-gnu-gcc AR=aarch64-nextui-linux-gnu-ar RANLIB=aarch64-nextui-linux-gnu-ranlib ./configure --static && make -j$$(nproc))'
	@# Replace bundled static libs with ARM64 versions:
	@#   libpng16.a from tg5050 sysroot (tg5040 only has libpng12)
	@#   libz.a from zlib source build above
	$(DOCKER_RUN_5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng16.a /build/src/GLideN64/src/GLideNHQ/lib/libpng.a
	cp $(SRC)/zlib/libz.a $(SRC)/GLideN64/src/GLideNHQ/lib/libz.a
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/GLideN64/src && mkdir -p build && cd build && cmake -DCMAKE_TOOLCHAIN_FILE=../../toolchain-aarch64.cmake -DMUPENPLUSAPI=ON -DEGL=ON -DMESA=ON -DNEON_OPT=ON -DCRC_ARMV8=ON .. && make -j$$(nproc) mupen64plus-video-GLideN64'

# ── GLideN64 ARM32 (rg35xxplus toolchain, separate build dir) ────────────────

.PHONY: gliden64-arm32

gliden64-arm32: $(PATCH_STAMP) tg5050-libpng-headers
	@# Cross-compile zlib for ARM32 (separate copy of source to avoid conflicts)
	@if [ ! -d $(SRC)/zlib-arm32 ]; then cp -r $(SRC)/zlib $(SRC)/zlib-arm32; fi
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/src/zlib-arm32 && [ -f libz.a ] || (make distclean 2>/dev/null; CC=arm-buildroot-linux-gnueabihf-gcc AR=arm-buildroot-linux-gnueabihf-ar RANLIB=arm-buildroot-linux-gnueabihf-ranlib CFLAGS="-marm -mtune=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard" ./configure --static && make -j$$(nproc))'
	@# Cross-compile libpng for ARM32 (uses libpng source from tg5050-libpng-headers)
	@if [ ! -d $(SRC)/libpng-arm32 ]; then cp -r $(LIBPNG_DIR) $(SRC)/libpng-arm32; fi
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/src/libpng-arm32 && [ -f libpng16.a ] || (CC=arm-buildroot-linux-gnueabihf-gcc AR=arm-buildroot-linux-gnueabihf-ar RANLIB=arm-buildroot-linux-gnueabihf-ranlib CFLAGS="-marm -mtune=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard -I/build/src/zlib-arm32" LDFLAGS="-L/build/src/zlib-arm32" ./configure --host=arm-buildroot-linux-gnueabihf --prefix=/tmp/libpng-arm32 --enable-static --disable-shared && make -j$$(nproc))'
	@# Replace bundled static libs with ARM32 versions
	cp $(SRC)/libpng-arm32/.libs/libpng16.a $(SRC)/GLideN64/src/GLideNHQ/lib/libpng.a
	cp $(SRC)/zlib-arm32/libz.a $(SRC)/GLideN64/src/GLideNHQ/lib/libz.a
	@# Generate ARM32 CMake toolchain file
	@printf 'set(CMAKE_SYSTEM_NAME Linux)\nset(CMAKE_SYSTEM_PROCESSOR arm)\n\nset(TOOLCHAIN_ROOT /opt/rg35xxplus-toolchain/usr)\nset(SYSROOT $${TOOLCHAIN_ROOT}/arm-buildroot-linux-gnueabihf/sysroot)\n\nset(CMAKE_C_COMPILER $${TOOLCHAIN_ROOT}/bin/arm-buildroot-linux-gnueabihf-gcc)\nset(CMAKE_CXX_COMPILER $${TOOLCHAIN_ROOT}/bin/arm-buildroot-linux-gnueabihf-g++)\n\nset(CMAKE_C_FLAGS "$${CMAKE_C_FLAGS} -marm -mtune=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard")\nset(CMAKE_CXX_FLAGS "$${CMAKE_CXX_FLAGS} -marm -mtune=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard")\n\nset(CMAKE_FIND_ROOT_PATH $${SYSROOT} $${SYSROOT}/usr)\nset(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)\nset(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)\nset(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)\n\ninclude_directories(/build/include)\ninclude_directories($${SYSROOT}/usr/include)\nlink_directories($${SYSROOT}/usr/lib)\n\nset(PNG_LIBRARY /build/src/libpng-arm32/.libs/libpng16.a)\nset(PNG_PNG_INCLUDE_DIR /build/src/libpng-arm32)\nset(ZLIB_LIBRARY /build/src/zlib-arm32/libz.a)\nset(ZLIB_INCLUDE_DIR /build/src/zlib-arm32)\n\nset(FREETYPE_INCLUDE_DIRS $${SYSROOT}/usr/include/freetype2)\nset(FREETYPE_LIBRARIES $${SYSROOT}/usr/lib/libfreetype.so)\nset(FREETYPE_FOUND TRUE)\n\nset(SDL_TTF_INCLUDE_DIRS $${SYSROOT}/usr/include/SDL2)\nset(SDL_TTF_LIBRARIES $${SYSROOT}/usr/lib/libSDL2_ttf.so)\n' > $(SRC)/GLideN64/toolchain-arm32.cmake
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/src/GLideN64/src && mkdir -p build-arm32 && cd build-arm32 && cmake -DCMAKE_TOOLCHAIN_FILE=../../toolchain-arm32.cmake -DMUPENPLUSAPI=ON -DEGL=ON -DMESA=ON -DNEON_OPT=ON -DCRC_ARMV8=OFF .. && make -j$$(nproc) mupen64plus-video-GLideN64'

# ── Rice video plugin (built per-platform toolchain) ─────────────────────────

.PHONY: rice-tg5040 rice-tg5050 rice-rg35xxplus

rice-tg5040: $(PATCH_STAMP)
	$(DOCKER_RUN_5040) bash -c 'cd /build/src/mupen64plus-video-rice/projects/unix && rm -rf _obj mupen64plus-video-rice.so && make -j$$(nproc) all $(PLUGIN_MAKE) USE_GLES=1'

rice-tg5050: $(PATCH_STAMP) tg5050-libpng-headers
	$(DOCKER_RUN_5050) bash -c 'cd /build/src/mupen64plus-video-rice/projects/unix && rm -rf _obj mupen64plus-video-rice.so && make -j$$(nproc) all $(PLUGIN_MAKE) USE_GLES=1 CPPFLAGS="-I/build/include" LIBPNG_CFLAGS="-I/build/src/libpng-headers/libpng-1.6.37" LIBPNG_LDLIBS="-lpng16 -lz"'

rice-rg35xxplus: $(PATCH_STAMP)
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/src/mupen64plus-video-rice/projects/unix && rm -rf _obj mupen64plus-video-rice.so && make -j$$(nproc) all $(PLUGIN_MAKE_RG35XXPLUS) USE_GLES=1'

# ── INI CLI tool (pure C, no SDK dependencies) ──────────────────────────────

ini-tg5040:
	$(DOCKER_RUN_5040) bash -c 'cd /build/tools/ini && make clean all CROSS_COMPILE=$(CROSS)'
	mkdir -p $(ROOT)/tools/ini/dist/tg5040
	cp $(ROOT)/tools/ini/build/ini $(ROOT)/tools/ini/dist/tg5040/ini

ini-tg5050:
	$(DOCKER_RUN_5050) bash -c 'cd /build/tools/ini && make clean all CROSS_COMPILE=$(CROSS)'
	mkdir -p $(ROOT)/tools/ini/dist/tg5050
	cp $(ROOT)/tools/ini/build/ini $(ROOT)/tools/ini/dist/tg5050/ini

ini-rg35xxplus:
	$(DOCKER_RUN_RG35XXPLUS) bash -c 'cd /build/tools/ini && make clean all CROSS_COMPILE=$(CROSS_RG35XXPLUS)'
	mkdir -p $(ROOT)/tools/ini/dist/rg35xxplus
	cp $(ROOT)/tools/ini/build/ini $(ROOT)/tools/ini/dist/rg35xxplus/ini

# ── Dist assembly ─────────────────────────────────────────────────────────────

# Shared data/config files copied into each platform dir (ARM64)
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

# Shared data/config files for rg35xxplus (ARM32 GLideN64 + 7zip)
define DIST_COMMON_RG35XXPLUS
	cp $(CONFIG)/shared/default.cfg $(1)/
	cp $(CONFIG)/shared/overlay_settings.json $(1)/
	cp $(SRC)/GLideN64/src/build-arm32/plugin/Release/mupen64plus-video-GLideN64.so $(1)/
	cp $(SRC)/mupen64plus-core/data/mupen64plus.ini    $(1)/
	cp $(SRC)/mupen64plus-input-sdl/data/InputAutoCfg.ini $(1)/
	cp $(SRC)/mupen64plus-core/data/mupencheat.txt     $(1)/
	cp $(SRC)/mupen64plus-video-rice/data/RiceVideoLinux.ini $(1)/
	cp $(SRC)/7zip-arm32/7zzs                          $(1)/
	cp $(SRC)/7zip-arm32/License.txt                   $(1)/7zzs.LICENSE
	cp pak.json $(1)/
endef

dist: dist-tg5040 dist-tg5050 dist-rg35xxplus
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
	cp $(ROOT)/tools/ini/dist/tg5040/ini $(DIST)/tg5040/
	$(DOCKER_RUN_5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng16.so.16.37.0 /build/dist/N64.pak/tg5040/libpng16.so.16
	$(DOCKER_RUN_5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libz.so.1.2.12 /build/dist/N64.pak/tg5040/libz.so.1

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
	cp $(ROOT)/tools/ini/dist/tg5050/ini $(DIST)/tg5050/
	$(DOCKER_RUN_5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libpng16.so.16.37.0 /build/dist/N64.pak/tg5050/libpng16.so.16
	$(DOCKER_RUN_5050) install -m 0644 /opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc/usr/lib/libz.so.1.2.12 /build/dist/N64.pak/tg5050/libz.so.1

dist-rg35xxplus:
	mkdir -p $(DIST)/rg35xxplus
	cp $(CONFIG)/shared/launch.sh $(DIST)/launch.sh
	cp $(SRC)/mupen64plus-core/projects/unix/libmupen64plus.so.2.0.0 $(DIST)/rg35xxplus/libmupen64plus.so.2
	cp $(SRC)/mupen64plus-ui-console/projects/unix/mupen64plus       $(DIST)/rg35xxplus/
	cp $(SRC)/mupen64plus-audio-sdl/projects/unix/mupen64plus-audio-sdl.so $(DIST)/rg35xxplus/
	cp $(SRC)/mupen64plus-input-sdl/projects/unix/mupen64plus-input-sdl.so $(DIST)/rg35xxplus/
	cp $(SRC)/mupen64plus-rsp-hle/projects/unix/mupen64plus-rsp-hle.so     $(DIST)/rg35xxplus/
	cp $(SRC)/mupen64plus-video-rice/projects/unix/mupen64plus-video-rice.so $(DIST)/rg35xxplus/
	$(call DIST_COMMON_RG35XXPLUS,$(DIST)/rg35xxplus)
	cp $(ROOT)/tools/ini/dist/rg35xxplus/ini $(DIST)/rg35xxplus/
	$(DOCKER_RUN_RG35XXPLUS) install -m 0644 /opt/rg35xxplus-toolchain/usr/arm-buildroot-linux-gnueabihf/sysroot/usr/lib/libpng16.so.16.32.0 /build/dist/N64.pak/rg35xxplus/libpng16.so.16
	$(DOCKER_RUN_RG35XXPLUS) install -m 0644 /opt/rg35xxplus-toolchain/usr/arm-buildroot-linux-gnueabihf/sysroot/usr/lib/libz.so.1.2.11 /build/dist/N64.pak/rg35xxplus/libz.so.1

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
	cd $(ROOT)/tools/ini && make clean
	rm -rf $(ROOT)/tools/ini/dist
