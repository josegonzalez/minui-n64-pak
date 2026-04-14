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

// Button state tracking (called every frame)
void emu_frontend_update_buttons(void);

// Shortcut binding (25 remappable shortcuts — same capture/modifier model as controls)
#define SHORTCUT_COUNT 25
typedef struct {
	const char* key;       // config key: "shortcut_toggle_ff", etc.
	const char* label;     // display name: "Toggle Fast Forward", etc.
	int physical;          // SDL button index (-1 = unbound)
	int is_axis;           // 0 = button, 1 = axis
	int axis_dir;          // +1 or -1 for axes
	int mod;               // modifier: 0=none, 8=MENU, 6=SELECT, -3=L2, -6=R2
} ShortcutBinding;

// Get the shortcuts array (owned by emu_frontend)
ShortcutBinding* emu_frontend_get_shortcuts(void);

// Get human-readable label for a shortcut (e.g., "R1", "MENU+A")
const char* emu_frontend_shortcut_label(const ShortcutBinding* s);

// Check if a shortcut was just activated (button pressed + modifier held)
bool emu_frontend_shortcut_just_pressed(const ShortcutBinding* s);

// Check if a shortcut's button is currently held (+ modifier)
bool emu_frontend_shortcut_is_held(const ShortcutBinding* s);

// Frame skip value (owned by emu_frontend, read by GLideN64 RSP.cpp via extern)
extern int g_frameSkip;

// Analog sensitivity modifier (owned by ui-console main.c, written by emu_frontend)
// 0 = 100% (default), 25/50/75 = output percentage
extern int g_analogSensitivity;

// N64 button mapping (10 remappable action buttons)
#define N64_REMAP_COUNT 10
typedef struct {
	const char* name;       // display name: "A Button", "Z Trig", etc.
	const char* cfg_key;    // mupen64plus.cfg key in [Input-SDL-Control1]
	unsigned int n64_bit;   // N64 button bit in controller.buttons.Value
	int physical;           // SDL button index, or encoded axis (-1 = unbound)
	int is_axis;            // 0 = button, 1 = axis
	int axis_dir;           // +1 or -1 for axes
	int mod;                // modifier: 0=none, button index for MENU/SELECT/etc
	int default_physical;   // factory default physical
	int default_is_axis;
	int default_axis_dir;
} N64ButtonMapping;

// Get the current button mappings array (owned by emu_frontend)
N64ButtonMapping* emu_frontend_get_button_mappings(void);

// Write current mappings to the runtime file for input-sdl to pick up
void emu_frontend_write_button_map_file(void);

// Get human-readable label for a mapping (e.g., "R1", "MENU+A", "L2 axis")
const char* emu_frontend_binding_label(const N64ButtonMapping* m);

#endif
