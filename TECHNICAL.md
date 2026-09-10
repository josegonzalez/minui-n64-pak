# minui-mupen64plus

Standalone mupen64plus built from upstream sources with custom overlay menu integration for TrimUI (`tg5040`, `tg5050`), Miyoo (`my355`) and Anbernic H700 (`h700`) devices.

## Prerequisites

- Docker (for cross-compilation toolchains)
- Git
- curl (for libpng headers download)

## Quick start

```sh
make clean build dist
```

This clones upstream repos, applies patches, builds each platform sequentially, and assembles `dist/N64.pak/`.

## Build targets

| Target | Description |
|--------|-------------|
| `make build` | Clone, patch, build core + all plugins for every platform |
| `make all` | Assemble `dist/` for every platform (assumes artifacts are already built) |
| `make clone` | Clone upstream repos into `src/` |
| `make patch` | Apply patches from `patches/shared/` |
| `make tg5040` | Build core + audio/input/rsp plugins for tg5040 |
| `make tg5050` | Build core + audio/input/rsp plugins for tg5050 |
| `make my355` | Build core + audio/input/rsp plugins for my355 |
| `make h700` | Build core + audio/input/rsp plugins for h700 |
| `make gliden64` | Build GLideN64 video plugin (shared across platforms) |
| `make rice-<platform>` | Build Rice video plugin per-toolchain |
| `make ini-<platform>` | Cross-compile the `ini` CLI helper per-toolchain |
| `make stage-<platform>` | Collect one platform's artifacts into `build/<platform>/` |
| `make dist-<platform>` | Assemble `dist/N64.pak/<platform>/` |
| `make print-<VAR>` | Print any make variable; used by `tests/makefile.bats` |
| `make patches` | Regenerate `patches/shared/*.patch` from the current source trees |
| `make dist` | Assemble `dist/N64.pak/` from current build outputs |
| `make clean` | Remove `src/`, `dist/`, `include/`, and generated `mupen64plus-audio-sdl.patch` |

Every platform has the same target family, so `<platform>` above is one of `tg5040`,
`tg5050`, `my355` or `h700` — the same list `pak.json` declares.

### Building a single platform

```sh
make clone patch
make tg5040
make dist-tg5040
```

## Tests

Two suites, both host-only — no toolchain, no Docker, no cloned upstream tree:

```sh
make -C tools/ini test   # C unit tests for the ini CLI helper
bats tests/              # shell tests
```

`tests/platform.bats` unit-tests `n64_platform_profile` (see [Platform profile](#platform-profile)) across every platform and device variant. `tests/makefile.bats` asserts the per-platform build wiring by introspecting the Makefile through `make print-<VAR>`; several of its cases walk `pak.json`'s platform list, so a platform added there without its build targets fails the suite. CI runs both on every pull request.

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

## ROM formats

Raw ROMs (`.z64`, `.n64`, `.v64`, `.rom`) are passed directly to mupen64plus.

Archived ROMs (`.zip`, `.7z`) are extracted to a tmpfs scratch directory (`/tmp/m64p_extracted.*`) at launch time using a bundled statically-linked [7-Zip](https://www.7-zip.org/) binary (`7zzs`, v26.00). `launch.sh` picks the first `.z64`/`.n64`/`.v64`/`.rom` file in the archive (or the first regular file if none match) and renames it to the archive's basename so that mupen64plus-ui-console's save-name derivation produces the same result as a raw ROM — e.g. `Zelda.zip` and `Zelda.z64` both save to `Zelda.srm`. The scratch directory is cleaned up on exit via an `EXIT/INT/TERM/HUP/QUIT` trap. All overlay metadata (per-game Input Mode file, screenshot previews, game-switcher auto-resume) uses the *original* archive filename so settings persist across runs.

The 7-Zip binary ships alongside the plugins and is downloaded + sha256-verified from `github.com/ip7z/7zip` during `make clone`. Its license (`7zzs.LICENSE`, LGPL / unRAR) sits next to the binary in each platform dir.

## Patches

All patches live in `patches/shared/`. See [`patches/shared/README.md`](patches/shared/README.md) for detailed descriptions of what each patch modifies and why.

## Save states

Save and Load are on the Quick Menu's main screen. When either is highlighted, d-pad left/right cycles through **8 slots** and a preview panel appears on the right half of the screen showing the slot's screenshot (or "Empty Slot" if unused). Pressing A immediately saves or loads the visible slot and closes the menu. This matches NextUI's minarch save-state UX — no separate slot-picker screen.

Slot screenshots are stored as BMP files at `$SHARED_USERDATA_PATH/.minui/N64/<rom>.<slot>.bmp` and are loaded when the menu opens.

## Data paths

All paths are set via CLI flags or `--set` on the mupen64plus command line — `launch.sh` does not `sed` the config file for these.

| Purpose | Mechanism | Example path (Brick) |
|---|---|---|
| User config | `--configdir` | `.userdata/tg5040/N64-mupen64plus/brick/` |
| Shared data (ROM DB, INI) | `--datadir` | `Emus/tg5040/N64.pak/tg5040/` |
| Plugins | `--plugindir` | `Emus/tg5040/N64.pak/tg5040/` |
| SRAM / battery saves | `--set "Core[SaveSRAMPath]=..."` | `/mnt/SDCARD/Saves/N64/` |
| Save states | `--set "Core[SaveStatePath]=..."` | `.userdata/shared/N64-mupen64plus/` |
| Screenshots | `--sshotdir` | `/mnt/SDCARD/Screenshots/` |
| User cache (shaders, textures) | `--cachedir` (patched into ui-console) | `.userdata/tg5040/N64-mupen64plus/brick/cache/` |
| User data | `XDG_DATA_HOME` env var | `.userdata/tg5040/N64-mupen64plus/brick/` |

## Platform profile

Every per-platform and per-device fact lives in one function, `n64_platform_profile` in `config/shared/platform.sh`, which `launch.sh` sources at startup and calls once with `$PLATFORM` and `$DEVICE`. It does no I/O — it reads only those two arguments plus `$SDL_VIDEO_EGL_DRIVER` — so it can be unit tested without a device.

It sets the following, and everything downstream in `launch.sh` reads them rather than switching on the platform again:

| Variable | Purpose |
|---|---|
| `PROFILE_CPUFREQ_PATH` | cpufreq directory to save, set and restore |
| `PROFILE_ONLINE_CPUS` | CPU numbers to bring online |
| `PROFILE_GPU_GOVERNOR_GLOB` | GPU devfreq governor path or glob; empty where the platform exposes none |
| `PROFILE_RESOLUTION` | `WxH` passed to `--resolution` |
| `PROFILE_ANISOTROPY` | device default for GLideN64 anisotropic filtering |
| `PROFILE_CONFIG_SUBDIR` | per-device subdirectory under the userdata dir; empty on single-variant platforms |
| `PROFILE_LEGACY_SUBDIR` | name under `$LEGACY_USERDATA_DIR/config/` for the migration block |
| `PROFILE_MAIN_MASK` / `PROFILE_HELPER_MASK` / `PROFILE_VIDEO_MASK` | taskset masks |
| `PROFILE_SWAPFILE` | swapfile path; empty skips swap entirely |
| `PROFILE_LD_EXTRA_DIRS` | extra loader directories for the mupen64plus invocation |
| `PROFILE_LD_PRELOAD` | EGL library to preload |

`platform.sh` ships in the pak root next to `launch.sh`.

### Swap

`launch.sh` builds a 512 MB swapfile to back hi-res texture loading. It lives on `/mnt/UDISK` on the TrimUI and Miyoo devices. H700 has no equivalent: its SD card is FAT, which cannot host a swapfile, and its stock Ubuntu rootfs is too small to give up half a gigabyte. `PROFILE_SWAPFILE` is therefore empty on `h700` and the whole block is skipped.

## Dist layout

```
dist/N64.pak/
├── launch.sh                          shared launch script (uses $PLATFORM)
├── platform.sh                        per-platform/device profile sourced by launch.sh
├── tg5040/                            TrimUI Brick / Brick Pro / Smart Pro
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
│   ├── ini                             INI get/merge helper used by launch.sh
│   ├── 7zzs                            7-Zip standalone (for .zip/.7z ROMs)
│   ├── 7zzs.LICENSE                    7-Zip license
│   ├── pak.json                        pak metadata
│   ├── libpng16.so.16                  libpng runtime
│   └── libz.so.1                       zlib runtime (libpng16 dep)
├── tg5050/                            TrimUI Smart Pro S
│   └── (same files, built with tg5050 toolchain)
├── my355/                             Miyoo Flip
│   └── (same files, built with my355 toolchain; no libpng16, it is linked statically)
└── h700/                              Anbernic H700 handhelds
    └── (same files, built with h700 toolchain)
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

The Brick Pro, the Miyoo Flip and the eleven H700 models differ from each other in whether
they carry analog sticks, but the pak does not branch on that. The remaps described below
are gated on `$DEVICE` matching `brick` exactly, so every other device — Brick Pro included
— uses the stock mapping: the d-pad drives the N64 d-pad, and C-buttons come from the right
analog stick where one exists. On a stickless device that is not the Brick, C-buttons need a
manual binding under Options → Shortcuts.

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

On every device with a real left analog stick both that stick *and* the d-pad work independently and simultaneously — the config maps SDL axis 0/1 to the N64 analog and SDL hat 0 to the N64 d-pad, and the Brick-specific remap below is gated on `$DEVICE=brick` so it never touches them.

### Per-game input mode (Brick only)

Because the Brick has no analog stick, the physical d-pad has to stand in for one of the two N64 directional inputs. The **Input Mode** setting decides which:

- **Joystick** (default for most games) — the physical d-pad routes through the N64 analog stick. The N64 d-pad is inactive.
- **D-Pad** — the physical d-pad passes through as the N64 d-pad (the config-mapped hat). The N64 analog stick is inactive.

Every other device is left alone — `emu_frontend.c` gates the d-pad remap on `$DEVICE=brick` via trimui_inputd flag files at `/tmp/trimui_inputd/`. The **Input → Input Mode** overlay menu item is still visible elsewhere but toggling it is a no-op. Note that this includes the Brick Pro and the stickless H700 models, which therefore have no d-pad↔joystick switch and no R2 + face button C-buttons.

On the Brick, the setting is **per-ROM**: each game gets its own file at `$DEVICE_CONFIG_DIR/per-game/<rom>.cfg` containing `input_mode=joystick` or `input_mode=dpad`. On first launch the default is chosen by substring-matching the ROM's GoodName (resolved by mupen64plus-core from `mupen64plus.ini` by CRC/MD5) against a hardcoded list in `overlay/emu_frontend.c` — the following games default to **D-Pad**:

Kirby 64: The Crystal Shards, Hoshi no Kirby 64, Mischief Makers, Tetris 64, Tetrisphere, Ms. Pac-Man - Maze Madness, Mortal Kombat 4, Mortal Kombat Trilogy, Killer Instinct Gold, Pokémon Puzzle League, WWF No Mercy, ClayFighter 63⅓, ClayFighter - Sculptor's Cut, WWF WarZone.

All other games default to **Joystick**. Change it live via the overlay menu's **Input → Input Mode** item, or by binding **Shortcuts → Toggle Input Mode** to any face/shoulder button — both write through to the per-game file and the input plugin picks up the change within a frame (stat-mtime polling).

### Brick-specific C-button remap

The Brick has no right analog stick either, so C-buttons are accessed via **R2 + ABXY**: hold R2 and press a face button to send a C-button based on the physical position (A=right, B=bottom, X=top, Y=left). Without R2 held, X and Y still map to C-Left and C-Down as normal. This remap is also gated on `$DEVICE=brick`; Smart Pro / Smart Pro S use their real right analog stick for C-buttons via the `axis(3±,24000)` mappings in `default.cfg`.

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

### Overlay menu layout

Scale, padding and rows-per-page are chosen from the screen dimensions rather than the platform name, because the Brick and Smart Pro share `tg5040` but not a resolution. `emu_ovl_init()` in `overlay/emu_overlay.c` gives 1024x768 a 3x scale with five rows, any panel 480 pixels tall or shorter a 2x scale with five rows, and everything else a 2x scale with eight rows. The height test covers both the 640x480 devices and the 720x480 H700 models; `list_page_size()` drops one further row at runtime when the description strip would not otherwise fit.

### Overlay menu sections

The overlay menu is defined in `config/shared/overlay_settings.json`. Items tagged `"plugin": "gliden64"` or `"plugin": "rice"` are only visible when the corresponding video plugin is active; untagged items always appear. The **Save Changes** entry at the bottom of the Options list lets users persist settings globally or per-game (see [Save scope](#save-scope) below).

#### Shared settings (visible with either video plugin)

| Section | Setting | Notes |
|---|---|---|
| Audio | Resampling | Trivial / Zero-Order Hold / Linear / Sinc Fast / Sinc Medium / Sinc Best (restart required) |
| Core | Video Plugin | Rice (default) / GLideN64 (restart required) |
| Core | CPU Overclock | Off / 2× / 4× / 8× (restart required) |
| Input | Input Mode | Joystick / D-Pad (Brick only, see [Per-game input mode](#per-game-input-mode-brick-only)) |
| Performance | CPU Mode | Powersave / Ondemand / Performance / Auto (applied on-demand) |
| Performance | Rewind Buffer | Off / Small / Medium / Large |
| Performance | Frame Skip | Off / 20fps / 25fps / 30fps (applied on-demand) |
| Shortcuts | *(19 items)* | Toggle/Hold FF, Reset, Quick Save/Load, Screenshot, Game Switcher, 8× Turbo, Cycle Aspect, Toggle/Hold Rewind, Toggle Input Mode |
| Cheats | *(dynamic)* | Loaded from `mupencheat.txt` for the current ROM |

#### GLideN64-only settings

| Section | Setting | Notes |
|---|---|---|
| Debug | Show FPS, Show VI/s, Show Speed % | Restart required |
| Dithering | Dithering Pattern, Quantization, RDRAM Dithering, Hi-Res Noise Dithering | |
| Frame Buffer | FB Emulation, Color to RDRAM, Depth to RDRAM, Color from RDRAM, N64 Depth Compare, Disable FB Info | |
| Gamma | Force Gamma, Gamma Level | |
| Hi-Res Textures | Enable Hi-Res, File Storage, Full Alpha Channel, Alt CRC, VRAM Limit | |
| Performance | Inaccurate Tex Coords, Legacy Blending, Shader Cache, Fragment Depth Write, Backgrounds Mode, Threaded Video | |
| Rendering | Resolution Factor, Aspect Ratio, FXAA, Multi-Sampling, Anisotropic Filtering, Bilinear Mode, Hybrid Filter, HW Lighting, LOD Emulation, Coverage, Clipping, Buffer Swap Mode | |
| Texture Enhancement | Filter Mode, Enhancement Mode, Deposterize, Ignore BG Textures, Texture Cache Size | |

#### Rice-only settings

| Section | Setting | Notes |
|---|---|---|
| Debug | Show FPS | Restart required |
| Frame Buffer | FB Setting, Render To Texture, Screen Update | |
| Hi-Res Textures | Load Hi-Res Textures, Hi-Res CRC Only | |
| Performance | Fast Texture Loading, Skip Frame, Accurate Texture Mapping | |
| Rendering | Aspect Ratio, Multi-Sampling, Anisotropic Filtering, Color Quality, Depth Buffer, Fog | |
| Texture Enhancement | Texture Enhancement, Force Texture Filter, Mipmapping, Texture Quality | |

#### Save scope

Settings follow NextUI's minarch save model: changes are applied on-demand in memory where possible but only persisted to disk when the user explicitly picks a target from **Options → Save Changes**:

- **Save for Console** — writes to `mupen64plus.cfg` (global, all games)
- **Save for Game** — writes to `per-game/<rom>.cfg` (this ROM only)
- **Restore Defaults** — deletes the currently-active scope's file and reverts to defaults

The scope indicator at the top of the Save Changes page shows `Using defaults.`, `Using console config.`, or `Using game config.`

### CPU mode

The overlay menu's **Performance → CPU Mode** toggle controls the kernel CPU governor. `apply_cpu_mode()` in `overlay/emu_frontend.c` picks the cpufreq node and the frequency table from `$PLATFORM`:

| Platform | cpufreq node | Powersave | Ondemand | Performance (default) |
|---|---|---|---|---|
| `tg5040` | `cpu0` | 408 MHz | 1.104 – 1.8 GHz | 1.608 – 2.0 GHz |
| `tg5050` | `cpu4` | 408 MHz | 1.2 – 1.8 GHz | 1.992 – 2.16 GHz |
| `my355` | `cpu0` | 408 MHz | 1.2 – 1.608 GHz | 1.8 – 1.992 GHz |
| `h700` | `cpu0` | 480 MHz | 1.008 – 1.512 GHz | 1.2 – 1.512 GHz |

**Auto** is not a separate mode — it resolves to Performance, since N64 emulation is demanding enough to want it. H700 uses 480 MHz for Powersave rather than 408 MHz because 408 MHz is not in its OPP table; its steps are 480, 720, 936, 1008, 1104, 1200, 1320, 1416 and 1512 MHz.

Applied immediately when changed. Persisted only via Options → Save Changes.

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
- **tg5050**: Uses `ghcr.io/loveretro/tg5050-toolchain:latest`. The toolchain has broken libpng header symlinks — the Makefile automatically downloads libpng 1.6.37 headers as a workaround. Also bundles `libpng16.so.16` and `libz.so.1` (from the tg5050 sysroot) in the tg5040, tg5050 and h700 dirs because the tg5040 device ships zlib 1.2.8, which is too old for the `ZLIB_1.2.9` symbols referenced by libpng16.
- **my355**: Uses `ghcr.io/loveretro/my355-toolchain:latest`. Cross-compiles libpng 1.6.37 from source and links it statically, so it bundles only `libz.so.1` (1.3.1, from its own sysroot).
- **h700**: Uses `ghcr.io/loveretro/h700-toolchain:latest`. That image is the tg5040 image plus a patched mali-fbdev SDL2 installed at `PREFIX_LOCAL=/opt/nextui` — same gcc 8.3 `aarch64-nextui-linux-gnu` cross compiler, same TrimUI TG5040 SDK sysroot, so no libpng workaround is needed. `scripts/docker-env.sh` detects that SDL2 and points `SDL_CFLAGS`/`SDL_LDLIBS` at it, because that is the build NextUI installs on the device at `$SYSTEM_PATH/lib`. GLES symbols resolve straight from `-lGLESv2` with no standalone mali blob.
- **GLideN64**: Built once using the tg5040 toolchain. The resulting `.so` is shared across every platform. It dlopens `libGLESv2.so.2` and `libEGL.so.1` at runtime rather than linking them.
- **Rice**: Built per-toolchain (one `.so` per platform) because it links against the platform-specific libpng. The overlay sources are injected into its Makefile by `patches/shared/mupen64plus-video-rice.patch`.

### Docker environment

Every `docker run` in the Makefile invokes `scripts/docker-env.sh`, which sets up the cross-compile environment inside the container and then execs the requested command. It is checked in rather than generated so it survives `make clean` and shows up in review.

Its one conditional is the h700 SDL2 lookup above: the toolchain's `sdl2.pc` records an absolute in-image prefix, so `PKG_CONFIG_SYSROOT_DIR` has to be cleared for that query or pkg-config rewrites every path under the sysroot. Toolchains that leave `$PREFIX_LOCAL` empty fall through to the sysroot unchanged. It logs which SDL2 it selected, and on `h700` a missing `$PREFIX_LOCAL/lib/pkgconfig/sdl2.pc` is a hard error — falling back to the SDK copy there would build cleanly but link against an SDL2 the device does not run.

### Shared source trees

All four platforms compile into the same `src/*/projects/unix` output paths, so each platform's recipes clear the previous platform's objects before building, and `make build` stages one platform fully before starting the next.
