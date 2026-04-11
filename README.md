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
| `make tg5040` | Build core + audio/input/rsp plugins for tg5040 |
| `make tg5050` | Build core + audio/input/rsp plugins for tg5050 |
| `make gliden64` | Build GLideN64 video plugin (shared across platforms) |
| `make rice-tg5040` / `make rice-tg5050` | Build Rice video plugin per-toolchain |
| `make patches` | Regenerate `patches/shared/*.patch` from the current source trees |
| `make dist` | Assemble `dist/N64.pak/` from current build outputs |
| `make clean` | Remove `src/`, `dist/`, and `include/` |

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
| mupen64plus-video-rice | `mupen64plus/mupen64plus-video-rice` @ 2.6.0 | `mupen64plus-video-rice.so` |

## Patches

All patches live in `patches/shared/`:

- **mupen64plus-core.patch** — Adds `romfilename` field to `ROM_PARAMS` and `SaveFilenameFormat=2` option for ROM-filename-based save naming (matching NextUI conventions). Exports `ROM_PARAMS` in the linker version script so the frontend can set the filename via dlsym.
- **mupen64plus-ui-console.patch** — Changes `dlopen()` to use `RTLD_GLOBAL` so GLES/EGL symbols from the core library are visible to plugins. Sets `ROM_PARAMS.romfilename` from the command-line ROM path (basename without extension) for save file naming.
- **mupen64plus-audio-sdl.patch** — Empty placeholder (pulled from nx-redux at build time). Audio plugin is built from unmodified source to enable `src-sinc-fastest` resampler via libsamplerate.
- **mupen64plus-input-sdl.patch** — Per-game d-pad vs joystick input mode (reads `$EMU_INPUT_MODE_FILE` with stat-mtime caching and remaps the physical d-pad through the N64 analog stick when `input_mode=joystick`), plus the Brick's R2+ABXY C-button remap by physical position.
- **GLideN64-standalone.patch** — Thin shim that wires GLideN64 into the shared `emu_frontend` overlay module. All custom features (overlay menu, power button handling, shortcuts, rewind, cheats, save/load, screenshot, game switcher) live in `overlay/emu_frontend.c` and are compiled into the plugin via the CMakeLists sources list. Also contains the EGL/GLES runtime glue, the tg5050 libpng16 static link, and the cross-compilation toolchain file.
- **mupen64plus-video-rice.patch** — Wires the Rice video plugin into the same `emu_frontend` module as GLideN64 so every custom feature works regardless of which video plugin is active. Adds the overlay sources to Rice's Makefile and hooks `emu_frontend_frame` into `UpdateScreen`.

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
│   ├── mupen64plus-video-GLideN64.so   GLideN64 video plugin
│   ├── mupen64plus-video-rice.so       Rice video plugin
│   ├── default.cfg                     base config (patched at runtime)
│   ├── overlay_settings.json           overlay menu config
│   ├── mupen64plus.ini                 ROM database (GoodName lookups)
│   ├── RiceVideoLinux.ini              Rice per-ROM rendering hints
│   ├── InputAutoCfg.ini                input auto-config
│   ├── mupencheat.txt                  cheat codes
│   ├── libpng16.so.16                  libpng runtime
│   └── libz.so.1                       zlib runtime (libpng16 dep)
└── tg5050/                            TrimUI Smart Pro S
    └── (same files, built with tg5050 toolchain)
```

## Button mapping

### Physical controls by device

| Control | Brick | Smart Pro | Smart Pro S |
|---------|:-----:|:---------:|:-----------:|
| D-pad | Yes | Yes | Yes |
| A, B, X, Y | Yes | Yes | Yes |
| L1, R1 | Yes | Yes | Yes |
| L2, R2 | Yes | Yes | Yes |
| Start, Select, Menu | Yes | Yes | Yes |
| Left analog stick | — | Yes | Yes |
| Right analog stick | — | Yes | Yes |
| L3 (left stick click) | — | — | Yes |
| R3 (right stick click) | — | — | Yes |
| Power | Yes | Yes | Yes |

### N64 controller mapping

| N64 Button | Smart Pro / Smart Pro S | Brick (no analog sticks) |
|------------|----------------------|--------------------------|
| A | A | A |
| B | B | B |
| Start | Start | Start |
| Z Trigger | L2 (analog) | L2 (analog) |
| L | L1 | L1 |
| R | R1 | R1 |
| Analog Stick | Left analog stick | D-pad (see Input Mode below) |
| C-Up | Right analog up | R2 + X (top) |
| C-Down | Right analog down / Y | R2 + B (bottom) |
| C-Left | Right analog left / X | R2 + Y (left) |
| C-Right | Right analog right | R2 + A (right) |
| D-Pad | D-pad (hat) | D-pad (see Input Mode below) |

### Per-game input mode

Because the Brick has no analog stick, the physical d-pad has to stand in for one of the two N64 directional inputs. The **Input Mode** setting decides which:

- **Joystick** (default for most games) — the physical d-pad routes through the N64 analog stick. The N64 d-pad is inactive.
- **D-Pad** — the physical d-pad passes through as the N64 d-pad (the config-mapped hat). The N64 analog stick is inactive.

The setting is **per-ROM**: each game gets its own file at `$DEVICE_CONFIG_DIR/per-game/<rom>.cfg` containing `input_mode=joystick` or `input_mode=dpad`. On first launch the default is chosen by substring-matching the ROM's GoodName (resolved by mupen64plus-core from `mupen64plus.ini` by CRC/MD5) against a hardcoded list in `overlay/emu_frontend.c` — the following games default to **D-Pad**:

Kirby 64: The Crystal Shards, Mischief Makers, Tetris 64, Tetrisphere, Ms. Pac-Man - Maze Madness, Mortal Kombat 4, Mortal Kombat Trilogy, Killer Instinct Gold, Pokémon Puzzle League, WWF No Mercy, ClayFighter 63⅓, ClayFighter - Sculptor's Cut, WWF WarZone.

All other games default to **Joystick**. Change it live via the overlay menu's **Input → Input Mode** item, or by binding **Shortcuts → Toggle Input Mode** to any face/shoulder button — both write through to the per-game file and the input plugin picks up the change within a frame (stat-mtime polling).

### Brick-specific C-button remap

The Brick has no right analog stick either, so C-buttons are accessed via **R2 + ABXY**: hold R2 and press a face button to send a C-button based on the physical position (A=right, B=bottom, X=top, Y=left). Without R2 held, X and Y still map to C-Left and C-Down as normal.

### Overlay menu

| Action | Button |
|--------|--------|
| Open / close | Menu |
| Navigate | D-pad |
| Confirm | A |
| Back | B |
| Page left | L1 |
| Page right | R1 |

### Power button

| Action | Input |
|--------|-------|
| Sleep (screen off, audio mute) | Short press (< 1s) |
| Power off (exit + shutdown) | Long press (≥ 1s) |

After 2 minutes in sleep, the device suspends to RAM. Press power again to wake.

### Overlay menu sections

The overlay menu is defined in `config/shared/overlay_settings.json` and currently exposes:

- **Audio** — SDL resampler quality (`trivial` / `src-linear` / `src-sinc-fastest`).
- **Core** — Video plugin selector (GLideN64 / Rice — requires a restart, persisted to `[NextUI] VideoPlugin`), CPU overclock multiplier, frame skip, cheats enable.
- **Debug** — Show FPS, show stats, show D-list count, etc. (GLideN64-only items are hidden when Rice is active and vice versa.)
- **Frame Buffer**, **Hi-Res Textures**, **Performance**, **Rendering**, **Texture Enhancement** — plugin-specific items. Tagged with `"plugin": "gliden64"` or `"plugin": "rice"` so only the relevant ones appear.
- **Gamma Correction** — gamma level.
- **Input** — per-game Input Mode (Joystick / D-Pad, see above).
- **Shortcuts** — button bindings for fast forward, state save/load, reset, screenshot, game switcher, turbo per face/shoulder button, rewind, aspect cycle, toggle input mode.
- **Cheats** — dynamic list from `mupencheat.txt` for the current ROM.

Settings persist to `mupen64plus.cfg` (in the appropriate plugin section) and are applied on the next relevant restart. Items tagged `"per_game": true` in the JSON (currently only `input_mode`) bypass `mupen64plus.cfg` and persist to per-ROM files instead — see [Per-game input mode](#per-game-input-mode) above.

### CPU mode

The overlay menu's **Performance → CPU Mode** toggle controls the kernel CPU governor:

| Mode | Governor | Min Freq | Max Freq |
|------|----------|----------|----------|
| Powersave | `powersave` | 408 MHz | 408 MHz |
| Ondemand (default) | `ondemand` | 1.2 GHz | 1.8 GHz |
| Performance | `performance` | Platform max | Platform max |

Applied immediately when changed, persists to the config file, and re-applied automatically on each launch.

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
- **tg5050**: Uses `ghcr.io/loveretro/tg5050-toolchain:latest`. The toolchain has broken libpng header symlinks — the Makefile automatically downloads libpng 1.6.37 headers as a workaround. Also bundles `libpng16.so.16` and `libz.so.1` (from the tg5050 sysroot) in both platform dirs because the tg5040 device ships zlib 1.2.8, which is too old for the `ZLIB_1.2.9` symbols referenced by libpng16.
- **GLideN64**: Built once using the tg5040 toolchain. The resulting `.so` is shared across both platforms.
- **Rice**: Built per-toolchain (one `.so` per platform) because it links against the platform-specific libpng. The overlay sources are injected into its Makefile by `patches/shared/mupen64plus-video-rice.patch`.
