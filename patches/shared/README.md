# Patches

These patches are applied to the freshly-cloned upstream sources during `make patch`. They are regenerated from the modified source trees via `make patches` — never edit them by hand (unified diff `@@` hunk headers are fragile).

## mupen64plus-core.patch

**Target**: `src/mupen64plus-core/` (upstream tag 2.6.0)

Adds ROM-filename-based save naming so save files match NextUI's conventions:

- Adds a `romfilename[256]` field to `ROM_PARAMS` and a new API command `M64CMD_SET_ROM_FILENAME` that the frontend calls with the ROM's basename (without path or extension).
- Adds `SaveFilenameFormat` config option: when set to `2`, save files (`.sra`, `.eep`, `.fla`, `.mpk`, `.st*`) use `romfilename` instead of the internal ROM name or CRC. This produces stable, human-readable filenames like `Super Mario 64.sra`.
- Exports `ROM_PARAMS` in the linker version script (`api_export.ver`) so the frontend can write `romfilename` via dlsym after `dlopen(RTLD_GLOBAL)`.

## mupen64plus-ui-console.patch

**Target**: `src/mupen64plus-ui-console/` (upstream tag 2.6.0)

Three changes to the command-line frontend:

1. **`RTLD_GLOBAL` for `dlopen()`**: changes `osal_dynamiclib_unix.c` from `RTLD_NOW` to `RTLD_NOW | RTLD_GLOBAL` so that GLES/EGL symbols exported by the core library are visible to video plugins. Without this, GLideN64 and Rice fail to resolve GL function pointers on TrimUI's PowerVR/Mali drivers.

2. **ROM filename passthrough**: after loading the ROM, extracts the basename (without path or extension) from the command-line filepath and calls `CoreDoCommand(M64CMD_SET_ROM_FILENAME, ...)` so the core's save-naming logic (from the core patch above) uses the ROM's actual filename.

3. **`--cachedir` flag**: resolves `ConfigOverrideUserPaths` via dlsym from the core library and adds a `--cachedir (dir)` command-line option that calls `ConfigOverrideUserPaths(NULL, dir)` to set the user cache directory (shader cache, texture cache). This avoids the default `$HOME/.cache/mupen64plus/` fallback.

## mupen64plus-audio-sdl.patch

**Target**: `src/mupen64plus-audio-sdl/` (upstream tag 2.6.0)

Empty placeholder — pulled from the nx-redux build system at `make clone` time. The audio plugin is built from unmodified upstream source. The patch file exists so the `make patch` / `make patches` machinery has a consistent target for all components.

## mupen64plus-input-sdl.patch

**Target**: `src/mupen64plus-input-sdl/` (upstream tag 2.6.0)

Brick-specific input remapping, gated on `$DEVICE=brick` at runtime (Smart Pro and Smart Pro S are unaffected):

1. **Per-game d-pad ↔ joystick mode**: reads the per-game config file at `$EMU_INPUT_MODE_FILE` (managed by `emu_frontend.c` in the overlay) on every `GetKeys()` call via `stat()` mtime caching. When the file contains `input_mode=joystick`, the physical d-pad (SDL hat 0) is routed through the N64 analog stick (`X_AXIS`/`Y_AXIS` set to ±80) and the N64 d-pad bits are cleared. When `input_mode=dpad` (or file missing), the default hat→d-pad config mapping is left intact. This lets the user toggle d-pad vs joystick mode live via the overlay menu or a shortcut, with the input plugin picking up changes within a single frame.

2. **R2 + ABXY → C-buttons**: when SDL axis 5 (R2 trigger) is positive, face buttons are remapped to C-buttons by physical position: A (right) → C-Right, B (bottom) → C-Down, X (top) → C-Up, Y (left) → C-Left. The original A/B button bits are cleared so both actions don't fire simultaneously. This compensates for the Brick's lack of a right analog stick.

Both blocks are wrapped in a `static int is_brick` check that reads `getenv("DEVICE")` once; on non-Brick devices the entire block is skipped.

## GLideN64-standalone.patch

**Target**: `src/GLideN64/` (upstream commit c8ef81c)

Wires GLideN64 into the shared `emu_frontend` overlay module so all custom TrimUI features work when GLideN64 is the active video plugin. The patch is large but structurally thin — most of the logic lives in the vendored `overlay/*.c` sources, not in GLideN64 code itself.

**What it modifies in GLideN64**:

- **`CMakeLists.txt`**: adds the overlay source files (`emu_overlay.c`, `emu_overlay_cfg.c`, `emu_overlay_sdl.c`, `emu_frontend.c`, `cJSON.c`) to the build, links SDL2_ttf and SDL2_image, adds EGL/`-ldl` for dynamic GL loading, and sets up include paths for the overlay headers and GLES/KHR platform headers.
- **`src/DisplayWindow.cpp`** (the plugin's main render loop): reduced to a thin shim that fills `EmuFrontendPluginOps` (swap_buffers, cycle_aspect, get_render, exec_on_video_thread) and calls `emu_frontend_init()` + `emu_frontend_frame()` from `swapBuffers()`. All custom feature logic that previously lived here was extracted to `overlay/emu_frontend.c` in earlier refactoring commits.
- **`src/mupenplus/MupenPlusAPIImpl.cpp`**: resolves `CoreDoCommand`, `CoreAddCheat`, `CoreCheatEnabled` via dlsym at plugin startup for the cheat and save-state systems.
- **`src/RSP.cpp`**: reads the `extern int g_frameSkip` variable (owned by `emu_frontend.c`) to implement adaptive frame skip.
- **`src/Graphics/OpenGLContext/` files**: patches for PowerVR GE8300 compatibility (EGL via dlopen, `glBufferSubData` instead of `glMapBufferRange`, `eglGetProcAddress` via dlsym).
- **`toolchain-aarch64.cmake`**: cross-compilation toolchain file for the Docker build.

**What it adds (new files)**:

- `src/overlay/` directory containing the overlay SDL render backend (`emu_overlay_sdl.c`) — though this is actually a symlink/copy from `overlay/` in the repo root, added to the GLideN64 source tree so CMake can find it.
- Platform-specific libpng headers (`png.h`, `pngconf.h`, `pnglibconf.h`) matching the tg5050 sysroot's libpng 1.6.43.

## mupen64plus-video-rice.patch

**Target**: `src/mupen64plus-video-rice/` (upstream tag 2.6.0)

Wires the Rice video plugin into the same `emu_frontend` overlay module as GLideN64, so every custom feature (overlay menu, power button, shortcuts, rewind, cheats, save/load, screenshot, game switcher) works identically regardless of which video plugin is active.

**What it modifies in Rice**:

- **`projects/unix/Makefile`**: adds the overlay source files as build targets (`OVERLAY_DIR = ../../../../overlay`), includes the overlay and cJSON header paths, and links SDL2_ttf and SDL2_image.
- **`src/Video.cpp`**: includes `emu_frontend.h` (via `extern "C"`), adds four static `rice_*` plugin-op callback functions, adds `ensure_frontend_init()` that fills `EmuFrontendCoreAPI` + `EmuFrontendPluginOps` and calls `emu_frontend_init()`, and calls `emu_frontend_frame(windowSetting.uDisplayWidth, windowSetting.uDisplayHeight)` at the end of `UpdateScreen()`.

Rice's plugin ops are simpler than GLideN64's because Rice is single-threaded:
- `rice_exec_on_video_thread(fn, ctx)` just calls `fn(ctx)` directly (no thread dispatch needed).
- `rice_swap_buffers()` calls `CoreVideo_GL_SwapBuffers()`.
- `rice_get_render()` returns the SDL overlay backend.
- `rice_cycle_aspect()` is a no-op (Rice reads aspect from VI registers).

The patch also resolves `CoreDoCommand`, `CoreAddCheat`, and `CoreCheatEnabled` via dlsym in `PluginStartup()` for the cheat and save-state systems.
