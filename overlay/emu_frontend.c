#include "emu_frontend.h"
#include "m64p_types.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <SDL2/SDL.h>

// Frame skip: owned here, read by GLideN64 RSP.cpp via extern
int g_frameSkip = 0;

// Forward declarations for scope-aware save system
static const char* get_per_game_path(void);
static EmuConfigScope compute_scope(void);
static void handle_save_for_console(void);
static void handle_save_for_game(void);
static void handle_restore_defaults(void);

// Core API and plugin ops (set by emu_frontend_init)
static EmuFrontendCoreAPI s_coreAPI;
static EmuFrontendPluginOps s_pluginOps;
static bool s_initialized = false;

// Joystick (managed by emu_frontend for power button + input polling)
static SDL_Joystick* s_joy = NULL;

// ---------------------------------------------------------------------------
// Overlay state
// ---------------------------------------------------------------------------

static EmuOvl s_overlay;
static EmuOvlConfig s_overlayConfig;
static bool s_overlayInitialized = false;
static bool s_overlayConfigLoaded = false;
static bool s_overlayConfigFailed = false;
static char s_overlayJsonPath[512] = "";
static char s_overlayIniPath[512] = "";
static bool s_menuBtnPrev = false;
static Uint8 s_prevHat = 0;
static Uint32 s_prevButtons = 0;

// ---------------------------------------------------------------------------
// CPU mode (switchable via overlay menu)
// ---------------------------------------------------------------------------

static void apply_cpu_mode(int mode) {
	// Detect platform: try tg5050 cpu4 path first, fall back to tg5040 cpu0
	const char* cpu_path = "/sys/devices/system/cpu/cpu4/cpufreq";
	FILE* f = fopen("/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor", "r");
	int is_tg5050 = (f != NULL);
	if (f) fclose(f);
	if (!is_tg5050) cpu_path = "/sys/devices/system/cpu/cpu0/cpufreq";

	// Auto (3) = Performance for N64 (CPU demands are high enough)
	if (mode == 3) mode = 2;

	char path[256];
	if (mode == 0) { // Powersave
		snprintf(path, sizeof(path), "%s/scaling_governor", cpu_path);
		f = fopen(path, "w"); if (f) { fprintf(f, "powersave"); fclose(f); }
		snprintf(path, sizeof(path), "%s/scaling_min_freq", cpu_path);
		f = fopen(path, "w"); if (f) { fprintf(f, "408000"); fclose(f); }
		snprintf(path, sizeof(path), "%s/scaling_max_freq", cpu_path);
		f = fopen(path, "w"); if (f) { fprintf(f, "408000"); fclose(f); }
	} else if (mode == 1) { // Ondemand
		snprintf(path, sizeof(path), "%s/scaling_governor", cpu_path);
		f = fopen(path, "w"); if (f) { fprintf(f, "ondemand"); fclose(f); }
		snprintf(path, sizeof(path), "%s/scaling_min_freq", cpu_path);
		f = fopen(path, "w"); if (f) { fprintf(f, "1200000"); fclose(f); }
		snprintf(path, sizeof(path), "%s/scaling_max_freq", cpu_path);
		f = fopen(path, "w"); if (f) { fprintf(f, "1800000"); fclose(f); }
	} else { // Performance (2) or Auto (3, remapped above)
		snprintf(path, sizeof(path), "%s/scaling_governor", cpu_path);
		f = fopen(path, "w"); if (f) { fprintf(f, "performance"); fclose(f); }
		if (is_tg5050) {
			snprintf(path, sizeof(path), "%s/scaling_min_freq", cpu_path);
			f = fopen(path, "w"); if (f) { fprintf(f, "1992000"); fclose(f); }
			snprintf(path, sizeof(path), "%s/scaling_max_freq", cpu_path);
			f = fopen(path, "w"); if (f) { fprintf(f, "2160000"); fclose(f); }
		} else {
			snprintf(path, sizeof(path), "%s/scaling_min_freq", cpu_path);
			f = fopen(path, "w"); if (f) { fprintf(f, "1608000"); fclose(f); }
			snprintf(path, sizeof(path), "%s/scaling_max_freq", cpu_path);
			f = fopen(path, "w"); if (f) { fprintf(f, "2000000"); fclose(f); }
		}
	}
}

static int find_cpu_mode_value(EmuOvlConfig* cfg) {
	for (int s = 0; s < cfg->section_count; s++)
		for (int i = 0; i < cfg->sections[s].item_count; i++)
			if (strcmp(cfg->sections[s].items[i].key, "cpu_mode") == 0)
				return cfg->sections[s].items[i].current_value;
	return -1;
}

static void apply_cpu_mode_if_dirty(EmuOvlConfig* cfg) {
	for (int s = 0; s < cfg->section_count; s++)
		for (int i = 0; i < cfg->sections[s].item_count; i++)
			if (strcmp(cfg->sections[s].items[i].key, "cpu_mode") == 0 &&
			    cfg->sections[s].items[i].dirty) {
				apply_cpu_mode(cfg->sections[s].items[i].staged_value);
				return;
			}
}

// ---------------------------------------------------------------------------
// Frame skip (configurable via overlay menu)
// ---------------------------------------------------------------------------

static int find_frame_skip_value(EmuOvlConfig* cfg) {
	for (int s = 0; s < cfg->section_count; s++)
		for (int i = 0; i < cfg->sections[s].item_count; i++)
			if (strcmp(cfg->sections[s].items[i].key, "frame_skip") == 0)
				return cfg->sections[s].items[i].current_value;
	return -1;
}

static void apply_frame_skip_if_dirty(EmuOvlConfig* cfg) {
	for (int s = 0; s < cfg->section_count; s++)
		for (int i = 0; i < cfg->sections[s].item_count; i++)
			if (strcmp(cfg->sections[s].items[i].key, "frame_skip") == 0 &&
			    cfg->sections[s].items[i].dirty) {
				g_frameSkip = cfg->sections[s].items[i].staged_value;
				return;
			}
}

// ---------------------------------------------------------------------------
// Audio quality (maps numeric overlay value to RESAMPLE string in INI)
// ---------------------------------------------------------------------------

static void apply_audio_quality_if_dirty(EmuOvlConfig* cfg) {
	for (int s = 0; s < cfg->section_count; s++)
		for (int i = 0; i < cfg->sections[s].item_count; i++)
			if (strcmp(cfg->sections[s].items[i].key, "audio_quality") == 0 &&
			    cfg->sections[s].items[i].dirty) {
				const char* resample;
				switch (cfg->sections[s].items[i].staged_value) {
					case 0:  resample = "trivial"; break;
					case 1:  resample = "src-linear"; break;
					default: resample = "src-sinc-fastest"; break;
				}
				if (s_overlayIniPath[0] != '\0') {
					FILE* f = fopen(s_overlayIniPath, "r");
					if (!f) return;
					fseek(f, 0, SEEK_END);
					long sz = ftell(f);
					fseek(f, 0, SEEK_SET);
					char* buf = (char*)malloc(sz + 1);
					if (!buf) { fclose(f); return; }
					fread(buf, 1, sz, f);
					buf[sz] = '\0';
					fclose(f);
					char* p = strstr(buf, "RESAMPLE = ");
					if (p) {
						char* eol = strchr(p, '\n');
						if (!eol) eol = buf + sz;
						char newline[128];
						snprintf(newline, sizeof(newline), "RESAMPLE = \"%s\"", resample);
						long before = p - buf;
						long after_len = sz - (eol - buf);
						long new_sz = before + (long)strlen(newline) + after_len;
						char* out = (char*)malloc(new_sz + 1);
						if (out) {
							memcpy(out, buf, before);
							memcpy(out + before, newline, strlen(newline));
							memcpy(out + before + strlen(newline), eol, after_len);
							out[new_sz] = '\0';
							f = fopen(s_overlayIniPath, "w");
							if (f) {
								fwrite(out, 1, new_sz, f);
								fclose(f);
							}
							free(out);
						}
					}
					free(buf);
				}
				return;
			}
}

// ---------------------------------------------------------------------------
// Input mode (d-pad vs joystick) — Brick only. Uses trimui_inputd flag files
// at /tmp/trimui_inputd/ to remap the physical d-pad to virtual analog axes
// at the kernel input layer. This is cleaner than our old input-sdl patch
// approach: the daemon gives proper proportional axis values, and there's
// zero per-frame overhead in the emulator process.
//
// The per-game default is chosen by matching the ROM's GoodName against the
// list below. The user can toggle at runtime via the overlay menu or shortcut.
// ---------------------------------------------------------------------------

// Games that default to d-pad input on first run. Matched as a case-insensitive
// substring against the GoodName resolved by mupen64plus-core's ROM database
// (src/mupen64plus-core/data/mupen64plus.ini). Substrings chosen to catch all
// regional/revision variants ((U)/(E)/(J) and [!], [b1], [t1], etc.) while
// staying distinctive enough to avoid false positives.
static const char* const INPUT_DPAD_DEFAULT_GAMES[] = {
	"Kirby 64 - The Crystal Shards",
	"Hoshi no Kirby 64",
	"Mischief Makers",
	"Tetris 64",
	"Tetrisphere",
	"Ms. Pac-Man - Maze Madness",
	"Mortal Kombat 4",
	"Mortal Kombat Trilogy",
	"Killer Instinct Gold",
	"Pokemon Puzzle League",
	"WWF No Mercy",
	"Clay Fighter 63 1-3",
	"Clay Fighter - Sculptor's Cut",
	"WWF - War Zone",
};

static bool strcasestr_match(const char* hay, const char* needle) {
	if (!hay || !needle) return false;
	size_t nlen = strlen(needle);
	for (; *hay; hay++) {
		if (strncasecmp(hay, needle, nlen) == 0)
			return true;
	}
	return false;
}

// Returns 1 if the current ROM's GoodName matches the d-pad default list.
// Retrieves the GoodName via M64CMD_ROM_GET_SETTINGS, which queries the
// mupen64plus-core ROM database by CRC/MD5 (see core/src/main/rom.c).
static int dpad_default_for_current_rom(void) {
	if (!s_coreAPI.core_cmd) return 0;
	m64p_rom_settings settings;
	memset(&settings, 0, sizeof(settings));
	if (s_coreAPI.core_cmd(M64CMD_ROM_GET_SETTINGS, sizeof(settings), &settings) != 0)
		return 0;
	for (size_t i = 0; i < sizeof(INPUT_DPAD_DEFAULT_GAMES) / sizeof(INPUT_DPAD_DEFAULT_GAMES[0]); i++) {
		if (strcasestr_match(settings.goodname, INPUT_DPAD_DEFAULT_GAMES[i]))
			return 1;
	}
	return 0;
}

// Apply input mode via trimui_inputd flag files. The daemon polls
// /tmp/trimui_inputd/ and remaps d-pad to virtual analog at the kernel level.
// mode 0 = joystick (d-pad → analog stick), mode 1 = dpad (passthrough).
static void apply_input_mode(int mode) {
	const char* d = getenv("DEVICE");
	if (!d || strcmp(d, "brick") != 0) return; // Brick-only

	if (mode == 0) {
		// Joystick: d-pad becomes analog stick
		mkdir("/tmp/trimui_inputd", 0755);
		int fd = open("/tmp/trimui_inputd/input_dpad_to_joystick", O_CREAT | O_WRONLY, 0644);
		if (fd >= 0) close(fd);
		fd = open("/tmp/trimui_inputd/input_no_dpad", O_CREAT | O_WRONLY, 0644);
		if (fd >= 0) close(fd);
	} else {
		// D-pad: passthrough (remove flag files)
		unlink("/tmp/trimui_inputd/input_dpad_to_joystick");
		unlink("/tmp/trimui_inputd/input_no_dpad");
	}
}

// Read the per-game input_mode from the per-game config file.
// Returns 1 for dpad, 0 for joystick, -1 if file missing.
static int read_input_mode_file(void) {
	const char* path = get_per_game_path();
	if (!path || path[0] == '\0') return -1;
	FILE* f = fopen(path, "r");
	if (!f) return -1;
	char line[128];
	int value = -1;
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, "input_mode=", 11) == 0) {
			value = (strncmp(line + 11, "dpad", 4) == 0) ? 1 : 0;
			break;
		}
	}
	fclose(f);
	return value;
}

// Write input_mode to the per-game config file.
static void write_input_mode_file(int value) {
	const char* path = get_per_game_path();
	if (!path || path[0] == '\0') return;
	FILE* f = fopen(path, "w");
	if (!f) return;
	fprintf(f, "input_mode=%s\n", value ? "dpad" : "joystick");
	fclose(f);
}

// Find the input_mode item in the config (returns NULL if not present).
static EmuOvlItem* find_input_mode_item(EmuOvlConfig* cfg) {
	for (int s = 0; s < cfg->section_count; s++)
		for (int i = 0; i < cfg->sections[s].item_count; i++)
			if (strcmp(cfg->sections[s].items[i].key, "input_mode") == 0)
				return &cfg->sections[s].items[i];
	return NULL;
}

// Load the per-game input mode into the overlay item and apply it via
// trimui_inputd. On first launch for a ROM, seeds the default from the
// GoodName auto-detect list. On non-Brick devices, early-returns (the
// feature is Brick-only since those devices have real analog sticks).
static void load_input_mode_from_file(EmuOvlConfig* cfg) {
	EmuOvlItem* item = find_input_mode_item(cfg);
	if (!item) return;
	const char* d = getenv("DEVICE");
	if (!d || strcmp(d, "brick") != 0) return;
	int v = read_input_mode_file();
	if (v < 0) {
		v = dpad_default_for_current_rom();
		write_input_mode_file(v);
	}
	item->current_value = v;
	item->staged_value = v;
	item->dirty = false;
	apply_input_mode(v);
}

// If the input_mode item is dirty (user changed it in the overlay menu),
// apply via trimui_inputd and persist to the per-game file.
static void apply_input_mode_if_dirty(EmuOvlConfig* cfg) {
	EmuOvlItem* item = find_input_mode_item(cfg);
	if (!item || !item->dirty) return;
	const char* d = getenv("DEVICE");
	if (!d || strcmp(d, "brick") != 0) {
		item->dirty = false;
		return;
	}
	apply_input_mode(item->staged_value);
	write_input_mode_file(item->staged_value);
	item->current_value = item->staged_value;
	item->dirty = false;
}

// Shortcut: toggle input mode. Applies via trimui_inputd and persists.
static void process_input_mode_shortcut(void) {
	int btn = emu_frontend_get_shortcut("shortcut_toggle_input_mode");
	if (!emu_frontend_btn_just_pressed(btn))
		return;
	const char* d = getenv("DEVICE");
	if (!d || strcmp(d, "brick") != 0) return;
	int cur = read_input_mode_file();
	if (cur < 0) cur = 0;
	int new_value = cur ? 0 : 1;
	apply_input_mode(new_value);
	write_input_mode_file(new_value);
	if (s_overlayConfigLoaded) {
		EmuOvlItem* item = find_input_mode_item(&s_overlayConfig);
		if (item) {
			item->current_value = new_value;
			item->staged_value = new_value;
			item->dirty = false;
		}
	}
}

// ---------------------------------------------------------------------------
// Turbo buttons (via platform trimui_inputd daemon)
// ---------------------------------------------------------------------------

static void toggle_turbo_file(const char* name) {
	char path[128];
	snprintf(path, sizeof(path), "/tmp/trimui_inputd/turbo_%s", name);
	if (access(path, F_OK) == 0) {
		unlink(path);
	} else {
		mkdir("/tmp/trimui_inputd", 0755);
		int fd = open(path, O_CREAT | O_WRONLY, 0644);
		if (fd >= 0) close(fd);
	}
}

static void clear_turbo_files(void) {
	const char* names[] = {"a","b","x","y","l","l2","r","r2"};
	for (int i = 0; i < 8; i++) {
		char path[128];
		snprintf(path, sizeof(path), "/tmp/trimui_inputd/turbo_%s", names[i]);
		unlink(path);
	}
}

// ---------------------------------------------------------------------------
// Power button / sleep handling
// ---------------------------------------------------------------------------

#define POWER_BUTTON 102
#define DISP_LCD_SET_BRIGHTNESS 0x102
#define DEEP_SLEEP_TIMEOUT_MS 120000

static bool s_powerBtnPrev = false;
static uint32_t s_powerPressedAt = 0;

static void set_backlight(int brightness) {
	// tg5050: standard sysfs
	FILE* f = fopen("/sys/class/backlight/backlight0/brightness", "w");
	if (f) { fprintf(f, "%d", brightness); fclose(f); return; }
	// tg5040: Allwinner /dev/disp ioctl
	int fd = open("/dev/disp", O_RDWR);
	if (fd >= 0) {
		unsigned long param[4] = {0, (unsigned long)brightness, 0, 0};
		ioctl(fd, DISP_LCD_SET_BRIGHTNESS, &param);
		close(fd);
	}
}

static int read_backlight(void) {
	FILE* f = fopen("/sys/class/backlight/backlight0/brightness", "r");
	if (f) { int v = 0; if (fscanf(f, "%d", &v) == 1) { fclose(f); return v; } fclose(f); }
	return 200; // tg5040 default (no sysfs read path)
}

// Returns: 0 = nothing, 1 = short press (sleep), 2 = long press (poweroff)
static int check_power_button(void) {
	SDL_PumpEvents();
	const Uint8* keys = SDL_GetKeyboardState(NULL);
	bool kbPressed = keys && keys[POWER_BUTTON];
	bool joyPressed = s_joy && SDL_JoystickGetButton(s_joy, POWER_BUTTON) != 0;
	bool pressed = kbPressed || joyPressed;
	bool justPressed = pressed && !s_powerBtnPrev;
	bool justReleased = !pressed && s_powerBtnPrev;
	s_powerBtnPrev = pressed;

	if (justPressed)
		s_powerPressedAt = SDL_GetTicks();

	if (pressed && s_powerPressedAt && SDL_GetTicks() - s_powerPressedAt >= 1000) {
		s_powerPressedAt = 0;
		return 2; // poweroff
	}
	if (justReleased && s_powerPressedAt) {
		s_powerPressedAt = 0;
		return 1; // sleep
	}
	return 0;
}

static void handle_sleep(void) {
	// Auto-save state to slot 9 for NextUI game switcher resume
	if (s_coreAPI.core_cmd) {
		s_coreAPI.core_cmd(M64CMD_STATE_SET_SLOT, 9, NULL);
		s_coreAPI.core_cmd(M64CMD_STATE_SAVE, 0, NULL);
	}
	// Write auto_resume.txt with relative ROM path so game switcher can resume
	const char* rom_path = getenv("EMU_ROM_PATH");
	if (rom_path) {
		FILE* f = fopen("/mnt/SDCARD/.userdata/shared/.minui/auto_resume.txt", "w");
		if (f) { fprintf(f, "%s", rom_path); fclose(f); }
	}

	// Finalize game time tracking session (sleep time shouldn't count as play time)
	system("command -v gametimectl.elf >/dev/null 2>&1 && gametimectl.elf stop_all");

	// Enter sleep: pause audio, mute speaker, blank backlight
	SDL_PauseAudio(1);
	system("echo 1 > /sys/class/speaker/mute 2>/dev/null");
	int saved_brightness = read_backlight();
	set_backlight(0);

	// Wait for wake: poll power button every 200ms
	uint32_t sleep_start = SDL_GetTicks();
	bool woken = false;
	while (!woken) {
		SDL_Delay(200);
		SDL_PumpEvents();
		SDL_JoystickUpdate();
		const Uint8* keys = SDL_GetKeyboardState(NULL);
		bool pwrPressed = (keys && keys[POWER_BUTTON]) ||
		                  (s_joy && SDL_JoystickGetButton(s_joy, POWER_BUTTON));
		if (pwrPressed) {
			do {
				SDL_Delay(50);
				SDL_PumpEvents();
				SDL_JoystickUpdate();
				keys = SDL_GetKeyboardState(NULL);
				pwrPressed = (keys && keys[POWER_BUTTON]) ||
				             (s_joy && SDL_JoystickGetButton(s_joy, POWER_BUTTON));
			} while (pwrPressed);
			woken = true;
			break;
		}
		// Deep sleep after timeout: suspend to RAM
		if (SDL_GetTicks() - sleep_start >= DEEP_SLEEP_TIMEOUT_MS) {
			int fd = open("/sys/power/state", O_WRONLY);
			if (fd >= 0) {
				write(fd, "mem", 3);
				close(fd);
			}
			sleep_start = SDL_GetTicks();
		}
	}

	// Exit sleep: restore backlight, unmute, resume audio
	set_backlight(saved_brightness);
	system("echo 0 > /sys/class/speaker/mute 2>/dev/null");
	SDL_PauseAudio(0);

	// Resume game time tracking session
	system("command -v gametimectl.elf >/dev/null 2>&1 && gametimectl.elf resume");

	// Clear auto-resume marker since user resumed in-session
	unlink("/mnt/SDCARD/.userdata/shared/.minui/auto_resume.txt");

	// Reset edge detection so we don't immediately re-trigger
	s_powerBtnPrev = false;
	s_powerPressedAt = 0;
}

// ---------------------------------------------------------------------------
// Shortcut system (button state tracking + config lookup)
// ---------------------------------------------------------------------------

static int s_currentSlot = 0;
static uint32_t s_btnState = 0;
static uint32_t s_btnPrev = 0;

void emu_frontend_update_buttons(void) {
	s_btnPrev = s_btnState;
	s_btnState = 0;
	if (!s_joy) return;
	for (int b = 0; b <= 10; b++)
		if (SDL_JoystickGetButton(s_joy, b))
			s_btnState |= (1u << b);
}

int emu_frontend_get_shortcut(const char* key) {
	if (!s_overlayConfigLoaded) return -1;
	for (int s = 0; s < s_overlayConfig.section_count; s++)
		for (int i = 0; i < s_overlayConfig.sections[s].item_count; i++)
			if (strcmp(s_overlayConfig.sections[s].items[i].key, key) == 0)
				return s_overlayConfig.sections[s].items[i].current_value;
	return -1;
}

bool emu_frontend_btn_just_pressed(int b) {
	if (b < 0) return false;
	uint32_t m = 1u << b;
	return (s_btnState & m) && !(s_btnPrev & m);
}

bool emu_frontend_btn_is_held(int b) {
	if (b < 0) return false;
	return (s_btnState & (1u << b)) != 0;
}

// ---------------------------------------------------------------------------
// Fast forward
// ---------------------------------------------------------------------------

static bool s_fastForward = false;
static bool s_ffToggledOn = false;
static bool s_ffHoldActive = false;

static void set_fast_forward(bool enable) {
	if (s_fastForward == enable) return;
	s_fastForward = enable;
	if (s_coreAPI.core_cmd) {
		int speed = enable ? 400 : 100;
		s_coreAPI.core_cmd(M64CMD_CORE_STATE_SET, M64CORE_SPEED_FACTOR, &speed);
	}
}

static void process_fast_forward(void) {
	int toggleBtn = emu_frontend_get_shortcut("shortcut_toggle_ff");
	int holdBtn = emu_frontend_get_shortcut("shortcut_hold_ff");

	if (emu_frontend_btn_just_pressed(toggleBtn)) {
		s_ffToggledOn = !s_ffToggledOn;
		set_fast_forward(s_ffToggledOn);
	}
	if (holdBtn >= 0) {
		if (emu_frontend_btn_is_held(holdBtn) && !s_ffHoldActive) {
			s_ffHoldActive = true;
			set_fast_forward(true);
		} else if (!emu_frontend_btn_is_held(holdBtn) && s_ffHoldActive) {
			s_ffHoldActive = false;
			set_fast_forward(s_ffToggledOn);
		}
	}
}

// ---------------------------------------------------------------------------
// Stop emulation (shared by poweroff and game switcher)
// ---------------------------------------------------------------------------

static void request_stop(void) {
	emu_frontend_cleanup();
	if (s_coreAPI.core_cmd)
		s_coreAPI.core_cmd(M64CMD_STOP, 0, NULL);
}

// ---------------------------------------------------------------------------
// Game switcher (save state + thumbnail + marker file + stop)
// ---------------------------------------------------------------------------

static void trigger_game_switcher(void) {
	if (s_coreAPI.core_cmd) {
		s_coreAPI.core_cmd(M64CMD_STATE_SET_SLOT, s_currentSlot, NULL);
		s_coreAPI.core_cmd(M64CMD_STATE_SAVE, 0, NULL);
	}
	if (s_overlayInitialized)
		emu_ovl_save_slot_screenshot(&s_overlay, s_currentSlot);
	// NextUI checks existence (not content) to show the game switcher screen
	FILE* f = fopen("/mnt/SDCARD/.userdata/shared/.minui/game_switcher.txt", "w");
	if (f) { fprintf(f, "unused"); fclose(f); }
	request_stop();
}

// ---------------------------------------------------------------------------
// Rewind (tmpfs ring buffer of save states)
// ---------------------------------------------------------------------------

#define REWIND_INTERVAL 30 // capture every 30 frames (~2/sec at 60fps)
// Slot counts per buffer size setting: Off=0, Small=10, Medium=30, Large=60
static const int REWIND_SLOT_COUNTS[] = {0, 10, 30, 60};

static int s_rewindSlots = 0;      // max slots (0 = disabled)
static int s_rewindHead = 0;       // next slot to write
static int s_rewindCount = 0;      // number of valid slots in ring
static int s_rewindFrame = 0;      // frame counter
static bool s_rewinding = false;
static bool s_rewindToggledOn = false;
static bool s_rewindHoldActive = false;
static bool s_rewindInitialized = false;

static void rewind_init(void) {
	if (s_rewindInitialized) return;
	system("mkdir -p /tmp/m64p_rewind");
	s_rewindInitialized = true;
}

static void rewind_cleanup(void) {
	system("rm -rf /tmp/m64p_rewind");
	s_rewindSlots = 0;
	s_rewindHead = 0;
	s_rewindCount = 0;
	s_rewindFrame = 0;
	s_rewinding = false;
	s_rewindToggledOn = false;
	s_rewindHoldActive = false;
	s_rewindInitialized = false;
}

static void rewind_update_config(void) {
	if (!s_overlayConfigLoaded) return;
	int bufSetting = 0;
	for (int s = 0; s < s_overlayConfig.section_count; s++)
		for (int i = 0; i < s_overlayConfig.sections[s].item_count; i++)
			if (strcmp(s_overlayConfig.sections[s].items[i].key, "rewind_buffer") == 0)
				bufSetting = s_overlayConfig.sections[s].items[i].current_value;
	if (bufSetting < 0 || bufSetting > 3) bufSetting = 0;
	int newSlots = REWIND_SLOT_COUNTS[bufSetting];
	if (newSlots != s_rewindSlots) {
		s_rewindSlots = newSlots;
		s_rewindHead = 0;
		s_rewindCount = 0;
		if (newSlots > 0) rewind_init();
	}
}

static void rewind_capture(void) {
	if (s_rewindSlots <= 0 || s_rewinding || !s_coreAPI.core_cmd) return;
	if (++s_rewindFrame < REWIND_INTERVAL) return;
	s_rewindFrame = 0;

	char path[64];
	snprintf(path, sizeof(path), "/tmp/m64p_rewind/%03d.st", s_rewindHead);
	s_coreAPI.core_cmd(M64CMD_STATE_SAVE, 1, (void*)path);
	s_rewindHead = (s_rewindHead + 1) % s_rewindSlots;
	if (s_rewindCount < s_rewindSlots) s_rewindCount++;
}

static void rewind_step_back(void) {
	if (s_rewindSlots <= 0 || s_rewindCount <= 0 || !s_coreAPI.core_cmd) return;
	s_rewindHead = (s_rewindHead - 1 + s_rewindSlots) % s_rewindSlots;
	s_rewindCount--;

	char path[64];
	snprintf(path, sizeof(path), "/tmp/m64p_rewind/%03d.st", s_rewindHead);
	s_coreAPI.core_cmd(M64CMD_STATE_LOAD, 0, (void*)path);
}

static void process_rewind(void) {
	rewind_update_config();
	int toggleBtn = emu_frontend_get_shortcut("shortcut_toggle_rewind");
	int holdBtn = emu_frontend_get_shortcut("shortcut_hold_rewind");

	if (emu_frontend_btn_just_pressed(toggleBtn)) {
		s_rewindToggledOn = !s_rewindToggledOn;
		s_rewinding = s_rewindToggledOn;
		if (s_rewinding && s_fastForward) set_fast_forward(false);
	}

	if (holdBtn >= 0) {
		if (emu_frontend_btn_is_held(holdBtn) && !s_rewindHoldActive) {
			s_rewindHoldActive = true;
			s_rewinding = true;
			if (s_fastForward) set_fast_forward(false);
		} else if (!emu_frontend_btn_is_held(holdBtn) && s_rewindHoldActive) {
			s_rewindHoldActive = false;
			s_rewinding = s_rewindToggledOn;
			if (!s_rewinding && s_ffToggledOn) set_fast_forward(true);
		}
	}

	// Restore FF when rewind not active
	if (!s_rewinding && !s_rewindHoldActive && s_ffToggledOn && !s_fastForward)
		set_fast_forward(true);

	if (s_rewinding) {
		rewind_step_back();
	} else {
		rewind_capture();
	}
}

// ---------------------------------------------------------------------------
// Cheat system (parses mupencheat.txt, registers cheats with the core)
// ---------------------------------------------------------------------------

#define MAX_CHEATS 64
#define MAX_CHEAT_CODES_PER 32
#define MAX_CHEAT_VARIANTS 16

typedef struct { uint32_t address; int value; } CheatCode;
typedef struct { int value; char label[64]; } CheatVariant;
typedef struct {
	char name[128];
	char description[256];
	CheatCode codes[MAX_CHEAT_CODES_PER];
	int num_codes;
	bool enabled;
	int variable_code_index;
	CheatVariant variants[MAX_CHEAT_VARIANTS];
	int variant_count;
	int selected_variant;
} CheatEntry;

static CheatEntry s_cheats[MAX_CHEATS];
static int s_cheatCount = 0;

// Expand any `\` character in src into ` - ` when writing into dst (clamped to dst_size).
// mupencheat.txt uses `\` as a hierarchy separator (e.g. "No Damage\Player 1").
static void expand_backslashes(char* dst, size_t dst_size, const char* src) {
	if (dst_size == 0) return;
	size_t di = 0;
	for (size_t si = 0; src[si] != '\0' && di + 1 < dst_size; si++) {
		if (src[si] == '\\') {
			const char* sep = " - ";
			for (int k = 0; sep[k] != '\0' && di + 1 < dst_size; k++)
				dst[di++] = sep[k];
		} else {
			dst[di++] = src[si];
		}
	}
	dst[di] = '\0';
}

static int cheat_compare(const void* a, const void* b) {
	const CheatEntry* ea = (const CheatEntry*)a;
	const CheatEntry* eb = (const CheatEntry*)b;
	return strcmp(ea->name, eb->name);
}

static void load_cheats(void) {
	if (!s_coreAPI.core_cmd) return;

	m64p_rom_header header;
	memset(&header, 0, sizeof(header));
	if (s_coreAPI.core_cmd(M64CMD_ROM_GET_HEADER, sizeof(header), &header) != M64ERR_SUCCESS)
		return;

	char romCrc[32];
	uint32_t crc1 = __builtin_bswap32(header.CRC1);
	uint32_t crc2 = __builtin_bswap32(header.CRC2);
	snprintf(romCrc, sizeof(romCrc), "%08X-%08X-C:%X", crc1, crc2, header.Country_code & 0xff);

	const char* jsonPath = getenv("EMU_OVERLAY_JSON");
	if (!jsonPath) return;
	char cheatPath[512];
	snprintf(cheatPath, sizeof(cheatPath), "%s", jsonPath);
	char* lastSlash = strrchr(cheatPath, '/');
	if (lastSlash) *lastSlash = '\0';
	strncat(cheatPath, "/mupencheat.txt", sizeof(cheatPath) - strlen(cheatPath) - 1);

	FILE* f = fopen(cheatPath, "r");
	if (!f) return;

	char line[1024];
	bool romFound = false;
	int curCheat = -1;
	s_cheatCount = 0;

	while (fgets(line, sizeof(line), f) && s_cheatCount < MAX_CHEATS) {
		int len = strlen(line);
		while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r' || line[len-1] == ' '))
			line[--len] = '\0';
		char* p = line;
		while (*p == ' ' || *p == '\t') p++;
		if (*p == '\0' || *p == '#' || (p[0] == '/' && p[1] == '/'))
			continue;

		if (strncmp(p, "crc ", 4) == 0) {
			if (romFound) break;
			if (strcmp(p + 4, romCrc) == 0) romFound = true;
			continue;
		}
		if (!romFound) continue;
		if (strncmp(p, "gn ", 3) == 0) continue;

		if (strncmp(p, "cd ", 3) == 0) {
			if (curCheat >= 0) {
				strncpy(s_cheats[curCheat].description, p + 3, 255);
				s_cheats[curCheat].description[255] = '\0';
			}
			continue;
		}

		if (strncmp(p, "cn ", 3) == 0) {
			curCheat = s_cheatCount++;
			strncpy(s_cheats[curCheat].name, p + 3, 127);
			s_cheats[curCheat].name[127] = '\0';
			s_cheats[curCheat].description[0] = '\0';
			s_cheats[curCheat].num_codes = 0;
			s_cheats[curCheat].enabled = false;
			s_cheats[curCheat].variable_code_index = -1;
			s_cheats[curCheat].variant_count = 0;
			s_cheats[curCheat].selected_variant = 0;
			continue;
		}

		if (curCheat >= 0 && s_cheats[curCheat].num_codes < MAX_CHEAT_CODES_PER) {
			uint32_t addr;
			if (sscanf(p, "%8X", &addr) == 1) {
				int ci = s_cheats[curCheat].num_codes;
				s_cheats[curCheat].codes[ci].address = addr;
				if (strlen(p) > 13 && strncmp(p + 9, "????", 4) == 0) {
					s_cheats[curCheat].variable_code_index = ci;
					s_cheats[curCheat].variant_count = 0;
					s_cheats[curCheat].selected_variant = 0;
					char* vp = p + 14;
					while (*vp == ' ') vp++;
					while (*vp && s_cheats[curCheat].variant_count < MAX_CHEAT_VARIANTS) {
						unsigned int vval;
						if (sscanf(vp, "%4X", &vval) != 1) break;
						vp += 4;
						int vi = s_cheats[curCheat].variant_count;
						s_cheats[curCheat].variants[vi].value = (int)vval;
						s_cheats[curCheat].variants[vi].label[0] = '\0';
						if (*vp == ':' && *(vp+1) == '"') {
							vp += 2;
							char* end = strchr(vp, '"');
							if (end) {
								int vlen = end - vp;
								if (vlen > 63) vlen = 63;
								strncpy(s_cheats[curCheat].variants[vi].label, vp, vlen);
								s_cheats[curCheat].variants[vi].label[vlen] = '\0';
								vp = end + 1;
							}
						}
						s_cheats[curCheat].variant_count++;
						if (*vp == ',') vp++;
						while (*vp == ' ') vp++;
					}
					s_cheats[curCheat].codes[ci].value =
						s_cheats[curCheat].variant_count > 0 ? s_cheats[curCheat].variants[0].value : 0;
				} else {
					unsigned int val = 0;
					sscanf(p + 9, "%4X", &val);
					s_cheats[curCheat].codes[ci].value = (int)val;
				}
				s_cheats[curCheat].num_codes++;
			}
		}
	}
	fclose(f);

	// Replace `\` hierarchy separators with ` - ` for all user-visible strings
	char buf[512];
	for (int i = 0; i < s_cheatCount; i++) {
		expand_backslashes(buf, sizeof(buf), s_cheats[i].name);
		strncpy(s_cheats[i].name, buf, sizeof(s_cheats[i].name) - 1);
		s_cheats[i].name[sizeof(s_cheats[i].name) - 1] = '\0';

		expand_backslashes(buf, sizeof(buf), s_cheats[i].description);
		strncpy(s_cheats[i].description, buf, sizeof(s_cheats[i].description) - 1);
		s_cheats[i].description[sizeof(s_cheats[i].description) - 1] = '\0';

		for (int v = 0; v < s_cheats[i].variant_count; v++) {
			expand_backslashes(buf, sizeof(buf), s_cheats[i].variants[v].label);
			strncpy(s_cheats[i].variants[v].label, buf, sizeof(s_cheats[i].variants[v].label) - 1);
			s_cheats[i].variants[v].label[sizeof(s_cheats[i].variants[v].label) - 1] = '\0';
		}
	}

	// Sort alphabetically by name so hierarchical cheats cluster together
	qsort(s_cheats, s_cheatCount, sizeof(CheatEntry), cheat_compare);
}

// Cheat overlay callbacks
static const char* cheat_get_name(int idx) {
	return (idx >= 0 && idx < s_cheatCount) ? s_cheats[idx].name : "";
}
static const char* cheat_get_description(int idx) {
	return (idx >= 0 && idx < s_cheatCount) ? s_cheats[idx].description : "";
}
static const char* cheat_get_value_label(int idx) {
	if (idx < 0 || idx >= s_cheatCount) return "OFF";
	CheatEntry* c = &s_cheats[idx];
	if (!c->enabled) return "OFF";
	if (c->variant_count > 0 && c->selected_variant >= 0 && c->selected_variant < c->variant_count)
		return c->variants[c->selected_variant].label;
	return "ON";
}
static int cheat_get_count(void) { return s_cheatCount; }
static bool cheat_is_enabled(int idx) {
	return (idx >= 0 && idx < s_cheatCount) ? s_cheats[idx].enabled : false;
}
static void cheat_toggle(int idx) {
	if (idx < 0 || idx >= s_cheatCount) return;
	s_cheats[idx].enabled = !s_cheats[idx].enabled;
	if (s_cheats[idx].enabled) {
		if (s_coreAPI.add_cheat && s_coreAPI.cheat_enabled) {
			m64p_cheat_code codes[MAX_CHEAT_CODES_PER];
			for (int j = 0; j < s_cheats[idx].num_codes; j++) {
				codes[j].address = s_cheats[idx].codes[j].address;
				codes[j].value = s_cheats[idx].codes[j].value;
			}
			s_coreAPI.add_cheat(s_cheats[idx].name, codes, s_cheats[idx].num_codes);
			s_coreAPI.cheat_enabled(s_cheats[idx].name, 1);
		}
	} else {
		if (s_coreAPI.cheat_enabled)
			s_coreAPI.cheat_enabled(s_cheats[idx].name, 0);
	}
}
static void cheat_cycle_variant(int idx, int dir) {
	if (idx < 0 || idx >= s_cheatCount) return;
	CheatEntry* c = &s_cheats[idx];
	if (c->variant_count <= 0) { cheat_toggle(idx); return; }
	int pos = c->enabled ? c->selected_variant : -1;
	pos += dir;
	if (pos >= c->variant_count) pos = -1;
	if (pos < -1) pos = c->variant_count - 1;
	if (pos < 0) {
		c->enabled = false;
		if (s_coreAPI.cheat_enabled) s_coreAPI.cheat_enabled(c->name, 0);
	} else {
		c->selected_variant = pos;
		c->codes[c->variable_code_index].value = c->variants[pos].value;
		c->enabled = true;
		if (s_coreAPI.add_cheat && s_coreAPI.cheat_enabled) {
			m64p_cheat_code codes[MAX_CHEAT_CODES_PER];
			for (int j = 0; j < c->num_codes; j++) {
				codes[j].address = c->codes[j].address;
				codes[j].value = c->codes[j].value;
			}
			s_coreAPI.add_cheat(c->name, codes, c->num_codes);
			s_coreAPI.cheat_enabled(c->name, 1);
		}
	}
}

// ---------------------------------------------------------------------------
// Shortcut handlers for reset / save / load / screenshot / game switcher
// ---------------------------------------------------------------------------

static void process_state_shortcuts(void) {
	int resetBtn = emu_frontend_get_shortcut("shortcut_reset");
	if (emu_frontend_btn_just_pressed(resetBtn)) {
		if (s_coreAPI.core_cmd)
			s_coreAPI.core_cmd(M64CMD_RESET, 0, NULL);
	}

	int saveBtn = emu_frontend_get_shortcut("shortcut_save_state");
	if (emu_frontend_btn_just_pressed(saveBtn)) {
		if (s_coreAPI.core_cmd) {
			s_coreAPI.core_cmd(M64CMD_STATE_SET_SLOT, s_currentSlot, NULL);
			s_coreAPI.core_cmd(M64CMD_STATE_SAVE, 0, NULL);
		}
		if (s_overlayInitialized)
			emu_ovl_save_slot_screenshot(&s_overlay, s_currentSlot);
	}

	int loadBtn = emu_frontend_get_shortcut("shortcut_load_state");
	if (emu_frontend_btn_just_pressed(loadBtn)) {
		if (s_coreAPI.core_cmd) {
			s_coreAPI.core_cmd(M64CMD_STATE_SET_SLOT, s_currentSlot, NULL);
			s_coreAPI.core_cmd(M64CMD_STATE_LOAD, 0, NULL);
		}
	}

	int screenshotBtn = emu_frontend_get_shortcut("shortcut_screenshot");
	if (emu_frontend_btn_just_pressed(screenshotBtn)) {
		if (s_coreAPI.core_cmd)
			s_coreAPI.core_cmd(M64CMD_TAKE_NEXT_SCREENSHOT, 0, NULL);
	}

	int gsBtn = emu_frontend_get_shortcut("shortcut_game_switcher");
	if (emu_frontend_btn_just_pressed(gsBtn)) {
		trigger_game_switcher();
	}
}

// ---------------------------------------------------------------------------
// Turbo + aspect ratio shortcut handlers
// ---------------------------------------------------------------------------

static void process_turbo_and_aspect_shortcuts(void) {
	static const struct { const char* key; const char* file; } turbo_map[] = {
		{"shortcut_turbo_a",  "a"},  {"shortcut_turbo_b",  "b"},
		{"shortcut_turbo_x",  "x"},  {"shortcut_turbo_y",  "y"},
		{"shortcut_turbo_l",  "l"},  {"shortcut_turbo_l2", "l2"},
		{"shortcut_turbo_r",  "r"},  {"shortcut_turbo_r2", "r2"},
	};
	for (int i = 0; i < 8; i++) {
		int btn = emu_frontend_get_shortcut(turbo_map[i].key);
		if (emu_frontend_btn_just_pressed(btn))
			toggle_turbo_file(turbo_map[i].file);
	}

	int aspectBtn = emu_frontend_get_shortcut("shortcut_cycle_aspect");
	if (emu_frontend_btn_just_pressed(aspectBtn)) {
		if (s_pluginOps.cycle_aspect)
			s_pluginOps.cycle_aspect();
	}
}

// ---------------------------------------------------------------------------
// Overlay menu loop (opens on menu button, runs until closed)
// ---------------------------------------------------------------------------

static void overlay_init_paths(void) {
	const char* json = getenv("EMU_OVERLAY_JSON");
	const char* ini  = getenv("EMU_OVERLAY_INI");
	if (json) strncpy(s_overlayJsonPath, json, sizeof(s_overlayJsonPath) - 1);
	if (ini)  strncpy(s_overlayIniPath,  ini,  sizeof(s_overlayIniPath) - 1);
}

// Context for overlay GL init, dispatched on video thread
typedef struct {
	int w;
	int h;
	EmuOvlRenderBackend* render;
	const char* gameName;
	int result;
} OverlayInitCtx;

static void overlay_init_on_gl_thread(void* ctx) {
	OverlayInitCtx* c = (OverlayInitCtx*)ctx;
	if (c->render->init(c->w, c->h) != 0) {
		c->result = -1;
		return;
	}
	emu_ovl_init(&s_overlay, &s_overlayConfig, c->render,
	             c->gameName ? c->gameName : "N64", c->w, c->h);
	c->result = 0;
}

static void overlay_ensure_init(int w, int h) {
	if (s_overlayInitialized || s_overlayConfigFailed)
		return;

	// Load config once (permanent failure if config file is bad)
	if (!s_overlayConfigLoaded) {
		overlay_init_paths();

		if (s_overlayJsonPath[0] == '\0')
			return; // no overlay config provided

		memset(&s_overlayConfig, 0, sizeof(s_overlayConfig));
		if (emu_ovl_cfg_load(&s_overlayConfig, s_overlayJsonPath) != 0) {
			fprintf(stderr, "[Overlay] Failed to load config: %s\n", s_overlayJsonPath);
			s_overlayConfigFailed = true;
			return;
		}

		if (s_overlayIniPath[0] != '\0') {
			emu_ovl_cfg_read_ini(&s_overlayConfig, s_overlayIniPath);
		}

		s_overlayConfigLoaded = true;

		// Apply saved CPU mode from config on first load
		int cpu_mode = find_cpu_mode_value(&s_overlayConfig);
		if (cpu_mode >= 0)
			apply_cpu_mode(cpu_mode);

		// Apply saved frame skip from config on first load
		int fs = find_frame_skip_value(&s_overlayConfig);
		if (fs >= 0)
			g_frameSkip = fs;

		// Auto-resume: if launched from NextUI game switcher, load the requested state slot
		const char* resume = getenv("EMU_RESUME_SLOT");
		if (resume && resume[0] != '\0' && s_coreAPI.core_cmd) {
			int slot = atoi(resume);
			s_coreAPI.core_cmd(M64CMD_STATE_SET_SLOT, slot, NULL);
			s_coreAPI.core_cmd(M64CMD_STATE_LOAD, 0, NULL);
			unsetenv("EMU_RESUME_SLOT");
		}

		// Load cheats from mupencheat.txt for the current ROM
		load_cheats();

		// Load per-game overrides if a per-game config file exists
		const char* pgp = get_per_game_path();
		if (pgp && pgp[0] != '\0')
			emu_ovl_cfg_read_per_game(&s_overlayConfig, pgp);

		// Load the per-game input mode (Brick-only; no-op on other devices)
		load_input_mode_from_file(&s_overlayConfig);
	}

	// Try GL init on the video thread (retries each frame until GL context is available)
	if (!s_pluginOps.get_render || !s_pluginOps.exec_on_video_thread)
		return;

	OverlayInitCtx ctx;
	ctx.w = w;
	ctx.h = h;
	ctx.render = s_pluginOps.get_render();
	ctx.gameName = getenv("EMU_OVERLAY_GAME");
	ctx.result = -1;

	s_pluginOps.exec_on_video_thread(overlay_init_on_gl_thread, &ctx);

	if (ctx.result != 0)
		return; // GL not ready yet, will retry next frame

	s_overlayInitialized = true;

	// Compute scope AFTER emu_ovl_init (which memset's s_overlay to zero).
	// Placing it before would get wiped by the memset.
	s_overlay.scope = compute_scope();

	// Wire cheat callbacks for the overlay's Cheats menu
	s_overlay.cheat_cb.get_name = cheat_get_name;
	s_overlay.cheat_cb.get_description = cheat_get_description;
	s_overlay.cheat_cb.get_value_label = cheat_get_value_label;
	s_overlay.cheat_cb.get_count = cheat_get_count;
	s_overlay.cheat_cb.is_enabled = cheat_is_enabled;
	s_overlay.cheat_cb.toggle = cheat_toggle;
	s_overlay.cheat_cb.cycle_variant = cheat_cycle_variant;

	fprintf(stderr, "[Overlay] Initialized successfully (%dx%d)\n", w, h);
}

static bool check_menu_button(void) {
	SDL_JoystickUpdate();
	if (!s_joy) return false;

	bool pressed = SDL_JoystickGetButton(s_joy, 8) != 0;
	bool justPressed = pressed && !s_menuBtnPrev;
	s_menuBtnPrev = pressed;
	return justPressed;
}

static EmuOvlInput poll_overlay_input(void) {
	EmuOvlInput input;
	memset(&input, 0, sizeof(input));

	// Use direct state polling instead of SDL events — SDL_PollEvent() may not
	// deliver joystick events reliably in mupen64plus's threaded plugin context.
	SDL_JoystickUpdate();
	if (!s_joy) return input;

	// D-pad (hat) — edge detect: only trigger on newly-pressed directions
	Uint8 hat = SDL_JoystickGetHat(s_joy, 0);
	Uint8 hatPressed = hat & ~s_prevHat;
	s_prevHat = hat;

	if (hatPressed & SDL_HAT_UP)    input.up    = true;
	if (hatPressed & SDL_HAT_DOWN)  input.down  = true;
	if (hatPressed & SDL_HAT_LEFT)  input.left  = true;
	if (hatPressed & SDL_HAT_RIGHT) input.right = true;

	// Buttons — edge detect: only trigger on newly-pressed buttons
	// SDL button indices: 0=A(hw), 1=B(hw), 2=X(hw), 3=Y(hw), 4=L1, 5=R1, 8=Menu
	static const int btnMap[] = {0, 1, 4, 5, 8};
	Uint32 curButtons = 0;
	for (int i = 0; i < 5; i++) {
		if (SDL_JoystickGetButton(s_joy, btnMap[i]))
			curButtons |= (1u << btnMap[i]);
	}
	Uint32 btnPressed = curButtons & ~s_prevButtons;
	s_prevButtons = curButtons;

	if (btnPressed & (1u << 0)) input.b    = true;
	if (btnPressed & (1u << 1)) input.a    = true;
	if (btnPressed & (1u << 4)) input.l1   = true;
	if (btnPressed & (1u << 5)) input.r1   = true;
	if (btnPressed & (1u << 8)) input.menu = true;

	return input;
}

// Context for overlay open, dispatched on video thread
static void overlay_open_on_gl_thread(void* ctx) {
	(void)ctx;
	emu_ovl_open(&s_overlay);
}

// Context for per-frame overlay update+render, dispatched on video thread
static void overlay_frame_on_gl_thread(void* ctx) {
	EmuOvlInput* input = (EmuOvlInput*)ctx;
	emu_ovl_update(&s_overlay, input);
	emu_ovl_render(&s_overlay);
	if (s_pluginOps.swap_buffers)
		s_pluginOps.swap_buffers();
}

static EmuOvlAction run_overlay_loop(void) {
	// Pause audio (stays on main thread)
	SDL_PauseAudio(1);

	// Temporarily restore d-pad for menu navigation. trimui_inputd's
	// input_no_dpad suppresses hat events at the kernel level, which
	// breaks poll_overlay_input (it reads SDL hat 0). Remove the flags
	// while the menu is open; re-apply after close via apply_input_mode_if_dirty.
	int saved_input_mode = -1;
	EmuOvlItem* im_item = find_input_mode_item(&s_overlayConfig);
	if (im_item) {
		saved_input_mode = im_item->current_value;
		apply_input_mode(1); // force d-pad passthrough for menu nav
	}

	// Open overlay on video thread (captures current frame — needs GL)
	s_pluginOps.exec_on_video_thread(overlay_open_on_gl_thread, NULL);

	// Reset input edge detection state and drain pending SDL events
	s_prevHat = SDL_JoystickGetHat(s_joy, 0);
	s_prevButtons = 0;
	static const int menu_btns[] = {0, 1, 4, 5, 8};
	for (int i = 0; i < 5; i++) {
		if (SDL_JoystickGetButton(s_joy, menu_btns[i]))
			s_prevButtons |= (1u << menu_btns[i]);
	}
	SDL_Event ev;
	while (SDL_PollEvent(&ev)) {}
	s_menuBtnPrev = true; // prevent re-trigger

	// Menu loop: input polled here, update+render+swap dispatched to video thread
	while (emu_ovl_is_active(&s_overlay)) {
		EmuOvlInput input = poll_overlay_input();

		// Power button: sleep on short press, poweroff on long press
		int pwr = check_power_button();
		if (pwr == 1) {
			handle_sleep();
		} else if (pwr == 2) {
			system("touch /tmp/poweroff");
			s_overlay.action = EMU_OVL_ACTION_QUIT;
			s_overlay.state = EMU_OVL_STATE_CLOSED;
			break;
		}

		s_pluginOps.exec_on_video_thread(overlay_frame_on_gl_thread, &input);

		// Dispatch save-scope actions inline (menu stays open, matching
		// NextUI's OptionSaveChanges_onConfirm which calls Config_write
		// synchronously and then returns to the menu). Without this, the
		// save action set by the Save Changes submenu would be overwritten
		// by EMU_OVL_ACTION_CONTINUE when the user eventually closes the
		// menu via B.
		switch (emu_ovl_get_action(&s_overlay)) {
		case EMU_OVL_ACTION_SAVE_CONSOLE:
			handle_save_for_console();
			s_overlay.action = EMU_OVL_ACTION_NONE;
			break;
		case EMU_OVL_ACTION_SAVE_GAME:
			handle_save_for_game();
			s_overlay.action = EMU_OVL_ACTION_NONE;
			break;
		case EMU_OVL_ACTION_RESTORE_DEFAULTS:
			handle_restore_defaults();
			s_overlay.action = EMU_OVL_ACTION_NONE;
			break;
		default:
			break;
		}

		SDL_Delay(16);
	}

	// Resume audio (stays on main thread)
	SDL_PauseAudio(0);

	EmuOvlAction action = emu_ovl_get_action(&s_overlay);

	// Restore the input mode that was active before the menu opened.
	// If the user changed it in the menu, apply_input_mode_if_dirty will
	// override with the new value below.
	if (saved_input_mode >= 0)
		apply_input_mode(saved_input_mode);

	// Apply on-demand runtime settings (cpu_mode, frame_skip, input_mode)
	// WITHOUT persisting to disk. Dirty flags stay set so the Save Changes
	// menu knows something needs persistence.
	if (emu_ovl_cfg_has_changes(&s_overlayConfig)) {
		apply_cpu_mode_if_dirty(&s_overlayConfig);
		apply_frame_skip_if_dirty(&s_overlayConfig);
		apply_input_mode_if_dirty(&s_overlayConfig);
	}

	return action;
}

// Path to the per-game config file for this ROM
static const char* get_per_game_path(void) {
	return getenv("EMU_PER_GAME_CFG");
}

// Path to the ".customized" stamp (console scope indicator)
static char s_customizedPath[512] = "";
static void ensure_customized_path(void) {
	if (s_customizedPath[0] != '\0') return;
	// Derive from the overlay INI path's directory
	if (s_overlayIniPath[0] == '\0') return;
	snprintf(s_customizedPath, sizeof(s_customizedPath), "%s", s_overlayIniPath);
	char* slash = strrchr(s_customizedPath, '/');
	if (slash) {
		snprintf(slash + 1, sizeof(s_customizedPath) - (slash + 1 - s_customizedPath),
				 ".customized");
	}
}

static EmuConfigScope compute_scope(void) {
	const char* pgp = get_per_game_path();
	if (pgp && pgp[0] != '\0' && access(pgp, F_OK) == 0)
		return EMU_SCOPE_GAME;
	ensure_customized_path();
	if (s_customizedPath[0] != '\0' && access(s_customizedPath, F_OK) == 0)
		return EMU_SCOPE_CONSOLE;
	return EMU_SCOPE_NONE;
}

static void handle_save_for_console(void) {
	// Write all items to mupen64plus.cfg via the existing merge-preserve writer.
	// When in game scope, launch.sh backed up the console config to
	// $EMU_CONSOLE_CFG; write there instead so the console config is
	// updated without clobbering the game-overlaid runtime copy.
	const char* target = getenv("EMU_CONSOLE_CFG");
	if (!target || target[0] == '\0') target = s_overlayIniPath;
	if (target[0] != '\0') {
		emu_ovl_cfg_write_ini(&s_overlayConfig, target);
		apply_audio_quality_if_dirty(&s_overlayConfig);
	}
	emu_ovl_cfg_apply_staged(&s_overlayConfig);
	// Touch .customized stamp
	ensure_customized_path();
	if (s_customizedPath[0] != '\0') {
		FILE* f = fopen(s_customizedPath, "w");
		if (f) fclose(f);
	}
	s_overlay.scope = EMU_SCOPE_CONSOLE;
	fprintf(stderr, "[Overlay] Saved for console.\n");
}

static void handle_save_for_game(void) {
	const char* pgp = get_per_game_path();
	if (!pgp || pgp[0] == '\0') {
		fprintf(stderr, "[Overlay] No per-game path set; cannot save for game.\n");
		return;
	}
	emu_ovl_cfg_write_per_game(&s_overlayConfig, pgp);
	// Also write to the live mupen64plus.cfg so restart-required settings
	// take effect on next launch of THIS same game (launch.sh will overlay
	// the per-game file anyway, but if the user is still in-session it keeps
	// the runtime copy current too).
	if (s_overlayIniPath[0] != '\0') {
		emu_ovl_cfg_write_ini(&s_overlayConfig, s_overlayIniPath);
		apply_audio_quality_if_dirty(&s_overlayConfig);
	}
	emu_ovl_cfg_apply_staged(&s_overlayConfig);
	s_overlay.scope = EMU_SCOPE_GAME;
	fprintf(stderr, "[Overlay] Saved for game.\n");
}

static void handle_restore_defaults(void) {
	if (s_overlay.scope == EMU_SCOPE_GAME) {
		// Delete per-game file, revert to console scope
		const char* pgp = get_per_game_path();
		if (pgp && pgp[0] != '\0') unlink(pgp);
		// Reload values from the console config (mupen64plus.cfg)
		if (s_overlayIniPath[0] != '\0')
			emu_ovl_cfg_read_ini(&s_overlayConfig, s_overlayIniPath);
		s_overlay.scope = compute_scope();
		fprintf(stderr, "[Overlay] Restored console defaults.\n");
	} else if (s_overlay.scope == EMU_SCOPE_CONSOLE) {
		// Delete .customized stamp; reset all items to JSON defaults
		ensure_customized_path();
		if (s_customizedPath[0] != '\0') unlink(s_customizedPath);
		emu_ovl_cfg_reset_all_to_defaults(&s_overlayConfig);
		emu_ovl_cfg_apply_staged(&s_overlayConfig);
		// Re-seed mupen64plus.cfg from default.cfg
		const char* default_cfg = getenv("EMU_DEFAULT_CFG");
		if (default_cfg && default_cfg[0] != '\0' && s_overlayIniPath[0] != '\0') {
			// Copy default.cfg over mupen64plus.cfg
			FILE* src = fopen(default_cfg, "r");
			if (src) {
				FILE* dst = fopen(s_overlayIniPath, "w");
				if (dst) {
					char buf[4096];
					size_t n;
					while ((n = fread(buf, 1, sizeof(buf), src)) > 0)
						fwrite(buf, 1, n, dst);
					fclose(dst);
				}
				fclose(src);
			}
		}
		s_overlay.scope = EMU_SCOPE_NONE;
		fprintf(stderr, "[Overlay] Restored defaults.\n");
	} else {
		// Already on defaults — reset staged values
		emu_ovl_cfg_reset_all_to_defaults(&s_overlayConfig);
		emu_ovl_cfg_apply_staged(&s_overlayConfig);
		fprintf(stderr, "[Overlay] Already on defaults; reset staged.\n");
	}
	// Re-apply runtime settings with the restored values
	apply_cpu_mode(find_cpu_mode_value(&s_overlayConfig));
	int fs = find_frame_skip_value(&s_overlayConfig);
	if (fs >= 0) g_frameSkip = fs;
}

static void handle_overlay_action(EmuOvlAction action) {
	switch (action) {
	case EMU_OVL_ACTION_QUIT:
		request_stop();
		break;
	case EMU_OVL_ACTION_SAVE_STATE: {
		int slot = emu_ovl_get_action_param(&s_overlay);
		s_currentSlot = slot;
		if (s_coreAPI.core_cmd) {
			s_coreAPI.core_cmd(M64CMD_STATE_SET_SLOT, slot, NULL);
			s_coreAPI.core_cmd(M64CMD_STATE_SAVE, 0, NULL);
		}
		emu_ovl_save_slot_screenshot(&s_overlay, slot);
		break;
	}
	case EMU_OVL_ACTION_LOAD_STATE: {
		int slot = emu_ovl_get_action_param(&s_overlay);
		s_currentSlot = slot;
		if (s_coreAPI.core_cmd) {
			s_coreAPI.core_cmd(M64CMD_STATE_SET_SLOT, slot, NULL);
			s_coreAPI.core_cmd(M64CMD_STATE_LOAD, 0, NULL);
		}
		break;
	}
	case EMU_OVL_ACTION_SAVE_CONSOLE:
		handle_save_for_console();
		break;
	case EMU_OVL_ACTION_SAVE_GAME:
		handle_save_for_game();
		break;
	case EMU_OVL_ACTION_RESTORE_DEFAULTS:
		handle_restore_defaults();
		break;
	default:
		break;
	}
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void emu_frontend_init(EmuFrontendCoreAPI* api, EmuFrontendPluginOps* ops) {
	if (api) s_coreAPI = *api;
	if (ops) s_pluginOps = *ops;
	s_initialized = true;
}

EmuOvlConfig* emu_frontend_get_overlay_config(void) {
	return &s_overlayConfig;
}

void emu_frontend_frame(int w, int h) {
	// Ensure joystick is open
	if (!s_joy && SDL_NumJoysticks() > 0)
		s_joy = SDL_JoystickOpen(0);

	// Power button: sleep on short press, poweroff on long press
	int pwr = check_power_button();
	if (pwr == 1) {
		handle_sleep();
	} else if (pwr == 2) {
		system("touch /tmp/poweroff");
		request_stop();
	}

	// Shortcut button processing
	emu_frontend_update_buttons();
	if (s_overlayConfigLoaded) {
		process_fast_forward();
		process_state_shortcuts();
		process_rewind();
		process_turbo_and_aspect_shortcuts();
		process_input_mode_shortcut();
	}

	// Overlay menu: ensure loaded, then handle menu button press
	overlay_ensure_init(w, h);
	if (s_overlayInitialized && check_menu_button()) {
		EmuOvlAction action = run_overlay_loop();
		handle_overlay_action(action);
	}
}

void emu_frontend_cleanup(void) {
	rewind_cleanup();
	clear_turbo_files();
	// Clean up trimui_inputd flag files so we don't leak d-pad remap state
	// to other emulators. launch.sh's exit trap also does this as a safety net.
	unlink("/tmp/trimui_inputd/input_dpad_to_joystick");
	unlink("/tmp/trimui_inputd/input_no_dpad");
}

SDL_Joystick* emu_frontend_get_joystick(void) {
	return s_joy;
}
