#ifndef EMU_FRONTEND_H
#define EMU_FRONTEND_H

#include <stdbool.h>
#include <SDL2/SDL.h>
#include "emu_overlay.h"
#include "emu_overlay_cfg.h"
#include "emu_overlay_render.h"

// mupen64plus command constants (stable API — avoids m64p_types.h dependency)
#define EMU_FE_CMD_STOP              1
#define EMU_FE_CMD_STATE_SAVE        5
#define EMU_FE_CMD_STATE_LOAD        6
#define EMU_FE_CMD_STATE_SET_SLOT   11
#define EMU_FE_CMD_RESET             9
#define EMU_FE_CMD_TAKE_SCREENSHOT  12
#define EMU_FE_CMD_CORE_STATE_SET   13
#define EMU_FE_CMD_ROM_GET_HEADER   14

#define EMU_FE_CORE_SPEED_FACTOR     1

// Generic function pointer types matching mupen64plus core API
typedef int (*emu_fe_core_cmd_fn)(int cmd, int param1, void* param2);
typedef int (*emu_fe_add_cheat_fn)(const char* name, void* codes, int count);
typedef int (*emu_fe_cheat_enabled_fn)(const char* name, int enabled);

// Plugin-provided operations (filled by each video plugin)
typedef struct {
	void (*swap_buffers)(void);
	void (*cycle_aspect)(void);
	EmuOvlRenderBackend* (*get_render)(void);
	void (*exec_on_video_thread)(void (*fn)(void));
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

// Frame skip value (owned by emu_frontend, read by GLideN64 RSP.cpp via extern)
extern int g_frameSkip;

#endif
