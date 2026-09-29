#include "emu_overlay.h"
#include "emu_frontend.h"
#include "cjson/cJSON.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Layout constants (pre-scaled), tuned to Jawaka's RetroArch in-game menu.
#define PILL_SIZE 30
#define BUTTON_SIZE 20
#define BUTTON_MARGIN 5
#define BUTTON_PADDING 12
#define PANEL_RADIUS 14
#define FOOTER_UNDERLAY_ALPHA 200
#define HEADER_CONTENT_GAP 8
#define CONTENT_PANEL_TOP_TRIM 12
#define HINT_UP_DOWN "__nav_up_down__"
#define HINT_LEFT_RIGHT "__nav_left_right__"

static int ovl_scale = 2;
static int ovl_padding = 10;
#define S(x) ((x) * ovl_scale)
#define PADDING_PX (ovl_padding * ovl_scale)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static uint32_t color_with_alpha(uint32_t color, unsigned int alpha) {
	if (alpha > 255)
		alpha = 255;
	return (color & 0x00FFFFFFu) | ((uint32_t)alpha << 24);
}

static uint32_t color_scale_alpha(uint32_t color, unsigned int alpha) {
	if (alpha > 255)
		alpha = 255;
	unsigned int current = (unsigned int)((color >> 24) & 0xFFu);
	unsigned int scaled = current * alpha / 255;
	return (color & 0x00FFFFFFu) | ((uint32_t)scaled << 24);
}

static int hex_nibble(char c) {
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return 10 + c - 'a';
	if (c >= 'A' && c <= 'F')
		return 10 + c - 'A';
	return -1;
}

static bool parse_theme_color(const char* value, uint32_t* out) {
	if (!value || !out)
		return false;
	if (value[0] == '#')
		value++;
	size_t len = strlen(value);
	if (len != 6 && len != 8)
		return false;

	uint32_t n = 0;
	for (size_t i = 0; i < len; i++) {
		int v = hex_nibble(value[i]);
		if (v < 0)
			return false;
		n = (n << 4) | (uint32_t)v;
	}
	if (len == 6) {
		*out = 0xFF000000u | n;
	} else {
		uint32_t rgb = n >> 8;
		uint32_t a = n & 0xFFu;
		*out = (a << 24) | rgb;
	}
	return true;
}

static int color_luma(uint32_t color) {
	int r = (int)((color >> 16) & 0xFF);
	int g = (int)((color >> 8) & 0xFF);
	int b = (int)(color & 0xFF);
	return (r * 299 + g * 587 + b * 114) / 1000;
}

static uint32_t derive_highlighted_text(uint32_t background, uint32_t text,
										uint32_t highlight) {
	int hl_lum = color_luma(highlight);
	int text_lum = color_luma(text);
	int bg_lum = color_luma(background);
	if (hl_lum > 140)
		return (text_lum < bg_lum) ? text : background;
	return (text_lum > bg_lum) ? text : background;
}

static bool parse_theme_bool(const char* value, bool fallback) {
	if (!value || value[0] == '\0')
		return fallback;
	if (strcmp(value, "0") == 0 || strcmp(value, "false") == 0 ||
		strcmp(value, "FALSE") == 0 || strcmp(value, "off") == 0 ||
		strcmp(value, "OFF") == 0)
		return false;
	return true;
}

static float parse_theme_float(const char* value, float fallback,
							   float min_value, float max_value) {
	if (!value || value[0] == '\0')
		return fallback;
	char* end = NULL;
	float parsed = strtof(value, &end);
	if (end == value)
		return fallback;
	if (parsed < min_value)
		parsed = min_value;
	if (parsed > max_value)
		parsed = max_value;
	return parsed;
}

// ---------------------------------------------------------------------------
// Jawaka / Catastrophe theme stylesheet
//
// The launcher's in-game menu is rendered by Catastrophe from the active theme's
// stylesheet.json. This overlay is a separate renderer, so we read the same
// stylesheet to keep the two visually in sync. Resolved from
// $CAT_THEMES_DIR/$CAT_THEME_NAME/stylesheet.json (both set by Leaf's env.sh).
// Absent on the NextUI/MinUI launch path, where we fall back to the env/defaults.
// ---------------------------------------------------------------------------

static bool stylesheet_path(char* buf, size_t n) {
	const char* dir = getenv("CAT_THEMES_DIR");
	const char* name = getenv("CAT_THEME_NAME");
	if (!dir || !dir[0] || !name || !name[0])
		return false;
	int written = snprintf(buf, n, "%s/%s/stylesheet.json", dir, name);
	return written > 0 && (size_t)written < n;
}

static char* read_file_alloc(const char* path) {
	FILE* f = fopen(path, "rb");
	if (!f)
		return NULL;
	char* buf = NULL;
	if (fseek(f, 0, SEEK_END) == 0) {
		long size = ftell(f);
		if (size >= 0 && size <= (1 << 20)) {
			rewind(f);
			buf = (char*)malloc((size_t)size + 1);
			if (buf) {
				size_t got = fread(buf, 1, (size_t)size, f);
				buf[got] = '\0';
			}
		}
	}
	fclose(f);
	return buf;
}

// Parse the active stylesheet. Caller must cJSON_Delete the result (or NULL).
static cJSON* stylesheet_load(void) {
	char path[1024];
	if (!stylesheet_path(path, sizeof(path)))
		return NULL;
	char* text = read_file_alloc(path);
	if (!text)
		return NULL;
	cJSON* root = cJSON_Parse(text);
	free(text);
	return root;
}

// Read a "#RRGGBB"/"#RRGGBBAA" color field from a cJSON object into *out.
// Returns true only when the field exists and parses.
static bool json_color(const cJSON* obj, const char* key, uint32_t* out) {
	if (!obj)
		return false;
	const cJSON* item = cJSON_GetObjectItemCaseSensitive(obj, key);
	if (!cJSON_IsString(item) || !item->valuestring)
		return false;
	return parse_theme_color(item->valuestring, out);
}

static void load_theme(EmuOvl* ovl) {
	EmuOvlTheme theme;
	theme.text = EMU_OVL_COLOR_TEXT;
	theme.hint = EMU_OVL_COLOR_HINT;
	theme.highlight = EMU_OVL_COLOR_HIGHLIGHT;
	theme.highlighted_text = EMU_OVL_COLOR_HIGHLIGHT_TEXT;
	theme.accent = EMU_OVL_COLOR_HIGHLIGHT;
	theme.button_glyph_bg = EMU_OVL_COLOR_HIGHLIGHT;
	theme.button_label = EMU_OVL_COLOR_HIGHLIGHT_TEXT;
	theme.preview_bg = EMU_OVL_COLOR_PREVIEW_BG;
	theme.pill_radius_ratio = 1.0f;
	theme.show_hints = true;

	uint32_t background = 0xFF0F160Eu;

	// 1) Active Jawaka/Catastrophe stylesheet — primary source of truth.
	bool have_highlighted_text = false;
	bool have_accent = false;
	bool have_button_glyph_bg = false;
	bool have_button_label = false;
	cJSON* ss = stylesheet_load();
	if (ss) {
		const cJSON* ui = cJSON_GetObjectItemCaseSensitive(ss, "ui");
		json_color(ui, "background_color", &background);
		json_color(ui, "text_color", &theme.text);
		json_color(ui, "highlight_color", &theme.highlight);
		if (!json_color(ui, "hint_color", &theme.hint))
			json_color(ui, "disabled_color", &theme.hint);
		have_highlighted_text =
			json_color(ui, "highlight_text_color", &theme.highlighted_text);
		const cJSON* radius =
			ui ? cJSON_GetObjectItemCaseSensitive(ui, "pill_radius_ratio") : NULL;
		if (cJSON_IsNumber(radius))
			theme.pill_radius_ratio = (float)radius->valuedouble;

		const cJSON* bh = cJSON_GetObjectItemCaseSensitive(ss, "button_hints");
		have_accent = json_color(bh, "button_a_color", &theme.accent);
		have_button_glyph_bg = json_color(bh, "glyph_bg_color", &theme.button_glyph_bg);
		have_button_label = json_color(bh, "button_text_color", &theme.button_label);
		cJSON_Delete(ss);
	}

	// 2) CAT_COLOR_* env overrides for the base colors (win over the stylesheet).
	uint32_t parsed = 0;
	if (parse_theme_color(getenv("CAT_COLOR_BACKGROUND"), &parsed))
		background = parsed;
	if (parse_theme_color(getenv("CAT_COLOR_TEXT"), &parsed))
		theme.text = parsed;
	if (parse_theme_color(getenv("CAT_COLOR_HINT"), &parsed))
		theme.hint = parsed;
	bool have_highlight_override = parse_theme_color(getenv("CAT_COLOR_HIGHLIGHT"), &parsed);
	if (have_highlight_override)
		theme.highlight = parsed;
	else if (parse_theme_color(getenv("CAT_COLOR_ACCENT"), &parsed))
		theme.highlight = parsed;
	if (parse_theme_color(getenv("CAT_COLOR_ACCENT"), &parsed)) {
		theme.accent = parsed;
		have_accent = true;
	}

	// 3) Derive panel + dependent colors from the resolved base colors. Only
	//    derive a dependent color when neither the stylesheet nor an explicit
	//    env var supplied it.
	theme.background = background;
	theme.panel = color_with_alpha(background, 200);
	theme.panel_strong = color_with_alpha(background, 230);
	if (!have_accent)
		theme.accent = color_with_alpha(background, 255);
	if (background == 0xFF0E0E0Eu && theme.text == 0xFFECECECu &&
		theme.highlight == 0xFFCFCFCFu)
		// Ebony's light selection pill needs its dark background color for contrast.
		theme.highlighted_text = background;
	else if (!have_highlighted_text)
		theme.highlighted_text =
			derive_highlighted_text(background, theme.text, theme.highlight);
	if (!have_button_glyph_bg)
		theme.button_glyph_bg = theme.highlight;
	if (!have_button_label)
		theme.button_label = theme.highlighted_text;

	// 4) Remaining CAT_COLOR_* overrides (highest priority).
	if (parse_theme_color(getenv("CAT_COLOR_BUTTON_GLYPH_BG"), &parsed))
		theme.button_glyph_bg = parsed;
	if (parse_theme_color(getenv("CAT_COLOR_BUTTON_LABEL"), &parsed))
		theme.button_label = parsed;
	if (parse_theme_color(getenv("CAT_COLOR_HIGHLIGHTED_TEXT"), &parsed))
		theme.highlighted_text = parsed;

	theme.show_hints = parse_theme_bool(getenv("CAT_SHOW_HINTS"), true);
	theme.pill_radius_ratio = parse_theme_float(getenv("CAT_PILL_RADIUS_RATIO"),
												theme.pill_radius_ratio, 0.0f, 1.0f);

	ovl->theme = theme;
}

// Exposed for the SDL backend (declared in emu_overlay_render.h).
int emu_ovl_stylesheet_font_size(int fallback) {
	cJSON* ss = stylesheet_load();
	if (!ss)
		return fallback;
	int size = fallback;
	const cJSON* ui = cJSON_GetObjectItemCaseSensitive(ss, "ui");
	const cJSON* font = ui ? cJSON_GetObjectItemCaseSensitive(ui, "ui_font") : NULL;
	const cJSON* sz = font ? cJSON_GetObjectItemCaseSensitive(font, "size") : NULL;
	if (cJSON_IsNumber(sz) && sz->valuedouble > 0)
		size = (int)sz->valuedouble;
	cJSON_Delete(ss);
	return size;
}

static void build_main_menu(EmuOvl* ovl) {
	int n = 0;

	snprintf(ovl->main_items[n].label, sizeof(ovl->main_items[n].label), "Resume");
	ovl->main_items[n].type = EMU_OVL_MAIN_CONTINUE;
	n++;

	if (ovl->config->save_state) {
		snprintf(ovl->main_items[n].label, sizeof(ovl->main_items[n].label), "Save State");
		ovl->main_items[n].type = EMU_OVL_MAIN_SAVE;
		n++;
	}

	if (ovl->config->load_state) {
		snprintf(ovl->main_items[n].label, sizeof(ovl->main_items[n].label), "Load State");
		ovl->main_items[n].type = EMU_OVL_MAIN_LOAD;
		n++;
	}

	if (ovl->config->section_count > 0) {
		snprintf(ovl->main_items[n].label, sizeof(ovl->main_items[n].label), "Options");
		ovl->main_items[n].type = EMU_OVL_MAIN_OPTIONS;
		n++;
	}

	snprintf(ovl->main_items[n].label, sizeof(ovl->main_items[n].label), "Quit");
	ovl->main_items[n].type = EMU_OVL_MAIN_QUIT;
	n++;

	ovl->main_item_count = n;
}

static int find_options_index(EmuOvl* ovl) {
	for (int i = 0; i < ovl->main_item_count; i++) {
		if (ovl->main_items[i].type == EMU_OVL_MAIN_OPTIONS)
			return i;
	}
	return 0;
}

static const char* main_item_label(EmuOvl* ovl, int index) {
	if (!ovl || index < 0 || index >= ovl->main_item_count)
		return "";
	if (ovl->main_items[index].type == EMU_OVL_MAIN_QUIT)
		return ovl->quit_save ? "Save & Quit" : "Quit";
	return ovl->main_items[index].label;
}

static void cycle_item_next(EmuOvlItem* item) {
	switch (item->type) {
	case EMU_OVL_TYPE_BOOL:
		item->staged_value = item->staged_value ? 0 : 1;
		break;
	case EMU_OVL_TYPE_CYCLE: {
		int idx = -1;
		for (int i = 0; i < item->value_count; i++) {
			if (item->values[i] == item->staged_value) {
				idx = i;
				break;
			}
		}
		if (idx < 0)
			idx = 0;
		else
			idx = (idx + 1) % item->value_count;
		item->staged_value = item->values[idx];
		break;
	}
	case EMU_OVL_TYPE_INT:
		item->staged_value += item->int_step;
		if (item->staged_value > item->int_max)
			item->staged_value = item->int_min;
		break;
	}
	item->dirty = (item->staged_value != item->current_value);
}

static void cycle_item_prev(EmuOvlItem* item) {
	switch (item->type) {
	case EMU_OVL_TYPE_BOOL:
		item->staged_value = item->staged_value ? 0 : 1;
		break;
	case EMU_OVL_TYPE_CYCLE: {
		int idx = -1;
		for (int i = 0; i < item->value_count; i++) {
			if (item->values[i] == item->staged_value) {
				idx = i;
				break;
			}
		}
		if (idx < 0)
			idx = 0;
		else
			idx = (idx - 1 + item->value_count) % item->value_count;
		item->staged_value = item->values[idx];
		break;
	}
	case EMU_OVL_TYPE_INT:
		item->staged_value -= item->int_step;
		if (item->staged_value < item->int_min)
			item->staged_value = item->int_max;
		break;
	}
	item->dirty = (item->staged_value != item->current_value);
}

static const char* get_item_display_value(EmuOvlItem* item, char* buf, int buf_size) {
	switch (item->type) {
	case EMU_OVL_TYPE_BOOL:
		return item->staged_value ? "On" : "Off";
	case EMU_OVL_TYPE_CYCLE:
		for (int i = 0; i < item->value_count; i++) {
			if (item->values[i] == item->staged_value) {
				if (item->labels[i][0] != '\0')
					return item->labels[i];
				snprintf(buf, buf_size, "%d", item->staged_value);
				return buf;
			}
		}
		snprintf(buf, buf_size, "%d", item->staged_value);
		return buf;
	case EMU_OVL_TYPE_INT:
		snprintf(buf, buf_size, "%d", item->staged_value);
		return buf;
	}
	return "";
}

static void ensure_scroll(EmuOvl* ovl, int total_count) {
	if (ovl->selected < ovl->scroll_offset)
		ovl->scroll_offset = ovl->selected;
	else if (ovl->selected >= ovl->scroll_offset + ovl->items_per_page)
		ovl->scroll_offset = ovl->selected - ovl->items_per_page + 1;
	if (ovl->scroll_offset < 0)
		ovl->scroll_offset = 0;
	int max_scroll = total_count - ovl->items_per_page;
	if (max_scroll < 0)
		max_scroll = 0;
	if (ovl->scroll_offset > max_scroll)
		ovl->scroll_offset = max_scroll;
}

// L1/R1 page jump: move `selected` by `dir * page` items, clamped to [0, total-1].
// For short lists (total <= page) this reduces to "jump to first/last".
static int page_jump(int selected, int total, int page, int dir) {
	if (page < 1) page = 1;
	int new_sel = selected + dir * page;
	if (new_sel < 0) new_sel = 0;
	if (new_sel >= total) new_sel = total - 1;
	return new_sel;
}

// Find the synthetic "Cheats" section's alphabetical position in cfg->sections[]
static int find_cheats_section_index(EmuOvl* ovl) {
	if (!ovl || !ovl->config) return -1;
	for (int i = 0; i < ovl->config->section_count; i++)
		if (strcmp(ovl->config->sections[i].name, "Cheats") == 0)
			return i;
	return -1;
}

// ---------------------------------------------------------------------------
// Save-slot screenshot helpers
// ---------------------------------------------------------------------------

static void get_slot_screenshot_path(EmuOvl* ovl, int slot, char* buf, int buf_size) {
	// Slot preview format: <screenshot_dir>/<rom_file>.<slot>.bmp
	snprintf(buf, buf_size, "%s/%s.%d.bmp", ovl->screenshot_dir, ovl->rom_file, slot);
}

static void write_resume_slot(EmuOvl* ovl, int slot) {
	// Write resume slot file so game switcher knows which slot to show
	// Format: <screenshot_dir>/<rom_file>.txt containing the slot number
	char path[512];
	snprintf(path, sizeof(path), "%s/%s.txt", ovl->screenshot_dir, ovl->rom_file);
	FILE* f = fopen(path, "w");
	if (f) {
		fprintf(f, "%d", slot);
		fclose(f);
	}
}

static void load_slot_screenshots(EmuOvl* ovl) {
	if (!ovl->render || !ovl->render->load_icon ||
		ovl->screenshot_dir[0] == '\0' || ovl->rom_file[0] == '\0')
		return;

	int outer = PADDING_PX + S(24);
	int available_w = ovl->screen_w - outer * 2;
	int menu_w = available_w * 62 / 100;
	int preview_w = available_w - menu_w - S(14);
	int target_h = preview_w * 3 / 4;
	if (target_h < S(80))
		target_h = ovl->screen_h / 3;

	for (int i = 0; i < EMU_OVL_MAX_SLOTS; i++) {
		// Free old icon if loaded
		if (ovl->slot_icons[i] >= 0 && ovl->render->free_icon) {
			ovl->render->free_icon(ovl->slot_icons[i]);
			ovl->slot_icons[i] = -1;
		}
		char path[512];
		get_slot_screenshot_path(ovl, i, path, sizeof(path));
		if (access(path, F_OK) == 0)
			ovl->slot_icons[i] = ovl->render->load_icon(path, target_h);
	}
}

static void free_slot_screenshots(EmuOvl* ovl) {
	if (!ovl->render || !ovl->render->free_icon)
		return;
	for (int i = 0; i < EMU_OVL_MAX_SLOTS; i++) {
		if (ovl->slot_icons[i] >= 0) {
			ovl->render->free_icon(ovl->slot_icons[i]);
			ovl->slot_icons[i] = -1;
		}
	}
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

int emu_ovl_init(EmuOvl* ovl, EmuOvlConfig* cfg, EmuOvlRenderBackend* render,
				 const char* game_name, int screen_w, int screen_h) {
	memset(ovl, 0, sizeof(*ovl));
	ovl->config = cfg;
	ovl->render = render;
	ovl->state = EMU_OVL_STATE_CLOSED;
	ovl->action = EMU_OVL_ACTION_NONE;
	ovl->screen_w = screen_w;
	ovl->screen_h = screen_h;
	load_theme(ovl);

	if (game_name)
		snprintf(ovl->game_name, sizeof(ovl->game_name), "%s", game_name);

	// Console display name shown under the game title (Catastrophe IGM parity).
	const char* console = getenv("EMU_OVERLAY_CONSOLE");
	snprintf(ovl->console_name, sizeof(ovl->console_name), "%s",
			 (console && console[0]) ? console : "Nintendo 64");

	// Per-resolution layout scale + page size. Only the Brick (1024x768) is tall
	// enough for 3x; the 720p-class screens (MLP1 960x720, Smart Pro / TG5050
	// 1280x720) use 2x so the header and rows fit without overlapping.
	if (screen_w <= 1024 && screen_h >= 768) {
		// Brick 1024x768
		ovl_scale = 3;
		ovl_padding = 5;
		ovl->items_per_page = 5;
	} else if (screen_w <= 1024) {
		// MLP1 960x720 — 720p height, narrow width
		ovl_scale = 2;
		ovl_padding = 10;
		ovl->items_per_page = 6;
	} else {
		// Smart Pro / TG5050 1280x720
		ovl_scale = 2;
		ovl_padding = 10;
		ovl->items_per_page = 8;
	}

	build_main_menu(ovl);

	// Screenshot directory for save/load slot previews.
	ovl->screenshot_dir[0] = '\0';
	ovl->rom_file[0] = '\0';
	const char* ss_dir = getenv("EMU_OVERLAY_SCREENSHOT_DIR");
	if (ss_dir && ss_dir[0] != '\0')
		snprintf(ovl->screenshot_dir, sizeof(ovl->screenshot_dir), "%s", ss_dir);
	const char* rom_file = getenv("EMU_OVERLAY_ROMFILE");
	if (rom_file && rom_file[0] != '\0')
		snprintf(ovl->rom_file, sizeof(ovl->rom_file), "%s", rom_file);

	// Init slot screenshot icons
	for (int i = 0; i < EMU_OVL_MAX_SLOTS; i++)
		ovl->slot_icons[i] = -1;

	// Note: caller is responsible for calling render->init() before emu_ovl_init
	return 0;
}

void emu_ovl_open(EmuOvl* ovl) {
	ovl->state = EMU_OVL_STATE_MAIN_MENU;
	ovl->selected = 0;
	ovl->action = EMU_OVL_ACTION_NONE;
	ovl->action_param = 0;
	ovl->save_slot = 0;
	ovl->quit_save = true;
	ovl->scroll_offset = 0;
	ovl->bind_capture = -1;

	if (ovl->render && ovl->render->capture_frame)
		ovl->render->capture_frame();

	// Pre-load all slot preview screenshots so they're ready before Save/Load
	// is highlighted.
	load_slot_screenshots(ovl);
}

bool emu_ovl_update(EmuOvl* ovl, EmuOvlInput* input) {
	if (ovl->state == EMU_OVL_STATE_CLOSED)
		return false;

	switch (ovl->state) {
	// ----- MAIN MENU -----
	case EMU_OVL_STATE_MAIN_MENU: {
		// Inline slot cycling when Save or Load is highlighted.
		EmuOvlMainItemType sel_type = ovl->main_items[ovl->selected].type;
		if (sel_type == EMU_OVL_MAIN_SAVE || sel_type == EMU_OVL_MAIN_LOAD) {
			if (input->left) {
				ovl->save_slot = (ovl->save_slot - 1 + EMU_OVL_MAX_SLOTS) % EMU_OVL_MAX_SLOTS;
			} else if (input->right) {
				ovl->save_slot = (ovl->save_slot + 1) % EMU_OVL_MAX_SLOTS;
			}
		} else if (sel_type == EMU_OVL_MAIN_QUIT && (input->left || input->right)) {
			ovl->quit_save = !ovl->quit_save;
		}
		if (input->up) {
			ovl->selected = (ovl->selected - 1 + ovl->main_item_count) % ovl->main_item_count;
		} else if (input->down) {
			ovl->selected = (ovl->selected + 1) % ovl->main_item_count;
		} else if (input->l1) {
			ovl->selected = page_jump(ovl->selected, ovl->main_item_count, ovl->items_per_page, -1);
		} else if (input->r1) {
			ovl->selected = page_jump(ovl->selected, ovl->main_item_count, ovl->items_per_page, +1);
		} else if (input->a) {
			EmuOvlMainItemType t = ovl->main_items[ovl->selected].type;
			switch (t) {
			case EMU_OVL_MAIN_CONTINUE:
				free_slot_screenshots(ovl);
				ovl->action = EMU_OVL_ACTION_CONTINUE;
				ovl->state = EMU_OVL_STATE_CLOSED;
				return false;
			case EMU_OVL_MAIN_SAVE:
				free_slot_screenshots(ovl);
				ovl->action = EMU_OVL_ACTION_SAVE_STATE;
				ovl->action_param = ovl->save_slot;
				ovl->state = EMU_OVL_STATE_CLOSED;
				return false;
			case EMU_OVL_MAIN_LOAD:
				free_slot_screenshots(ovl);
				ovl->action = EMU_OVL_ACTION_LOAD_STATE;
				ovl->action_param = ovl->save_slot;
				ovl->state = EMU_OVL_STATE_CLOSED;
				return false;
			case EMU_OVL_MAIN_OPTIONS:
				ovl->state = EMU_OVL_STATE_SECTION_LIST;
				ovl->selected = 0;
				ovl->scroll_offset = 0;
				ovl->current_section = 0;
				break;
			case EMU_OVL_MAIN_QUIT:
				free_slot_screenshots(ovl);
				ovl->action = ovl->quit_save ? EMU_OVL_ACTION_SAVE_AND_QUIT : EMU_OVL_ACTION_QUIT;
				ovl->state = EMU_OVL_STATE_CLOSED;
				return false;
			}
		} else if (input->b || input->menu) {
			free_slot_screenshots(ovl);
			ovl->action = EMU_OVL_ACTION_CONTINUE;
			ovl->state = EMU_OVL_STATE_CLOSED;
			return false;
		}
		break;
	}

	// ----- SECTION LIST -----
	case EMU_OVL_STATE_SECTION_LIST:
		{
		// +1 for "Save Changes" row at the bottom.
		int total_entries = ovl->config->section_count + 1;
		if (input->up) {
			ovl->selected = (ovl->selected - 1 + total_entries) % total_entries;
			ensure_scroll(ovl, total_entries);
		} else if (input->down) {
			ovl->selected = (ovl->selected + 1) % total_entries;
			ensure_scroll(ovl, total_entries);
		} else if (input->l1) {
			ovl->selected = page_jump(ovl->selected, total_entries, ovl->items_per_page, -1);
			ensure_scroll(ovl, total_entries);
		} else if (input->r1) {
			ovl->selected = page_jump(ovl->selected, total_entries, ovl->items_per_page, +1);
			ensure_scroll(ovl, total_entries);
		} else if (input->a) {
			if (ovl->selected == ovl->config->section_count) {
				// "Save Changes" row
				ovl->state = EMU_OVL_STATE_SAVE_CHANGES;
				ovl->selected = 0;
				ovl->scroll_offset = 0;
			} else {
				EmuOvlSection* sec = &ovl->config->sections[ovl->selected];
				if (strcmp(sec->name, "Cheats") == 0) {
					ovl->state = EMU_OVL_STATE_CHEATS;
				} else {
					ovl->current_section = ovl->selected;
					ovl->state = EMU_OVL_STATE_SECTION_ITEMS;
				}
				ovl->selected = 0;
				ovl->scroll_offset = 0;
			}
		} else if (input->b) {
			ovl->state = EMU_OVL_STATE_MAIN_MENU;
			ovl->selected = find_options_index(ovl);
		}
		}
		break;

	// ----- SECTION ITEMS -----
	case EMU_OVL_STATE_SECTION_ITEMS: {
		// During bind capture, the main loop owns input — skip here
		if (ovl->bind_capture >= 0)
			break;
		EmuOvlSection* sec = &ovl->config->sections[ovl->current_section];
		bool is_input = (strcmp(sec->name, "Controls") == 0);
		bool is_shortcuts = (strcmp(sec->name, "Shortcuts") == 0);
		int remap_rows = is_input ? N64_REMAP_COUNT : 0;
		int shortcut_rows = is_shortcuts ? emu_frontend_visible_shortcut_count() : 0;
		int total_rows = sec->item_count + remap_rows + shortcut_rows + 1; // items + [remaps|shortcuts] + reset
		if (input->up) {
			ovl->selected = (ovl->selected - 1 + total_rows) % total_rows;
			ensure_scroll(ovl, total_rows);
		} else if (input->down) {
			ovl->selected = (ovl->selected + 1) % total_rows;
			ensure_scroll(ovl, total_rows);
		} else if (input->l1) {
			ovl->selected = page_jump(ovl->selected, total_rows, ovl->items_per_page, -1);
			ensure_scroll(ovl, total_rows);
		} else if (input->r1) {
			ovl->selected = page_jump(ovl->selected, total_rows, ovl->items_per_page, +1);
			ensure_scroll(ovl, total_rows);
		} else if (input->right || input->a) {
			if (ovl->selected == total_rows - 1) {
				// "Reset to Default" (last row)
				emu_ovl_cfg_reset_section_to_defaults(sec);
				if (is_input) {
					N64ButtonMapping* mappings = emu_frontend_get_button_mappings();
					for (int i = 0; i < N64_REMAP_COUNT; i++) {
						mappings[i].physical = mappings[i].default_physical;
						mappings[i].is_axis = mappings[i].default_is_axis;
						mappings[i].axis_dir = mappings[i].default_axis_dir;
						mappings[i].mod = 0;
					}
					emu_frontend_write_button_map_file();
				}
				if (is_shortcuts) {
					for (int i = 0; i < shortcut_rows; i++) {
						ShortcutBinding* sc = emu_frontend_get_visible_shortcut(i);
						if (!sc)
							continue;
						sc->physical = -1;
						sc->is_axis = 0;
						sc->axis_dir = 0;
						sc->mod = 0;
					}
				}
			} else if (is_input && ovl->selected >= sec->item_count &&
					   ovl->selected < sec->item_count + remap_rows) {
				// Start bind capture for controls
				ovl->bind_capture = ovl->selected - sec->item_count;
				ovl->bind_capture_start = SDL_GetTicks();
			} else if (is_shortcuts && ovl->selected >= sec->item_count &&
					   ovl->selected < sec->item_count + shortcut_rows) {
				// Start bind capture for shortcuts (1000 + index)
				int storage_index = emu_frontend_visible_shortcut_storage_index(
					ovl->selected - sec->item_count);
				if (storage_index >= 0) {
					ovl->bind_capture = 1000 + storage_index;
					ovl->bind_capture_start = SDL_GetTicks();
				}
			} else if (ovl->selected < sec->item_count && sec->item_count > 0) {
				cycle_item_next(&sec->items[ovl->selected]);
			}
		} else if (input->left) {
			if (ovl->selected < sec->item_count && sec->item_count > 0)
				cycle_item_prev(&sec->items[ovl->selected]);
		} else if (input->b) {
			ovl->state = EMU_OVL_STATE_SECTION_LIST;
			ovl->selected = ovl->current_section;
			ovl->scroll_offset = 0;
			ensure_scroll(ovl, ovl->config->section_count);
		}
		break;
	}

	case EMU_OVL_STATE_CHEATS: {
		int count = ovl->cheat_cb.get_count ? ovl->cheat_cb.get_count() : 0;
		if (input->b) {
			ovl->state = EMU_OVL_STATE_SECTION_LIST;
			int cheats_idx = find_cheats_section_index(ovl);
			ovl->selected = (cheats_idx >= 0) ? cheats_idx : 0;
			ovl->scroll_offset = 0;
			ensure_scroll(ovl, ovl->config->section_count);
		} else if (count == 0) {
			break;
		} else if (input->up) {
			ovl->selected = (ovl->selected - 1 + count) % count;
			ensure_scroll(ovl, count);
		} else if (input->down) {
			ovl->selected = (ovl->selected + 1) % count;
			ensure_scroll(ovl, count);
		} else if (input->l1) {
			ovl->selected = page_jump(ovl->selected, count, ovl->items_per_page, -1);
			ensure_scroll(ovl, count);
		} else if (input->r1) {
			ovl->selected = page_jump(ovl->selected, count, ovl->items_per_page, +1);
			ensure_scroll(ovl, count);
		} else if (input->right || input->a) {
			if (ovl->cheat_cb.cycle_variant)
				ovl->cheat_cb.cycle_variant(ovl->selected, 1);
		} else if (input->left) {
			if (ovl->cheat_cb.cycle_variant)
				ovl->cheat_cb.cycle_variant(ovl->selected, -1);
		}
		break;
	}

	// ----- SAVE CHANGES submenu -----
	case EMU_OVL_STATE_SAVE_CHANGES: {
		// 3 items: Save for N64, Save for This Game, Restore Defaults
		int count = 3;
		if (input->up) {
			ovl->selected = (ovl->selected - 1 + count) % count;
		} else if (input->down) {
			ovl->selected = (ovl->selected + 1) % count;
		} else if (input->a) {
			switch (ovl->selected) {
			case 0: ovl->action = EMU_OVL_ACTION_SAVE_CONSOLE; break;
			case 1: ovl->action = EMU_OVL_ACTION_SAVE_GAME; break;
			case 2: ovl->action = EMU_OVL_ACTION_RESTORE_DEFAULTS; break;
			}
			// Return to main menu after action — emu_frontend handles the write
			ovl->state = EMU_OVL_STATE_MAIN_MENU;
			ovl->selected = 0;
			break;
		} else if (input->b || input->menu) {
			ovl->state = EMU_OVL_STATE_MAIN_MENU;
			ovl->selected = 0;
			break;
		}
		break;
	}

	case EMU_OVL_STATE_CLOSED:
		return false;
	}

	return true;
}

// ---------------------------------------------------------------------------
// Rendering — Jawaka in-game menu style.
// ---------------------------------------------------------------------------

static int apply_radius_ratio(const EmuOvl* ovl, int base_radius, int w, int h) {
	float ratio = ovl ? ovl->theme.pill_radius_ratio : 1.0f;
	int radius = (int)((float)base_radius * ratio + 0.5f);
	if (radius > h / 2)
		radius = h / 2;
	if (radius > w / 2)
		radius = w / 2;
	if (radius < 0)
		radius = 0;
	return radius;
}

// Pill-shaped rounded rect. Delegates to the backend's anti-aliased
// draw_rounded_rect implementation.
static void draw_pill(EmuOvl* ovl, int x, int y, int w, int h, uint32_t color) {
	EmuOvlRenderBackend* r = ovl->render;
	if (r->draw_rounded_rect)
		r->draw_rounded_rect(x, y, w, h, apply_radius_ratio(ovl, h / 2, w, h), color);
	else
		r->draw_rect(x, y, w, h, color);
}

static uint32_t footer_bg_color(uint32_t color) {
	return color_scale_alpha(color, FOOTER_UNDERLAY_ALPHA);
}

static int content_margin(void) {
	return S(24);
}

static int content_x(void) {
	return PADDING_PX + content_margin();
}

static int content_w(const EmuOvl* ovl) {
	return ovl->screen_w - (PADDING_PX + content_margin()) * 2;
}

static int content_top(void) {
	return PADDING_PX + S(58 + HEADER_CONTENT_GAP);
}

static int content_panel_top(void) {
	return content_top() + S(CONTENT_PANEL_TOP_TRIM);
}

static int content_bottom(const EmuOvl* ovl) {
	return ovl->screen_h - PADDING_PX - S(58);
}

static void draw_panel(EmuOvl* ovl, int x, int y, int w, int h, uint32_t color) {
	EmuOvlRenderBackend* r = ovl->render;
	if (w <= 0 || h <= 0)
		return;
	if (r->draw_rounded_rect)
		r->draw_rounded_rect(x, y, w, h,
							  apply_radius_ratio(ovl, S(PANEL_RADIUS), w, h), color);
	else
		r->draw_rect(x, y, w, h, color);
}

static void draw_content_panel(EmuOvl* ovl, int top, int bottom) {
	int x = PADDING_PX + S(8);
	int w = ovl->screen_w - x * 2;
	draw_panel(ovl, x, top, w, bottom - top, ovl->theme.panel);
}

// Compute vertically centered list_y for n items, reserving space for the
// title and footer areas used by Jawaka's in-game menu.
static int calc_centered_list_y(EmuOvl* ovl, int item_count) {
	int top = content_top() + S(12);
	int bottom = content_bottom(ovl) - S(10);
	int total_h = item_count * S(PILL_SIZE);
	int y = top + (bottom - top - total_h) / 2;
	// Never start above the content area — otherwise a list taller than the
	// available space centers upward and overlaps the header.
	if (y < top)
		y = top;
	return y;
}

// Strip ROM metadata from a game name: drop anything from the first " (" or
// " [" so "Legend of Zelda, The - Ocarina of Time (U) (V1.2) [!]" becomes
// "Legend of Zelda, The - Ocarina of Time". Truncates with "..." as a last
// resort if the result still won't fit in max_w pixels.
static void shorten_title(EmuOvlRenderBackend* r, const char* in, char* out,
						  int out_size, int max_w) {
	if (out_size <= 0)
		return;
	snprintf(out, out_size, "%s", in);
	// Strip metadata
	char* cut = strstr(out, " (");
	char* cut2 = strstr(out, " [");
	if (cut2 && (!cut || cut2 < cut))
		cut = cut2;
	if (cut)
		*cut = '\0';
	if (r->text_width(out, EMU_OVL_FONT_LARGE) <= max_w)
		return;
	// Still too long — truncate and append "..."
	int len = (int)strlen(out);
	while (len > 0) {
		out[--len] = '\0';
		char buf[256];
		snprintf(buf, sizeof(buf), "%s...", out);
		if (r->text_width(buf, EMU_OVL_FONT_LARGE) <= max_w) {
			snprintf(out, out_size, "%s", buf);
			return;
		}
	}
}

// ---------------------------------------------------------------------------
// Status bar (wifi / battery / clock) — mirrors the Catastrophe IGM header.
// Drawn with themed primitives so it tracks the active theme color; honors the
// same CAT_STATUS_* env vars Leaf's env.sh sets for the launcher.
// ---------------------------------------------------------------------------

// Battery charge 0..100, or -1 if no power-supply node is readable.
static int read_battery_percent(void) {
	DIR* d = opendir("/sys/class/power_supply");
	if (!d)
		return -1;
	int pct = -1;
	struct dirent* e;
	while ((e = readdir(d)) != NULL) {
		if (e->d_name[0] == '.')
			continue;
		char path[300];
		snprintf(path, sizeof(path), "/sys/class/power_supply/%s/capacity", e->d_name);
		FILE* f = fopen(path, "r");
		if (!f)
			continue;
		int v;
		int ok = fscanf(f, "%d", &v);
		fclose(f);
		if (ok == 1) {
			pct = v < 0 ? 0 : (v > 100 ? 100 : v);
			break;
		}
	}
	closedir(d);
	return pct;
}

// Wifi signal strength 0..3, or -1 if /proc/net/wireless has no entry.
static int read_wifi_strength(void) {
	FILE* f = fopen("/proc/net/wireless", "r");
	if (!f)
		return -1;
	char line[256];
	int strength = -1;
	// Skip the two header lines.
	if (fgets(line, sizeof(line), f) && fgets(line, sizeof(line), f)) {
		while (fgets(line, sizeof(line), f) != NULL) {
			char iface[32];
			int status;
			float link;
			if (sscanf(line, " %31[^:]: %d %f", iface, &status, &link) >= 3) {
				int q = (int)link; // typically 0..70
				if (q <= 0)
					strength = 0;
				else if (q < 24)
					strength = 1;
				else if (q < 47)
					strength = 2;
				else
					strength = 3;
				break;
			}
		}
	}
	fclose(f);
	return strength;
}

// Draw an outlined battery glyph whose right edge is at `right`, returning width.
static int draw_status_battery(EmuOvl* ovl, int right, int cy) {
	EmuOvlRenderBackend* r = ovl->render;
	int bw = S(22), bh = S(12), nub_w = S(2), nub_h = S(6), border = S(2);
	int total_w = bw + nub_w;
	int x = right - total_w;
	int y = cy - bh / 2;
	uint32_t fg = ovl->theme.text;

	// Outline = filled body knocked out by the panel/background color.
	r->draw_rounded_rect(x, y, bw, bh, S(2), fg);
	r->draw_rounded_rect(x + border, y + border, bw - 2 * border, bh - 2 * border,
						 S(1), ovl->theme.background);
	r->draw_rect(x + bw, cy - nub_h / 2, nub_w, nub_h, fg);

	int pct = read_battery_percent();
	if (pct >= 0) {
		int inner_x = x + border + S(1);
		int inner_y = y + border + S(1);
		int inner_w = bw - 2 * border - S(2);
		int inner_h = bh - 2 * border - S(2);
		int fill = inner_w * pct / 100;
		if (fill < S(1) && pct > 0)
			fill = S(1);
		uint32_t fillc = (pct <= 15) ? 0xFFE05050u : fg; // low charge → red
		if (fill > 0)
			r->draw_rect(inner_x, inner_y, fill, inner_h, fillc);
	}
	return total_w;
}

// Draw 3 ascending wifi bars whose right edge is at `right`, returning width.
static int draw_status_wifi(EmuOvl* ovl, int right, int cy) {
	EmuOvlRenderBackend* r = ovl->render;
	const int bars = 3;
	int bw = S(3), gap = S(2), maxh = S(12);
	int total_w = bars * bw + (bars - 1) * gap;
	int x = right - total_w;
	int base_y = cy + maxh / 2;
	int strength = read_wifi_strength();
	for (int i = 0; i < bars; i++) {
		int h = maxh * (i + 1) / bars;
		uint32_t c = (strength > i) ? ovl->theme.text
								    : color_with_alpha(ovl->theme.hint, 90);
		r->draw_rect(x + i * (bw + gap), base_y - h, bw, h, c);
	}
	return total_w;
}

// Draw the status cluster right-aligned, vertically centered on `center_y`.
static void draw_status_bar(EmuOvl* ovl, int center_y) {
	EmuOvlRenderBackend* r = ovl->render;
	int x = ovl->screen_w - PADDING_PX - content_margin();
	int gap = S(10);

	// Clock (rightmost).
	const char* clock = getenv("CAT_STATUS_CLOCK");
	bool show_clock = !clock || (strcmp(clock, "0") != 0 && strcmp(clock, "off") != 0);
	if (show_clock) {
		bool h12 = clock && strcmp(clock, "12") == 0;
		time_t t = time(NULL);
		struct tm tmv;
		localtime_r(&t, &tmv);
		char buf[16];
		strftime(buf, sizeof(buf), h12 ? "%I:%M" : "%H:%M", &tmv);
		int tw = r->text_width(buf, EMU_OVL_FONT_SMALL);
		int th = r->text_height(EMU_OVL_FONT_SMALL);
		r->draw_text(buf, x - tw, center_y - th / 2, ovl->theme.text, EMU_OVL_FONT_SMALL);
		x -= tw + gap;
	}

	if (parse_theme_bool(getenv("CAT_STATUS_SHOW_BATTERY"), true)) {
		int w = draw_status_battery(ovl, x, center_y);
		x -= w + gap;
	}

	if (parse_theme_bool(getenv("CAT_STATUS_SHOW_WIFI"), true)) {
		int w = draw_status_wifi(ovl, x, center_y);
		x -= w + gap;
	}
}

// Draw the title like Jawaka's in-game header: themed text over a soft panel,
// with an optional console subtitle and the status cluster on the right.
static void draw_menu_bar(EmuOvl* ovl, const char* title, const char* subtitle) {
	EmuOvlRenderBackend* r = ovl->render;
	int pad = content_margin();
	int title_h = r->text_height(EMU_OVL_FONT_LARGE);
	int sub_h = subtitle ? r->text_height(EMU_OVL_FONT_SMALL) : 0;
	int sub_gap = subtitle ? S(2) : 0;
	int top_pad = S(10);

	// Available inner width = screen - side padding - pill internal padding
	int max_inner_w = ovl->screen_w - PADDING_PX * 2 - pad * 2;
	char display[256];
	shorten_title(r, title, display, sizeof(display), max_inner_w);

	int panel_y = PADDING_PX + S(4);
	int panel_h = top_pad * 2 + title_h + sub_gap + sub_h;
	draw_content_panel(ovl, panel_y, panel_y + panel_h);

	int title_y = panel_y + top_pad;
	r->draw_text(display, content_x(), title_y, ovl->theme.text, EMU_OVL_FONT_LARGE);
	if (subtitle && subtitle[0])
		r->draw_text(subtitle, content_x(), title_y + title_h + sub_gap,
					 ovl->theme.hint, EMU_OVL_FONT_SMALL);

	draw_status_bar(ovl, title_y + title_h / 2);
}

static size_t utf8_codepoint_count(const char* text) {
	size_t count = 0;
	if (!text)
		return 0;
	while (*text) {
		if ((((unsigned char)*text) & 0xC0u) != 0x80u)
			count++;
		text++;
	}
	return count;
}

static bool footer_button_text_is_single_codepoint(const char* text) {
	return utf8_codepoint_count(text) == 1;
}

static int footer_button_font_id(const char* btn) {
	return footer_button_text_is_single_codepoint(btn) ?
		EMU_OVL_FONT_MEDIUM : EMU_OVL_FONT_TINY;
}

static bool is_nav_button_glyph(const char* btn) {
	return strcmp(btn, HINT_LEFT_RIGHT) == 0 ||
		   strcmp(btn, HINT_UP_DOWN) == 0;
}

static int nav_button_glyph_width(int btn_inner_h) {
	return btn_inner_h + (btn_inner_h * 2) / 3;
}

// Measure a button glyph's width.
static int measure_button_glyph(EmuOvl* ovl, const char* btn, int btn_inner_h) {
	EmuOvlRenderBackend* r = ovl->render;
	if (is_nav_button_glyph(btn))
		return nav_button_glyph_width(btn_inner_h);
	if (footer_button_text_is_single_codepoint(btn))
		return btn_inner_h;
	int tw = r->text_width(btn, footer_button_font_id(btn));
	return btn_inner_h / 2 + tw;
}

static void draw_thick_line(EmuOvl* ovl, int x0, int y0, int x1, int y1,
							int thickness, uint32_t color) {
	EmuOvlRenderBackend* r = ovl->render;
	if (thickness < 1)
		thickness = 1;
	int half = thickness / 2;
	int dx = abs(x1 - x0);
	int sx = x0 < x1 ? 1 : -1;
	int dy = -abs(y1 - y0);
	int sy = y0 < y1 ? 1 : -1;
	int err = dx + dy;

	for (;;) {
		r->draw_rect(x0 - half, y0 - half, thickness, thickness, color);
		if (x0 == x1 && y0 == y1)
			break;
		int e2 = 2 * err;
		if (e2 >= dy) {
			err += dy;
			x0 += sx;
		}
		if (e2 <= dx) {
			err += dx;
			y0 += sy;
		}
	}
}

typedef enum {
	NAV_CHEVRON_LEFT,
	NAV_CHEVRON_RIGHT,
	NAV_CHEVRON_UP,
	NAV_CHEVRON_DOWN
} NavChevronDir;

static void draw_nav_chevron(EmuOvl* ovl, int cx, int cy, int half,
							 int thickness, NavChevronDir dir, uint32_t color) {
	switch (dir) {
	case NAV_CHEVRON_LEFT:
		draw_thick_line(ovl, cx + half, cy - half, cx - half, cy, thickness, color);
		draw_thick_line(ovl, cx - half, cy, cx + half, cy + half, thickness, color);
		break;
	case NAV_CHEVRON_RIGHT:
		draw_thick_line(ovl, cx - half, cy - half, cx + half, cy, thickness, color);
		draw_thick_line(ovl, cx + half, cy, cx - half, cy + half, thickness, color);
		break;
	case NAV_CHEVRON_UP:
		draw_thick_line(ovl, cx - half, cy + half, cx, cy - half, thickness, color);
		draw_thick_line(ovl, cx, cy - half, cx + half, cy + half, thickness, color);
		break;
	case NAV_CHEVRON_DOWN:
		draw_thick_line(ovl, cx - half, cy - half, cx, cy + half, thickness, color);
		draw_thick_line(ovl, cx, cy + half, cx + half, cy - half, thickness, color);
		break;
	}
}

static void draw_nav_button_glyph(EmuOvl* ovl, const char* btn, int gx, int gy,
								  int w, int btn_inner_h) {
	int cy = gy + btn_inner_h / 2;
	int gap = btn_inner_h / 4 + S(1);
	int half = btn_inner_h / 5;
	int thickness = btn_inner_h / 10;
	if (thickness < S(1))
		thickness = S(1);
	int left_cx = gx + w / 2 - gap;
	int right_cx = gx + w / 2 + gap;

	if (strcmp(btn, HINT_LEFT_RIGHT) == 0) {
		draw_nav_chevron(ovl, left_cx, cy, half, thickness,
						 NAV_CHEVRON_LEFT, ovl->theme.button_label);
		draw_nav_chevron(ovl, right_cx, cy, half, thickness,
						 NAV_CHEVRON_RIGHT, ovl->theme.button_label);
	} else {
		draw_nav_chevron(ovl, left_cx, cy, half, thickness,
						 NAV_CHEVRON_UP, ovl->theme.button_label);
		draw_nav_chevron(ovl, right_cx, cy, half, thickness,
						 NAV_CHEVRON_DOWN, ovl->theme.button_label);
	}
}

// Draw a single button glyph at (gx, gy). btn_inner_h is the inner pill height.
static int draw_button_glyph(EmuOvl* ovl, const char* btn, int gx, int gy,
							 int btn_inner_h) {
	EmuOvlRenderBackend* r = ovl->render;
	if (is_nav_button_glyph(btn)) {
		int w = nav_button_glyph_width(btn_inner_h);
		draw_pill(ovl, gx, gy, w, btn_inner_h,
				  footer_bg_color(ovl->theme.button_glyph_bg));
		draw_nav_button_glyph(ovl, btn, gx, gy, w, btn_inner_h);
		return w;
	}

	int font_id = footer_button_font_id(btn);
	if (footer_button_text_is_single_codepoint(btn)) {
		// Jawaka footer glyph: accent circle with light text.
		draw_pill(ovl, gx, gy, btn_inner_h, btn_inner_h,
				  footer_bg_color(ovl->theme.button_glyph_bg));
		int tw = r->text_width(btn, font_id);
		int th = r->text_height(font_id);
		r->draw_text(btn, gx + (btn_inner_h - tw) / 2,
					 gy + (btn_inner_h - th) / 2,
					 ovl->theme.button_label, font_id);
		return btn_inner_h;
	}
	int tw = r->text_width(btn, font_id);
	int w = btn_inner_h / 2 + tw;
	draw_pill(ovl, gx, gy, w, btn_inner_h,
			  footer_bg_color(ovl->theme.button_glyph_bg));
	int th = r->text_height(font_id);
	r->draw_text(btn, gx + btn_inner_h / 4, gy + (btn_inner_h - th) / 2,
				 ovl->theme.button_label, font_id);
	return w;
}

// Draw a button-hint group inside a themed rounded outer pill.
// Entries alternate: button_label, action_label, button_label, action_label, …
// align_right = true → bottom-right anchored, else bottom-left.
//
// Uses the same paired button/action rhythm as Jawaka's footer.
static void draw_button_group(EmuOvl* ovl, const char* hints[], int hint_count,
							  bool align_right) {
	EmuOvlRenderBackend* r = ovl->render;
	int pill_h = S(PILL_SIZE);
	int inner_h = S(BUTTON_SIZE);
	int bm = S(BUTTON_MARGIN);

	// Pass 1: measure total width.
	int group_w = bm;
	for (int i = 0; i < hint_count; i += 2) {
		int pair_w = measure_button_glyph(ovl, hints[i], inner_h);
		pair_w += bm;
		if (i + 1 < hint_count)
			pair_w += r->text_width(hints[i + 1], EMU_OVL_FONT_SMALL);
		pair_w += bm;
		group_w += bm + pair_w;
	}
	int x = align_right ? (ovl->screen_w - PADDING_PX - group_w) : PADDING_PX;
	int y = ovl->screen_h - PADDING_PX - pill_h;

	// Outer theme-coloured pill, matching Jawaka's footer underlay.
	draw_pill(ovl, x, y, group_w, pill_h, footer_bg_color(ovl->theme.accent));

	// Pass 2: draw contents. Start at x + BM, advance by (pair_w + BM) per pair.
	int cx = x + bm;
	int inner_y = y + (pill_h - inner_h) / 2;
	int text_y = y + (pill_h - r->text_height(EMU_OVL_FONT_SMALL)) / 2;
	for (int i = 0; i < hint_count; i += 2) {
		int gw = draw_button_glyph(ovl, hints[i], cx, inner_y, inner_h);
		int label_x = cx + gw + bm;
		int label_w = 0;
		if (i + 1 < hint_count) {
			r->draw_text(hints[i + 1], label_x, text_y,
						 ovl->theme.hint, EMU_OVL_FONT_SMALL);
			label_w = r->text_width(hints[i + 1], EMU_OVL_FONT_SMALL);
		}
		// pair_w = gw + bm + label_w + bm; advance by pair_w + bm
		cx += gw + bm + label_w + bm + bm;
	}
}

// Is this button a navigation hint (d-pad, L/R, etc.) that should go in the
// left-aligned group?
static bool is_nav_hint(const char* btn) {
	return strcmp(btn, "LEFT/RIGHT") == 0 ||
		   strcmp(btn, "UP/DOWN") == 0 ||
		   strcmp(btn, HINT_LEFT_RIGHT) == 0 ||
		   strcmp(btn, HINT_UP_DOWN) == 0 ||
		   strcmp(btn, "L/R") == 0 ||
		   strcmp(btn, "L1/R1") == 0;
}

// Draw the full bottom hint row, splitting navigation hints left and actions
// right like Jawaka's in-game footer.
static void draw_footer_hints(EmuOvl* ovl, const char* hints[], int hint_count) {
	if (!ovl->theme.show_hints)
		return;

	const char* left[16];
	const char* right[16];
	int left_count = 0;
	int right_count = 0;
	for (int i = 0; i + 1 < hint_count; i += 2) {
		if (is_nav_hint(hints[i])) {
			if (left_count + 1 < (int)(sizeof(left) / sizeof(left[0]))) {
				left[left_count++] = hints[i];
				left[left_count++] = hints[i + 1];
			}
		} else {
			if (right_count + 1 < (int)(sizeof(right) / sizeof(right[0]))) {
				right[right_count++] = hints[i];
				right[right_count++] = hints[i + 1];
			}
		}
	}

	if (left_count > 0)
		draw_button_group(ovl, left, left_count, false);
	if (right_count > 0)
		draw_button_group(ovl, right, right_count, true);
}

// Draw an in-game menu row (label on left, optional value on right).
static void draw_settings_row(EmuOvl* ovl, int x, int y, int w, int h,
							  const char* label, const char* value,
							  bool selected, bool cycleable, int label_font) {
	EmuOvlRenderBackend* r = ovl->render;
	int row_pad = S(BUTTON_PADDING);

	if (selected) {
		draw_pill(ovl, x - S(10), y + S(2), w, h - S(4), ovl->theme.highlight);
		if (value) {
			int text_y_pos = y + (h - r->text_height(label_font)) / 2;
			r->draw_text(label, x + row_pad, text_y_pos,
						 ovl->theme.highlighted_text, label_font);

			char display[192];
			if (cycleable)
				snprintf(display, sizeof(display), "< %s >", value);
			else
				snprintf(display, sizeof(display), "%s", value);

			int vw = r->text_width(display, EMU_OVL_FONT_TINY);
			int val_x = x + w - row_pad - vw;
			int val_y = y + (h - r->text_height(EMU_OVL_FONT_TINY)) / 2;
			r->draw_text(display, val_x, val_y, ovl->theme.highlighted_text, EMU_OVL_FONT_TINY);
		} else {
			int text_y_pos = y + (h - r->text_height(label_font)) / 2;
			r->draw_text(label, x + row_pad, text_y_pos,
						 ovl->theme.highlighted_text, label_font);
		}
	} else {
		// Unselected: the underlay guarantees contrast over the paused frame.
		int text_y_pos = y + (h - r->text_height(label_font)) / 2;
		r->draw_text(label, x + row_pad, text_y_pos,
					 ovl->theme.text, label_font);

		if (value) {
			int vw = r->text_width(value, EMU_OVL_FONT_TINY);
			int val_x = x + w - row_pad - vw;
			int val_y = y + (h - r->text_height(EMU_OVL_FONT_TINY)) / 2;
			r->draw_text(value, val_x, val_y, ovl->theme.hint, EMU_OVL_FONT_TINY);
		}
	}
}

static void draw_centered_text(EmuOvlRenderBackend* r, const char* text, int cx, int cy,
							   uint32_t color, int font_id) {
	int tw = r->text_width(text, font_id);
	int th = r->text_height(font_id);
	r->draw_text(text, cx - tw / 2, cy - th / 2, color, font_id);
}

static void render_main_menu(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;

	draw_menu_bar(ovl, ovl->game_name, ovl->console_name);
	draw_content_panel(ovl, content_panel_top(), content_bottom(ovl));

	int row_h = S(PILL_SIZE);
	int x = content_x();
	int w = content_w(ovl);

	int vis_count = ovl->main_item_count;
	if (vis_count > ovl->items_per_page)
		vis_count = ovl->items_per_page;
	int list_y = calc_centered_list_y(ovl, vis_count);

	EmuOvlMainItemType sel_type = ovl->main_items[ovl->selected].type;
	bool preview_active = (sel_type == EMU_OVL_MAIN_SAVE || sel_type == EMU_OVL_MAIN_LOAD);
	int menu_w = preview_active ? (w * 62 / 100) : w;

	for (int i = 0; i < vis_count; i++) {
		int iy = list_y + i * row_h;
		bool sel = (i == ovl->selected);
		draw_settings_row(ovl, x, iy, menu_w, row_h,
						  main_item_label(ovl, i), NULL, sel, false,
						  EMU_OVL_FONT_LARGE);
	}

	if (preview_active) {
		int gap = S(14);
		int pv_x = x + menu_w + gap;
		int pv_w = x + w - pv_x;
		int pv_h = pv_w * 3 / 4;
		int max_h = content_bottom(ovl) - list_y - S(42);
		if (pv_h > max_h)
			pv_h = max_h;
		int pv_y = list_y;
		draw_panel(ovl, pv_x, pv_y, pv_w, pv_h, ovl->theme.preview_bg);
		int icon_id = ovl->slot_icons[ovl->save_slot];
		if (icon_id >= 0 && r->draw_icon) {
			r->draw_icon(icon_id, pv_x, pv_y);
		} else {
			draw_centered_text(r, "No save in this slot",
							   pv_x + pv_w / 2, pv_y + pv_h / 2,
							   ovl->theme.text, EMU_OVL_FONT_SMALL);
		}

		int dot_spacing = S(15);
		int dots_total_w = dot_spacing * EMU_OVL_MAX_SLOTS;
		int dots_x = pv_x + (pv_w - dots_total_w) / 2;
		int dots_y = pv_y + pv_h + S(12);
		for (int i = 0; i < EMU_OVL_MAX_SLOTS; i++) {
			int dx = dots_x + i * dot_spacing;
			if (i == ovl->save_slot) {
				draw_pill(ovl, dx, dots_y, S(6), S(6), ovl->theme.highlight);
			} else {
				draw_pill(ovl, dx + S(2), dots_y + S(2), S(2), S(2), ovl->theme.hint);
			}
		}
	}

	if (sel_type == EMU_OVL_MAIN_CONTINUE) {
		const char* hints[] = {HINT_UP_DOWN, "Move", "A", "Resume", "B", "Resume"};
		draw_footer_hints(ovl, hints, 6);
	} else {
		const char* hints[] = {
			HINT_UP_DOWN, "Move", HINT_LEFT_RIGHT, "Adjust", "B", "Resume", "A", "OK"};
		draw_footer_hints(ovl, hints, 8);
	}
}

static void render_section_list(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;

	draw_menu_bar(ovl, "Options", NULL);
	draw_content_panel(ovl, content_panel_top(), content_bottom(ovl));

	int row_h = S(PILL_SIZE);
	int x = content_x();
	int w = content_w(ovl);

	// +1 for "Save Changes" row at the bottom
	int total_count = ovl->config->section_count + 1;

	// Scroll
	ensure_scroll(ovl, total_count);

	int vis_count = ovl->items_per_page;
	if (vis_count > total_count)
		vis_count = total_count;
	int list_y = calc_centered_list_y(ovl, vis_count);

	for (int vi = 0; vi < vis_count; vi++) {
		int idx = ovl->scroll_offset + vi;
		if (idx >= total_count)
			break;

		int iy = list_y + vi * row_h;
		bool sel = (idx == ovl->selected);
		const char* name;
		if (idx < ovl->config->section_count)
			name = ovl->config->sections[idx].name;
		else
			name = "Save Changes";
		draw_settings_row(ovl, x, iy, w, row_h,
						  name, NULL, sel, false, EMU_OVL_FONT_LARGE);
	}

	// Optional hint (e.g. "Restart game to apply changes")
	if (ovl->config->options_hint[0] != '\0') {
		int hint_y = list_y + vis_count * row_h + S(4);
		int tw = r->text_width(ovl->config->options_hint, EMU_OVL_FONT_TINY);
		r->draw_text(ovl->config->options_hint,
					 (ovl->screen_w - tw) / 2, hint_y,
					 ovl->theme.hint, EMU_OVL_FONT_TINY);
	}

	const char* hints[] = {HINT_UP_DOWN, "Move", "B", "Back", "A", "Open"};
	draw_footer_hints(ovl, hints, 6);
}

static void render_section_items(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;
	EmuOvlSection* sec = &ovl->config->sections[ovl->current_section];

	draw_menu_bar(ovl, sec->name, NULL);
	draw_content_panel(ovl, content_panel_top(), content_bottom(ovl));

	int row_h = S(PILL_SIZE);
	int items_per_page = ovl->items_per_page;
	int list_y = calc_centered_list_y(ovl, items_per_page);
	int x = content_x();
	int w = content_w(ovl);

	bool is_input = (strcmp(sec->name, "Controls") == 0);
	bool is_shortcuts = (strcmp(sec->name, "Shortcuts") == 0);
	int remap_rows = is_input ? N64_REMAP_COUNT : 0;
	int shortcut_rows = is_shortcuts ? emu_frontend_visible_shortcut_count() : 0;
	int total_rows = sec->item_count + remap_rows + shortcut_rows + 1;

	// Scroll
	ensure_scroll(ovl, total_rows);

	int vis_count = items_per_page;
	if (vis_count > total_rows)
		vis_count = total_rows;

	N64ButtonMapping* mappings = is_input ? emu_frontend_get_button_mappings() : NULL;
	for (int vi = 0; vi < vis_count; vi++) {
		int idx = ovl->scroll_offset + vi;
		if (idx >= total_rows)
			break;

		int iy = list_y + vi * row_h;
		bool sel = (idx == ovl->selected);

		if (idx < sec->item_count) {
			// Normal config item
			EmuOvlItem* item = &sec->items[idx];
			char val_buf[64];
			const char* val_str = get_item_display_value(item, val_buf, sizeof(val_buf));
			draw_settings_row(ovl, x, iy, w, row_h,
							  item->label, val_str, sel, true,
							  EMU_OVL_FONT_SMALL);
		} else if (is_input && idx < sec->item_count + remap_rows) {
			// Button remap row
			int ri = idx - sec->item_count;
			const char* val;
			char countdown_buf[16];
			if (ovl->bind_capture == ri) {
				unsigned int elapsed = SDL_GetTicks() - ovl->bind_capture_start;
				if (elapsed < 500) {
					val = "...";
				} else {
					int remaining = (int)(5500 - elapsed) / 1000 + 1;
					if (remaining < 1) remaining = 1;
					if (remaining > 5) remaining = 5;
					snprintf(countdown_buf, sizeof(countdown_buf), "%d...", remaining);
					val = countdown_buf;
				}
			} else {
				val = emu_frontend_binding_label(&mappings[ri]);
			}
			draw_settings_row(ovl, x, iy, w, row_h,
							  mappings[ri].name, val, sel, false,
							  EMU_OVL_FONT_SMALL);
		} else if (is_shortcuts && idx >= sec->item_count &&
				   idx < sec->item_count + shortcut_rows) {
			// Shortcut binding row
			int si = idx - sec->item_count;
			int storage_index = emu_frontend_visible_shortcut_storage_index(si);
			ShortcutBinding* shortcut = emu_frontend_get_visible_shortcut(si);
			if (!shortcut)
				continue;
			const char* val;
			char countdown_buf[16];
			int bc_idx = ovl->bind_capture - 1000;
			if (ovl->bind_capture >= 1000 && bc_idx == storage_index) {
				unsigned int elapsed = SDL_GetTicks() - ovl->bind_capture_start;
				if (elapsed < 500) {
					val = "...";
				} else {
					int remaining = (int)(5500 - elapsed) / 1000 + 1;
					if (remaining < 1) remaining = 1;
					if (remaining > 5) remaining = 5;
					snprintf(countdown_buf, sizeof(countdown_buf), "%d...", remaining);
					val = countdown_buf;
				}
			} else {
				val = emu_frontend_shortcut_label(shortcut);
			}
			draw_settings_row(ovl, x, iy, w, row_h,
							  shortcut->label, val, sel, false,
							  EMU_OVL_FONT_SMALL);
		} else {
			// "Reset to Default" row (last)
			draw_settings_row(ovl, x, iy, w, row_h,
							  "Reset to Default", NULL, sel, false,
							  EMU_OVL_FONT_SMALL);
		}
	}

	// Description for selected item / hint text area
	int desc_y = list_y + vis_count * row_h;
	int desc_cy = desc_y + row_h / 2 - r->text_height(EMU_OVL_FONT_TINY) / 2;

	if (ovl->selected < sec->item_count) {
		EmuOvlItem* sel_item = &sec->items[ovl->selected];
		if (sel_item->description[0] != '\0') {
			int tw = r->text_width(sel_item->description, EMU_OVL_FONT_TINY);
			r->draw_text(sel_item->description,
						 (ovl->screen_w - tw) / 2, desc_cy,
						 ovl->theme.hint, EMU_OVL_FONT_TINY);
		}
	}

	const char* hints[] = {HINT_UP_DOWN, "Move", HINT_LEFT_RIGHT, "Adjust", "B", "Back"};
	draw_footer_hints(ovl, hints, 6);
}

static void render_cheats(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;
	draw_menu_bar(ovl, "Cheats", NULL);
	draw_content_panel(ovl, content_panel_top(), content_bottom(ovl));

	int count = ovl->cheat_cb.get_count ? ovl->cheat_cb.get_count() : 0;

	if (count == 0) {
		draw_centered_text(r, "No cheats available", ovl->screen_w / 2,
						   ovl->screen_h / 2, ovl->theme.hint, EMU_OVL_FONT_SMALL);
		const char* hints[] = {"B", "Back"};
		draw_footer_hints(ovl, hints, 2);
		return;
	}

	int row_h = S(PILL_SIZE);
	int items_per_page = ovl->items_per_page;
	int list_y = calc_centered_list_y(ovl, items_per_page);
	int x = content_x();
	int w = content_w(ovl);

	// Scroll
	ensure_scroll(ovl, count);

	int vis_count = items_per_page;
	if (vis_count > count)
		vis_count = count;

	for (int vi = 0; vi < vis_count; vi++) {
		int idx = ovl->scroll_offset + vi;
		if (idx >= count)
			break;

		int iy = list_y + vi * row_h;
		bool sel = (idx == ovl->selected);

		const char* name = ovl->cheat_cb.get_name ? ovl->cheat_cb.get_name(idx) : "???";
		const char* val = ovl->cheat_cb.get_value_label ? ovl->cheat_cb.get_value_label(idx) : "OFF";
		draw_settings_row(ovl, x, iy, w, row_h,
						  name, val, sel, true, EMU_OVL_FONT_SMALL);
	}

	// Description for selected cheat (inline, matching settings pattern)
	int desc_y = list_y + vis_count * row_h;
	int desc_cy = desc_y + row_h / 2 - r->text_height(EMU_OVL_FONT_TINY) / 2;
	const char* desc = ovl->cheat_cb.get_description ? ovl->cheat_cb.get_description(ovl->selected) : NULL;
	if (desc && desc[0] != '\0') {
		int tw = r->text_width(desc, EMU_OVL_FONT_TINY);
		r->draw_text(desc, (ovl->screen_w - tw) / 2, desc_cy,
					 ovl->theme.hint, EMU_OVL_FONT_TINY);
	}

	const char* hints[] = {HINT_UP_DOWN, "Move", HINT_LEFT_RIGHT, "Adjust", "B", "Back"};
	draw_footer_hints(ovl, hints, 6);
}

static const char* scope_label(EmuConfigScope scope) {
	switch (scope) {
	case EMU_SCOPE_NONE:    return "Using N64 defaults.";
	case EMU_SCOPE_CONSOLE: return "Using N64 settings.";
	case EMU_SCOPE_GAME:    return "Using this game's settings.";
	}
	return "";
}

static void render_save_changes(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;

	draw_menu_bar(ovl, "Save Changes", NULL);
	draw_content_panel(ovl, content_panel_top(), content_bottom(ovl));

	// Scope indicator below the title
	const char* desc = scope_label(ovl->scope);
	int desc_y = content_top() + S(12);
	r->draw_text(desc, content_x() + S(BUTTON_PADDING), desc_y,
				 ovl->theme.hint, EMU_OVL_FONT_TINY);

	// 3 rows: Save for N64, Save for This Game, Restore Defaults
	static const char* items[] = {
		"Save for N64", "Save for This Game", "Restore Defaults"
	};
	int row_h = S(PILL_SIZE);
	int x = content_x();
	int w = content_w(ovl);
	int list_y = calc_centered_list_y(ovl, 3);

	for (int i = 0; i < 3; i++) {
		int iy = list_y + i * row_h;
		bool sel = (i == ovl->selected);
		draw_settings_row(ovl, x, iy, w, row_h,
						  items[i], NULL, sel, false, EMU_OVL_FONT_LARGE);
	}

	const char* hints[] = {"B", "Back", "A", "Save"};
	draw_footer_hints(ovl, hints, 4);
}

void emu_ovl_render(EmuOvl* ovl) {
	if (ovl->state == EMU_OVL_STATE_CLOSED)
		return;

	EmuOvlRenderBackend* r = ovl->render;
	if (!r)
		return;

	r->begin_frame();
	r->draw_captured_frame(0.42f);

	switch (ovl->state) {
	case EMU_OVL_STATE_MAIN_MENU:
		render_main_menu(ovl);
		break;
	case EMU_OVL_STATE_SECTION_LIST:
		render_section_list(ovl);
		break;
	case EMU_OVL_STATE_SECTION_ITEMS:
		render_section_items(ovl);
		break;
	case EMU_OVL_STATE_CHEATS:
		render_cheats(ovl);
		break;
	case EMU_OVL_STATE_SAVE_CHANGES:
		render_save_changes(ovl);
		break;
	case EMU_OVL_STATE_CLOSED:
		break;
	}

	r->end_frame();
}

bool emu_ovl_is_active(EmuOvl* ovl) {
	return ovl->state != EMU_OVL_STATE_CLOSED;
}

EmuOvlAction emu_ovl_get_action(EmuOvl* ovl) {
	return ovl->action;
}

int emu_ovl_get_action_param(EmuOvl* ovl) {
	return ovl->action_param;
}

int emu_ovl_save_slot_screenshot(EmuOvl* ovl, int slot) {
	if (!ovl || !ovl->render || !ovl->render->save_captured_frame)
		return -1;
	if (slot < 0 || slot >= EMU_OVL_MAX_SLOTS)
		return -1;
	if (ovl->screenshot_dir[0] == '\0' || ovl->rom_file[0] == '\0')
		return -1;

	char path[512];
	get_slot_screenshot_path(ovl, slot, path, sizeof(path));
	int ret = ovl->render->save_captured_frame(path);

	// Write resume slot file for game switcher
	if (ret == 0)
		write_resume_slot(ovl, slot);

	return ret;
}

void emu_ovl_render_status(EmuOvl* ovl, const char* message) {
	if (!ovl || !ovl->render)
		return;

	EmuOvlRenderBackend* r = ovl->render;
	r->begin_frame();
	r->draw_captured_frame(0.42f);
	draw_menu_bar(ovl, ovl->game_name, ovl->console_name);
	draw_content_panel(ovl, content_panel_top(), content_bottom(ovl));
	draw_centered_text(r, message && message[0] ? message : "Working...",
					   ovl->screen_w / 2, (content_top() + content_bottom(ovl)) / 2,
					   ovl->theme.text, EMU_OVL_FONT_LARGE);
	r->end_frame();
}
