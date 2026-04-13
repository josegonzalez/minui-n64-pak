# Glide64mk2 on TrimUI: Investigation Summary

This document records the investigation into adding mupen64plus-video-glide64mk2 as a third video plugin for TrimUI devices (PowerVR GE8300 / Mali-G57). The effort was ultimately unsuccessful due to a fundamental display presentation issue on PowerVR GE8300 that could not be resolved without an older gl4es build.

## The Core Problem

Glide64mk2's OGLES backend renders correctly to the GL backbuffer (confirmed via `glReadPixels`), but `eglSwapBuffers` (via `CoreVideo_GL_SwapBuffers` -> `SDL_GL_SwapWindow`) never makes the frame visible on the display. Rice and GLideN64 do not have this issue.

The old minui-n64-pak (josegonzalez/minui-n64-pak, main-old branch) shipped a working Glide64mk2 using an older gl4es build (~2MB) with an EGL wrapper (~26KB). This combination worked with that project's mupen64plus core but is incompatible with the current core build.

## Approaches Tried

### Approach 1: Config-only changes

| Change | Result |
|--------|--------|
| `wrpFBO = 0` (disable FBO-based HW framebuffer emulation) | Black screen persists |
| `M64P_GL_BUFFER_SIZE = 32` (32-bit color buffer instead of upstream 16) | Black screen persists |
| `M64P_GL_CONTEXT_PROFILE_ES` with GLES 2.0 context | Black screen persists |

### Approach 2: GPU-specific patches to Glitch64 OGLES backend

| Change | Result |
|--------|--------|
| `glBindFramebuffer(GL_FRAMEBUFFER, 0)` + `glColorMask(GL_TRUE, ...)` before swap | Black screen |
| `glBlitFramebuffer` from current FBO to FBO 0 | Black screen |
| `glUseProgram(0)` + unbind VBO/textures + disable scissor/depth before swap | Black screen |
| Draw transparent fullscreen quad before swap (trigger TBDR tile flush) | Black screen |
| `glCopyTexSubImage2D` (GPU-only texture copy from framebuffer) | Empty texture on PowerVR |
| `glFinish()` before swap | Black screen |
| Fix `gl_FragDepth` shader error (guard with `!defined(USE_GLES)`) | Shader error fixed, but black screen persists |

### Approach 3: glReadPixels passthrough compositor

Capture the rendered frame via `glReadPixels` and re-present through a simple textured-quad shader (the same pipeline the overlay menu uses successfully).

| Variant | Result |
|---------|--------|
| Passthrough on every VI interrupt (UpdateScreen) | Game visible, but alternating frame stutter (double-swap) |
| Skip native swap + passthrough on every VI | Game visible, stutter on frames with no new content |
| Flag-based: passthrough only when `newSwapBuffers` sets `s_newFrameReady` | Game visible, slight stutter in Zelda OoT, significant stutter in Mario Kart 64 |
| + `grFinish()` before readback | Significantly worse stutter |
| + Pre-allocated readback buffer (no malloc/free per frame) | Same as flag-based without grFinish |
| + Double-buffered PBO async readback (GLES 3.0) | Much worse performance (PBOs appear synchronous on PowerVR GE8300) |

**Conclusion**: The flag-based passthrough with pre-allocated buffer was the best achievable result, but the `glReadPixels` overhead (~3MB per frame at 1024x768) makes it too slow for games like Mario Kart 64.

### Approach 4: gl4es (GL-to-GLES translation library)

The old pak shipped gl4es `libGL.so.1` and `libEGL.so.1`. gl4es translates desktop OpenGL calls to GLES.

| Variant | Result |
|---------|--------|
| Build Glide64mk2 with desktop GL (no `USE_GLES`), link against gl4es | Segfault during first render call after `Video: initialized.` |
| `LD_PRELOAD` both `libGL.so.1` + `libEGL.so.1` (gl4es) | All shaders broken (gl4es intercepts GLES calls, rejects `#version 300 es`) |
| `LD_PRELOAD` only `libEGL.so.1` (gl4es EGL wrapper) | All shaders broken (EGL wrapper loads `libGL.so.1` as dependency, which intercepts GLES) |
| `LD_LIBRARY_PATH` with gl4es `libEGL.so.1` (no LD_PRELOAD) | gl4es not loaded (SDL does `dlopen("libEGL.so")` — unversioned — not matching our `libEGL.so.1`) |
| `LD_LIBRARY_PATH` with unversioned `libEGL.so` copy of gl4es | Hang: circular init (`libEGL.so` loads `libGL.so.1` which tries to load `libEGL.so` again) |
| Core patch to skip GLES context override when plugin sets profile | Freeze for all plugins (SDL_GL_GetAttribute returned stale value) |
| Core patch with dedicated flag (`l_PluginSetContextProfile`) | Freeze for all plugins (flag declaration was inside `#ifndef USE_GLES` guard, not visible in GLES builds) |
| Fixed flag declaration (outside `#ifndef USE_GLES`) + desktop GL build | Freeze: gl4es `libEGL.so` in `$BIN_DIR` shadows system EGL for all plugins |
| Old pak's pre-built gl4es binaries with our core | Segfault (incompatible with our core build) |
| gl4es `libEGL.so` in subdirectory, only in `LD_LIBRARY_PATH` for Glide64mk2 | Hang: same circular init when gl4es EGL finds gl4es GL in same directory |

**Conclusion**: gl4es v1.1.6 has a circular initialization dependency between `libEGL.so` and `libGL.so.1` that causes hangs. The old pak used an older gl4es build (~2MB vs 6.85MB) that didn't have this issue, but that version is unidentifiable and incompatible with our mupen64plus core.

### Approach 5: Overlay shader compatibility for gl4es

Added GLSL 1.20 fallback shaders (`attribute`/`varying` instead of `in`/`out`) to `overlay/emu_overlay_sdl.c` so the overlay works when gl4es is preloaded. This fixed the overlay but didn't help with Glide64mk2's own shaders being intercepted by gl4es.

## Root Cause Analysis

The PowerVR GE8300 GPU uses a tile-based deferred renderer (TBDR). Unlike immediate-mode GPUs, content rendered to the backbuffer isn't automatically available for `eglSwapBuffers` to present. The display controller requires specific conditions to flush tiles to the framebuffer:

1. Rice works because its rendering pipeline naturally leaves the GL state in a way the PowerVR TBDR expects
2. GLideN64 works because it was heavily patched for PowerVR compatibility (EGL via dlopen, `glBufferSubData` fallback, depth buffer workarounds)
3. Glide64mk2's Glitch64 OGLES backend leaves GL state (shader programs, VAOs, VBOs, scissor/depth tests) that prevents the PowerVR TBDR from flushing tiles during `eglSwapBuffers`

The overlay's textured-quad draw succeeds because it uses a minimal shader pipeline that the PowerVR driver handles correctly for presentation.

## What Would Be Needed

To ship Glide64mk2 without the `glReadPixels` overhead, one of:

1. **An older gl4es build** that doesn't have the circular `libEGL.so` / `libGL.so.1` init issue. The old pak's binary works but is incompatible with our core. Building from the correct commit (unknown) with a compatible core would be needed.

2. **A native OGLES fix** in the Glitch64 backend that makes `eglSwapBuffers` present correctly on PowerVR. This would likely require understanding exactly what GL state the PowerVR TBDR needs to see before swap — potentially by reverse-engineering the PowerVR driver's swap implementation or finding PowerVR-specific documentation.

3. **A different display path** that bypasses `eglSwapBuffers` entirely (e.g., using DRM/KMS directly, or a custom EGL implementation that handles PowerVR's TBDR quirks).
