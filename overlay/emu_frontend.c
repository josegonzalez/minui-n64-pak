#include "emu_frontend.h"
#include "m64p_types.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <SDL2/SDL.h>

// Frame skip: owned here, read by GLideN64 RSP.cpp via extern
int g_frameSkip = 0;

// Core API and plugin ops (set by emu_frontend_init)
static EmuFrontendCoreAPI s_coreAPI;
static EmuFrontendPluginOps s_pluginOps;
static bool s_initialized = false;

// Joystick (managed by emu_frontend for power button + input polling)
static SDL_Joystick* s_joy = NULL;

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

static EmuOvlConfig* s_config = NULL;
static EmuOvl* s_ovl = NULL;
static bool* s_ovlInitialized = NULL;
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
	if (!s_config) return -1;
	for (int s = 0; s < s_config->section_count; s++)
		for (int i = 0; i < s_config->sections[s].item_count; i++)
			if (strcmp(s_config->sections[s].items[i].key, key) == 0)
				return s_config->sections[s].items[i].current_value;
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
	if (s_pluginOps.on_pre_stop)
		s_pluginOps.on_pre_stop();
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
	if (s_ovl && s_ovlInitialized && *s_ovlInitialized)
		emu_ovl_save_slot_screenshot(s_ovl, s_currentSlot);
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
	if (!s_config) return;
	int bufSetting = 0;
	for (int s = 0; s < s_config->section_count; s++)
		for (int i = 0; i < s_config->sections[s].item_count; i++)
			if (strcmp(s_config->sections[s].items[i].key, "rewind_buffer") == 0)
				bufSetting = s_config->sections[s].items[i].current_value;
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

void emu_frontend_load_cheats(void) {
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
		if (s_ovl && s_ovlInitialized && *s_ovlInitialized)
			emu_ovl_save_slot_screenshot(s_ovl, s_currentSlot);
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
// Public API
// ---------------------------------------------------------------------------

void emu_frontend_init(EmuFrontendCoreAPI* api, EmuFrontendPluginOps* ops) {
	if (api) s_coreAPI = *api;
	if (ops) s_pluginOps = *ops;
	s_initialized = true;
}

void emu_frontend_set_config(EmuOvlConfig* cfg) {
	s_config = cfg;
}

void emu_frontend_set_overlay(EmuOvl* ovl, bool* initialized) {
	s_ovl = ovl;
	s_ovlInitialized = initialized;

	// Wire cheat callbacks for the overlay's Cheats menu
	if (ovl) {
		ovl->cheat_cb.get_name = cheat_get_name;
		ovl->cheat_cb.get_description = cheat_get_description;
		ovl->cheat_cb.get_value_label = cheat_get_value_label;
		ovl->cheat_cb.get_count = cheat_get_count;
		ovl->cheat_cb.is_enabled = cheat_is_enabled;
		ovl->cheat_cb.toggle = cheat_toggle;
		ovl->cheat_cb.cycle_variant = cheat_cycle_variant;
	}
}

int emu_frontend_get_current_slot(void) {
	return s_currentSlot;
}

void emu_frontend_set_current_slot(int slot) {
	s_currentSlot = slot;
}

void emu_frontend_frame(void) {
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
	if (s_config) {
		process_fast_forward();
		process_state_shortcuts();
		process_rewind();
	}
}

void emu_frontend_cleanup(void) {
	rewind_cleanup();
	// Turbo cleanup will move here in commit 5
}

SDL_Joystick* emu_frontend_get_joystick(void) {
	return s_joy;
}

bool emu_frontend_is_fast_forward(void) {
	return s_fastForward;
}

bool emu_frontend_is_ff_toggled(void) {
	return s_ffToggledOn;
}

void emu_frontend_set_fast_forward(bool enable) {
	set_fast_forward(enable);
}
