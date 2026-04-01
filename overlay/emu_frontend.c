#include "emu_frontend.h"

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
		s_coreAPI.core_cmd(EMU_FE_CMD_STATE_SET_SLOT, 9, NULL);
		s_coreAPI.core_cmd(EMU_FE_CMD_STATE_SAVE, 0, NULL);
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
// Public API
// ---------------------------------------------------------------------------

void emu_frontend_init(EmuFrontendCoreAPI* api, EmuFrontendPluginOps* ops) {
	if (api) s_coreAPI = *api;
	if (ops) s_pluginOps = *ops;
	s_initialized = true;
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
		emu_frontend_cleanup();
		if (s_coreAPI.core_cmd)
			s_coreAPI.core_cmd(EMU_FE_CMD_STOP, 0, NULL);
	}
}

void emu_frontend_cleanup(void) {
	// Placeholder: turbo + rewind cleanup will move here in later commits
}

SDL_Joystick* emu_frontend_get_joystick(void) {
	return s_joy;
}
