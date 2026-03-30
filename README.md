# trimui-mupen64plus

Standalone mupen64plus built from upstream sources with custom overlay menu integration for TrimUI devices (tg5040 and tg5050).

## Prerequisites

- Docker (for cross-compilation toolchains)
- Git
- curl (for libpng headers download)

## Quick start

```sh
make clean build
```

This clones upstream repos, applies patches, builds for both platforms sequentially, and assembles `dist/N64.pak/`.

## Build targets

| Target | Description |
|--------|-------------|
| `make all` / `make build` | Full build: clone, patch, build both platforms, assemble dist |
| `make clone` | Clone upstream repos into `src/` |
| `make patch` | Apply patches from `patches/shared/` |
| `make tg5040` | Build all components for tg5040 |
| `make tg5050` | Build all components for tg5050 |
| `make gliden64` | Build GLideN64 video plugin (shared across platforms) |
| `make dist` | Assemble `dist/N64.pak/` from current build outputs |
| `make clean` | Remove `src/` and `dist/` |

### Building a single platform

```sh
make clone patch
make tg5040
make dist-tg5040
```

## Components

All components are built from upstream via Docker cross-compilation toolchains.

| Component | Source | Output |
|-----------|--------|--------|
| mupen64plus-core | `mupen64plus/mupen64plus-core` @ 2.6.0 | `libmupen64plus.so.2` |
| mupen64plus-ui-console | `mupen64plus/mupen64plus-ui-console` @ 2.6.0 | `mupen64plus` |
| mupen64plus-audio-sdl | `mupen64plus/mupen64plus-audio-sdl` @ 2.6.0 | `mupen64plus-audio-sdl.so` |
| mupen64plus-input-sdl | `mupen64plus/mupen64plus-input-sdl` @ 2.6.0 | `mupen64plus-input-sdl.so` |
| mupen64plus-rsp-hle | `mupen64plus/mupen64plus-rsp-hle` @ 2.6.0 | `mupen64plus-rsp-hle.so` |
| GLideN64 | `gonetz/GLideN64` @ c8ef81c | `mupen64plus-video-GLideN64.so` |

## Patches

All patches live in `patches/shared/` (identical for both platforms):

- **mupen64plus-ui-console.patch** — Changes `dlopen()` to use `RTLD_GLOBAL` so GLES/EGL symbols from the core library are visible to plugins loaded later.
- **mupen64plus-audio-sdl.patch** — Empty placeholder (audio plugin is built from unmodified source to enable `src-sinc-fastest` resampler via libsamplerate).
- **GLideN64-standalone.patch** — Adds overlay menu integration (in-game settings menu), cross-compilation toolchain file, and OpenGL ES render backend. References overlay sources from the bundled `overlay/` directory.

## Dist layout

```
dist/N64.pak/
├── launch.sh                          shared launch script (uses $PLATFORM)
├── tg5040/                            TrimUI Brick / Smart Pro
│   ├── mupen64plus                     emulator binary
│   ├── libmupen64plus.so.2             core library
│   ├── mupen64plus-audio-sdl.so        audio plugin
│   ├── mupen64plus-input-sdl.so        input plugin
│   ├── mupen64plus-rsp-hle.so          RSP plugin
│   ├── mupen64plus-video-GLideN64.so   video plugin
│   ├── default.cfg                     base config (patched at runtime)
│   ├── overlay_settings.json           overlay menu config
│   ├── mupen64plus.ini                 ROM database
│   ├── InputAutoCfg.ini                input auto-config
│   ├── mupencheat.txt                  cheat codes
│   └── libpng16.so.16                  libpng runtime
└── tg5050/                            TrimUI Smart Pro S
    └── (same files, built with tg5050 toolchain)
```

## Build flags

| Flag | Purpose |
|------|---------|
| `USE_GLES=1` | OpenGL ES instead of desktop GL |
| `NEON=1` | ARM NEON SIMD optimizations |
| `PIE=1` | Position-independent executable |
| `VULKAN=0` | Disable Vulkan (not available on target) |
| `HOST_CPU=aarch64` | Target architecture (enables NEW_DYNAREC) |
| `COREDIR="./"` | Search for core library relative to CWD |
| `PLUGINDIR="./"` | Search for plugins relative to CWD |

## Platform differences

- **tg5040**: Uses `ghcr.io/loveretro/tg5040-toolchain:latest`. No special setup needed.
- **tg5050**: Uses `ghcr.io/loveretro/tg5050-toolchain:latest`. The toolchain has broken libpng header symlinks — the Makefile automatically downloads libpng 1.6.37 headers as a workaround.
- **GLideN64**: Built once using the tg5040 toolchain. The resulting `.so` is shared across both platforms.
