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
	void (*swap_buffers)(void);
	void (*cycle_aspect)(void);
	EmuOvlRenderBackend* (*get_render)(void);
	void (*exec_on_video_thread)(void (*fn)(void));
	// Called before M64CMD_STOP so plugin can run cleanup (e.g. turbo files, rewind buffer).
	// Temporary — will become unnecessary once all cleanup lives in emu_frontend.
	void (*on_pre_stop)(void);
} EmuFrontendPluginOps;

// Core API pointers (set during init)
typedef struct {
	emu_fe_core_cmd_fn core_cmd;
	emu_fe_add_cheat_fn add_cheat;
	emu_fe_cheat_enabled_fn cheat_enabled;
} EmuFrontendCoreAPI;

// Initialize the frontend module. Called once by the video plugin.
void emu_frontend_init(EmuFrontendCoreAPI* api, EmuFrontendPluginOps* ops);

// Called every frame from the video plugin's render loop.
void emu_frontend_frame(void);

// Cleanup (called on exit)
void emu_frontend_cleanup(void);

// Shared joystick handle (managed by emu_frontend)
SDL_Joystick* emu_frontend_get_joystick(void);

// Set overlay config pointer (called by plugin after loading config)
void emu_frontend_set_config(EmuOvlConfig* cfg);

// Set overlay reference for save-slot screenshots + auto-wires cheat callbacks.
// Called by plugin after overlay init.
void emu_frontend_set_overlay(EmuOvl* ovl, bool* initialized);

// Load cheats from mupencheat.txt for the current ROM (called after config load)
void emu_frontend_load_cheats(void);

// Current save/load slot (shared with DisplayWindow overlay menu action handler)
int emu_frontend_get_current_slot(void);
void emu_frontend_set_current_slot(int slot);

// Shortcut system (button state tracking + config lookup)
void emu_frontend_update_buttons(void);
int emu_frontend_get_shortcut(const char* key);
bool emu_frontend_btn_just_pressed(int b);
bool emu_frontend_btn_is_held(int b);

// Fast forward state (for rewind mutual exclusion)
bool emu_frontend_is_fast_forward(void);
bool emu_frontend_is_ff_toggled(void);
void emu_frontend_set_fast_forward(bool enable);

// Frame skip value (owned by emu_frontend, read by GLideN64 RSP.cpp via extern)
extern int g_frameSkip;

#endif
