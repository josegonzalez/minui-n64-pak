#ifndef EMU_FRONTEND_H
#define EMU_FRONTEND_H

#include <stdbool.h>
#include <SDL2/SDL.h>
#include "emu_overlay.h"
#include "emu_overlay_cfg.h"
#include "emu_overlay_render.h"

// Generic function pointer types matching mupen64plus core API
// (command constants live in emu_frontend.c via m64p_types.h)
typedef int (*emu_fe_core_cmd_fn)(int cmd, int param1, void* param2);
typedef int (*emu_fe_add_cheat_fn)(const char* name, void* codes, int count);
typedef int (*emu_fe_cheat_enabled_fn)(const char* name, int enabled);

// Plugin-provided operations (filled by each video plugin)
typedef struct {
	// Present current frame. Called from the menu loop after each overlay render.
	void (*swap_buffers)(void);

	// Cycle aspect ratio. Plugin updates its internal state AND writes the new
	// value back to the overlay config so the menu reflects it.
	void (*cycle_aspect)(void);

	// Returns the overlay render backend the plugin wants to use.
	EmuOvlRenderBackend* (*get_render)(void);

	// Dispatch `fn(ctx)` on the video/GL thread (blocking). For non-threaded
	// plugins, this can just call `fn(ctx)` directly. GLideN64 uses its
	// OverlayCallbackCommand + executeOverlayCommand path.
	void (*exec_on_video_thread)(void (*fn)(void* ctx), void* ctx);
} EmuFrontendPluginOps;

// Core API pointers (set during init)
typedef struct {
	emu_fe_core_cmd_fn core_cmd;
	emu_fe_add_cheat_fn add_cheat;
	emu_fe_cheat_enabled_fn cheat_enabled;
} EmuFrontendCoreAPI;

// Initialize the frontend module. Called once by the video plugin.
void emu_frontend_init(EmuFrontendCoreAPI* api, EmuFrontendPluginOps* ops);

// Called every frame from the video plugin's render loop. w/h are current
// screen dimensions (used for overlay GL init on first open).
void emu_frontend_frame(int w, int h);

// Cleanup (called on exit paths — turbo files, rewind buffer)
void emu_frontend_cleanup(void);

// Shared joystick handle (managed by emu_frontend)
SDL_Joystick* emu_frontend_get_joystick(void);

// Get the overlay config owned by emu_frontend (for plugin callbacks that need
// to write back to the menu state, e.g. aspect ratio cycling).
EmuOvlConfig* emu_frontend_get_overlay_config(void);

// Shortcut system (button state tracking + config lookup)
void emu_frontend_update_buttons(void);
int emu_frontend_get_shortcut(const char* key);
bool emu_frontend_btn_just_pressed(int b);
bool emu_frontend_btn_is_held(int b);

// Frame skip value (owned by emu_frontend, read by GLideN64 RSP.cpp via extern)
extern int g_frameSkip;

#endif
