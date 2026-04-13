# trimui-mupen64plus

Standalone mupen64plus built from upstream sources with custom overlay menu integration for TrimUI devices (tg5040 and tg5050).

## Prerequisites

- Docker (for cross-compilation toolchains)
- Git
- curl (for libpng headers download)

## Quick start

```sh
make clean build dist
```

This clones upstream repos, applies patches, builds for both platforms sequentially, and assembles `dist/N64.pak/`.

## Build targets

| Target | Description |
|--------|-------------|
| `make build` | Clone, patch, build core + all plugins for both platforms |
| `make all` | Assemble `dist/` for both platforms (assumes artifacts are already built) |
| `make clone` | Clone upstream repos into `src/` |
| `make patch` | Apply patches from `patches/shared/` |
| `make tg5040` | Build core + audio/input/rsp plugins for tg5040 |
| `make tg5050` | Build core + audio/input/rsp plugins for tg5050 |
| `make gliden64` | Build GLideN64 video plugin (shared across platforms) |
| `make rice-tg5040` / `make rice-tg5050` | Build Rice video plugin per-toolchain |
| `make patches` | Regenerate `patches/shared/*.patch` from the current source trees |
| `make dist` | Assemble `dist/N64.pak/` from current build outputs |
| `make clean` | Remove `src/`, `dist/`, `include/`, and generated `mupen64plus-audio-sdl.patch` |

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

| Purpose | Mechanism | Path on Brick |
|---|---|---|
| User config | `--configdir` | `.userdata/tg5040/N64-mupen64plus/brick/` |
| Shared data (ROM DB, INI) | `--datadir` | `Emus/tg5040/N64.pak/tg5040/` |
| Plugins | `--plugindir` | `Emus/tg5040/N64.pak/tg5040/` |
| SRAM / battery saves | `--set "Core[SaveSRAMPath]=..."` | `/mnt/SDCARD/Saves/N64/` |
| Save states | `--set "Core[SaveStatePath]=..."` | `.userdata/shared/N64-mupen64plus/` |
| Screenshots | `--sshotdir` | `/mnt/SDCARD/Screenshots/` |
| User cache (shaders, textures) | `--cachedir` (patched into ui-console) | `.userdata/tg5040/N64-mupen64plus/brick/cache/` |
| User data | `XDG_DATA_HOME` env var | `.userdata/tg5040/N64-mupen64plus/brick/` |

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
│   ├── 7zzs                            7-Zip standalone (for .zip/.7z ROMs)
│   ├── 7zzs.LICENSE                    7-Zip license
│   ├── pak.json                        pak metadata
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

On Smart Pro and Smart Pro S both the left analog stick *and* the d-pad work independently and simultaneously — the config maps SDL axis 0/1 to the N64 analog and SDL hat 0 to the N64 d-pad, and the Brick-specific remap below is gated on `$DEVICE=brick` so it never touches those devices.

### Per-game input mode (Brick only)

Because the Brick has no analog stick, the physical d-pad has to stand in for one of the two N64 directional inputs. The **Input Mode** setting decides which:

- **Joystick** (default for most games) — the physical d-pad routes through the N64 analog stick. The N64 d-pad is inactive.
- **D-Pad** — the physical d-pad passes through as the N64 d-pad (the config-mapped hat). The N64 analog stick is inactive.

Smart Pro and Smart Pro S both have a real left analog stick, so this remap is disabled on them — `emu_frontend.c` gates the d-pad remap on `$DEVICE=brick` via trimui_inputd flag files at `/tmp/trimui_inputd/`. The **Input → Input Mode** overlay menu item is still visible on those devices but toggling it is a no-op.

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

The overlay menu's **Performance → CPU Mode** toggle controls the kernel CPU governor:

| Mode | Governor | Min Freq | Max Freq |
|------|----------|----------|----------|
| Powersave | `powersave` | 408 MHz | 408 MHz |
| Ondemand | `ondemand` | 1.2 GHz | 1.8 GHz |
| Performance (default) | `performance` | Platform max | Platform max |
| Auto | Resolves to Performance | *(same as Performance)* | *(same as Performance)* |

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
- **tg5050**: Uses `ghcr.io/loveretro/tg5050-toolchain:latest`. The toolchain has broken libpng header symlinks — the Makefile automatically downloads libpng 1.6.37 headers as a workaround. Also bundles `libpng16.so.16` and `libz.so.1` (from the tg5050 sysroot) in both platform dirs because the tg5040 device ships zlib 1.2.8, which is too old for the `ZLIB_1.2.9` symbols referenced by libpng16.
- **GLideN64**: Built once using the tg5040 toolchain. The resulting `.so` is shared across both platforms.
- **Rice**: Built per-toolchain (one `.so` per platform) because it links against the platform-specific libpng. The overlay sources are injected into its Makefile by `patches/shared/mupen64plus-video-rice.patch`.
