#include "emu_overlay.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Layout constants (pre-scaled) — matching NextUI's common/defines.h.
// NextUI's desktop platform (1024x768, FIXED_SCALE=3) overrides PADDING to 5,
// while tg5050 (1280x720, FIXED_SCALE=2) uses the default PADDING=10. We match
// both by varying ovl_padding at init time.
#define PILL_SIZE 30
#define BUTTON_SIZE 20
#define BUTTON_MARGIN 5
#define BUTTON_PADDING 12

static int ovl_scale = 2;
static int ovl_padding = 10;
#define S(x) ((x) * ovl_scale)
#define PADDING_PX (ovl_padding * ovl_scale)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void build_main_menu(EmuOvl* ovl) {
	int n = 0;

	snprintf(ovl->main_items[n].label, sizeof(ovl->main_items[n].label), "Continue");
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
	// Match minarch format: <screenshot_dir>/<rom_file>.<slot>.bmp
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

	// Target height: ~40% of screen height
	int target_h = ovl->screen_h * 2 / 5;

	for (int i = 0; i < EMU_OVL_MAX_SLOTS; i++) {
		// Free old icon if loaded
		if (ovl->slot_icons[i] >= 0 && ovl->render->free_icon) {
			ovl->render->free_icon(ovl->slot_icons[i]);
			ovl->slot_icons[i] = -1;
		}
		char path[512];
		get_slot_screenshot_path(ovl, i, path, sizeof(path));
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

	if (game_name)
		snprintf(ovl->game_name, sizeof(ovl->game_name), "%s", game_name);

	// Scale factor & outer padding — match NextUI per-platform:
	//   tg5040 Brick (1024x768) → FIXED_SCALE=3, desktop platform's PADDING=5
	//   tg5050 (1280x720)       → FIXED_SCALE=2, default PADDING=10
	if (screen_w <= 1024) {
		ovl_scale = 3;
		ovl_padding = 5;
	} else {
		ovl_scale = 2;
		ovl_padding = 10;
	}

	// Items per page: Brick = 5, Smart Pro / TG5050 = 9
	if (screen_w <= 1024)
		ovl->items_per_page = 5;
	else
		ovl->items_per_page = 8;

	build_main_menu(ovl);

	// Screenshot directory (matches minarch's .minui path for game switcher)
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

	// Load button hint icons from resource directory
	ovl->icon_a = -1;
	ovl->icon_b = -1;
	ovl->icon_dpad_h = -1;
	const char* res_dir = getenv("EMU_OVERLAY_RES");
	if (res_dir && res_dir[0] != '\0' && render->load_icon) {
		int icon_h = S(BUTTON_SIZE); // match NextUI's btn_sz = SCALE1(BUTTON_SIZE)
		char path[512];
		snprintf(path, sizeof(path), "%s/nav_button_a.png", res_dir);
		ovl->icon_a = render->load_icon(path, icon_h);
		snprintf(path, sizeof(path), "%s/nav_button_b.png", res_dir);
		ovl->icon_b = render->load_icon(path, icon_h);
		snprintf(path, sizeof(path), "%s/nav_dpad_horizontal.png", res_dir);
		ovl->icon_dpad_h = render->load_icon(path, icon_h);
	}

	// Note: caller is responsible for calling render->init() before emu_ovl_init
	return 0;
}

void emu_ovl_open(EmuOvl* ovl) {
	ovl->state = EMU_OVL_STATE_MAIN_MENU;
	ovl->selected = 0;
	ovl->action = EMU_OVL_ACTION_NONE;
	ovl->action_param = 0;
	ovl->save_slot = 0;
	ovl->scroll_offset = 0;

	if (ovl->render && ovl->render->capture_frame)
		ovl->render->capture_frame();
}

bool emu_ovl_update(EmuOvl* ovl, EmuOvlInput* input) {
	if (ovl->state == EMU_OVL_STATE_CLOSED)
		return false;

	switch (ovl->state) {
	// ----- MAIN MENU -----
	case EMU_OVL_STATE_MAIN_MENU:
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
				ovl->action = EMU_OVL_ACTION_CONTINUE;
				ovl->state = EMU_OVL_STATE_CLOSED;
				return false;
			case EMU_OVL_MAIN_SAVE:
				ovl->state = EMU_OVL_STATE_SAVE_SELECT;
				ovl->save_slot = 0;
				load_slot_screenshots(ovl);
				break;
			case EMU_OVL_MAIN_LOAD:
				ovl->state = EMU_OVL_STATE_LOAD_SELECT;
				ovl->save_slot = 0;
				load_slot_screenshots(ovl);
				break;
			case EMU_OVL_MAIN_OPTIONS:
				ovl->state = EMU_OVL_STATE_SECTION_LIST;
				ovl->selected = 0;
				ovl->scroll_offset = 0;
				ovl->current_section = 0;
				break;
			case EMU_OVL_MAIN_QUIT:
				ovl->action = EMU_OVL_ACTION_QUIT;
				ovl->state = EMU_OVL_STATE_CLOSED;
				return false;
			}
		} else if (input->b || input->menu) {
			ovl->action = EMU_OVL_ACTION_CONTINUE;
			ovl->state = EMU_OVL_STATE_CLOSED;
			return false;
		}
		break;

	// ----- SAVE / LOAD SELECT -----
	case EMU_OVL_STATE_SAVE_SELECT:
	case EMU_OVL_STATE_LOAD_SELECT:
		if (input->left) {
			ovl->save_slot = (ovl->save_slot - 1 + EMU_OVL_MAX_SLOTS) % EMU_OVL_MAX_SLOTS;
		} else if (input->right) {
			ovl->save_slot = (ovl->save_slot + 1) % EMU_OVL_MAX_SLOTS;
		} else if (input->l1) {
			ovl->save_slot = 0;
		} else if (input->r1) {
			ovl->save_slot = EMU_OVL_MAX_SLOTS - 1;
		} else if (input->a) {
			ovl->action = (ovl->state == EMU_OVL_STATE_SAVE_SELECT)
							  ? EMU_OVL_ACTION_SAVE_STATE
							  : EMU_OVL_ACTION_LOAD_STATE;
			ovl->action_param = ovl->save_slot;
			ovl->state = EMU_OVL_STATE_CLOSED;
			return false;
		} else if (input->b) {
			EmuOvlState prev_state = ovl->state;
			ovl->state = EMU_OVL_STATE_MAIN_MENU;
			free_slot_screenshots(ovl);
			// Restore selected to the correct Save/Load entry
			EmuOvlMainItemType target = (prev_state == EMU_OVL_STATE_SAVE_SELECT)
											? EMU_OVL_MAIN_SAVE
											: EMU_OVL_MAIN_LOAD;
			for (int i = 0; i < ovl->main_item_count; i++) {
				if (ovl->main_items[i].type == target) {
					ovl->selected = i;
					break;
				}
			}
		}
		break;

	// ----- SECTION LIST -----
	case EMU_OVL_STATE_SECTION_LIST:
		{
		// +1 for "Save Changes" row at the bottom (matching NextUI's minarch
		// which puts Save Changes as the last entry in its Options menu).
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
		EmuOvlSection* sec = &ovl->config->sections[ovl->current_section];
		int total_rows = sec->item_count + 1; // +1 for "Reset to Default"
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
			if (ovl->selected == sec->item_count) {
				// "Reset to Default" action
				emu_ovl_cfg_reset_section_to_defaults(sec);
			} else if (sec->item_count > 0) {
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
		// 3 items: Save for Console, Save for Game, Restore Defaults
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
// Rendering — settings-page style (matching NextUI's UI_renderSettingsPage)
// ---------------------------------------------------------------------------

// Pill-shaped rounded rect (radius = height/2). Delegates to the backend's
// anti-aliased draw_rounded_rect implementation.
static void draw_pill(EmuOvlRenderBackend* r, int x, int y, int w, int h,
					  uint32_t color) {
	if (r->draw_rounded_rect)
		r->draw_rounded_rect(x, y, w, h, h / 2, color);
	else
		r->draw_rect(x, y, w, h, color);
}

// Compute vertically centered list_y for n items, reserving space for the
// top title pill and the bottom footer pill.
static int calc_centered_list_y(EmuOvl* ovl, int item_count) {
	int reserved = PADDING_PX + S(PILL_SIZE) + PADDING_PX;
	int top = reserved;
	int bottom = ovl->screen_h - reserved;
	int total_h = item_count * S(PILL_SIZE);
	return top + (bottom - top - total_h) / 2;
}

// Draw text with a 1px black shadow for readability on game background
static void draw_shadowed_text(EmuOvlRenderBackend* r, const char* text, int x, int y,
							   uint32_t color, int font_id) {
	r->draw_text(text, x + 1, y + 1, EMU_OVL_COLOR_BLACK, font_id);
	r->draw_text(text, x, y, color, font_id);
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

// Draw the title inside a dark rounded pill at the top-left
// (matches NextUI Quick Menu's GFX_blitPillLight call on ASSET_WHITE_PILL)
static void draw_menu_bar(EmuOvl* ovl, const char* title) {
	EmuOvlRenderBackend* r = ovl->render;
	int pill_h = S(PILL_SIZE);
	int pad = S(BUTTON_PADDING);

	// Available inner width = screen - side padding - pill internal padding
	int max_inner_w = ovl->screen_w - PADDING_PX * 2 - pad * 2;
	char display[256];
	shorten_title(r, title, display, sizeof(display), max_inner_w);

	int text_w = r->text_width(display, EMU_OVL_FONT_LARGE);
	int pill_w = text_w + pad * 2;
	int max_pill_w = ovl->screen_w - PADDING_PX * 2;
	if (pill_w > max_pill_w)
		pill_w = max_pill_w;
	int x = PADDING_PX;
	int y = PADDING_PX;

	draw_pill(r, x, y, pill_w, pill_h, EMU_OVL_COLOR_ROW_BG);

	int text_y = y + (pill_h - r->text_height(EMU_OVL_FONT_LARGE)) / 2;
	r->draw_text(display, x + pad, text_y, EMU_OVL_COLOR_WHITE, EMU_OVL_FONT_LARGE);
}

// Map a button name to its icon handle, or -1 if no icon loaded
static int get_hint_icon(EmuOvl* ovl, const char* btn_name) {
	if (strcmp(btn_name, "A") == 0)
		return ovl->icon_a;
	if (strcmp(btn_name, "B") == 0)
		return ovl->icon_b;
	if (strcmp(btn_name, "LEFT/RIGHT") == 0)
		return ovl->icon_dpad_h;
	return -1;
}

// Measure a button glyph's width (a circle for single-char labels like "A"/"B",
// a pill for multi-char labels like "POWER", or a loaded PNG icon for special
// hints like "LEFT/RIGHT"). Mirrors NextUI's GFX_getButtonWidth.
static int measure_button_glyph(EmuOvl* ovl, const char* btn, int btn_inner_h) {
	EmuOvlRenderBackend* r = ovl->render;
	if (strlen(btn) == 1) {
		// Single-char button is always a filled BUTTON_SIZE circle (programmatic)
		return btn_inner_h;
	}
	// Special multi-char hints with PNG icons (d-pad etc.)
	int icon_id = get_hint_icon(ovl, btn);
	if (icon_id >= 0 && r->icon_width)
		return r->icon_width(icon_id);
	// Plain multi-char button (POWER/MENU): pill at BUTTON_SIZE/2 + text_w width,
	// text in font.tiny
	int tw = r->text_width(btn, EMU_OVL_FONT_TINY);
	return btn_inner_h / 2 + tw;
}

// Draw a single button glyph at (gx, gy). btn_inner_h is the inner pill height
// (== BUTTON_SIZE scaled). Returns the glyph width. Mirrors NextUI's
// single-char and multi-char branches of GFX_blitButton.
static int draw_button_glyph(EmuOvl* ovl, const char* btn, int gx, int gy,
							 int btn_inner_h) {
	EmuOvlRenderBackend* r = ovl->render;
	if (strlen(btn) == 1) {
		// Filled white circle + centered dark letter in font.medium
		draw_pill(r, gx, gy, btn_inner_h, btn_inner_h, EMU_OVL_COLOR_ROW_SEL);
		int tw = r->text_width(btn, EMU_OVL_FONT_MEDIUM);
		int th = r->text_height(EMU_OVL_FONT_MEDIUM);
		r->draw_text(btn, gx + (btn_inner_h - tw) / 2,
					 gy + (btn_inner_h - th) / 2,
					 EMU_OVL_COLOR_TEXT_SEL, EMU_OVL_FONT_MEDIUM);
		return btn_inner_h;
	}
	// PNG icon path for special hints (d-pad)
	int icon_id = get_hint_icon(ovl, btn);
	if (icon_id >= 0 && r->draw_icon) {
		r->draw_icon(icon_id, gx, gy);
		return r->icon_width(icon_id);
	}
	// Multi-char inner pill (POWER/MENU): width = BUTTON_SIZE/2 + text_w,
	// text in font.tiny, drawn at BUTTON_SIZE/4 offset from the pill's left edge.
	int tw = r->text_width(btn, EMU_OVL_FONT_TINY);
	int w = btn_inner_h / 2 + tw;
	draw_pill(r, gx, gy, w, btn_inner_h, EMU_OVL_COLOR_ROW_SEL);
	int th = r->text_height(EMU_OVL_FONT_TINY);
	r->draw_text(btn, gx + btn_inner_h / 4, gy + (btn_inner_h - th) / 2,
				 EMU_OVL_COLOR_TEXT_SEL, EMU_OVL_FONT_TINY);
	return w;
}

// Draw a button-hint group inside a dark rounded outer pill.
// Entries alternate: button_label, action_label, button_label, action_label, …
// align_right = true → bottom-right anchored, else bottom-left.
//
// Mirrors NextUI's GFX_blitButtonGroup layout: all inner gaps are BUTTON_MARGIN
// (= 5 scaled), so the outer pill content width is:
//   ow = BM + sum_i(BM + glyph_i + BM + label_i + BM) + BM
static void draw_button_group(EmuOvl* ovl, const char* hints[], int hint_count,
							  bool align_right) {
	EmuOvlRenderBackend* r = ovl->render;
	int pill_h = S(PILL_SIZE);
	int inner_h = S(BUTTON_SIZE);
	int bm = S(BUTTON_MARGIN);	// all inner margins are BUTTON_MARGIN per NextUI

	// Pass 1: measure total width using NextUI's per-pair formula:
	//   pair_w = glyph + BM + label + BM
	//   ow = BM + (BM + pair_w) * N = sum + (2*N + 1) * BM + sum_glyphs + sum_labels
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

	// Outer dark pill
	draw_pill(r, x, y, group_w, pill_h, EMU_OVL_COLOR_ROW_BG);

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
						 EMU_OVL_COLOR_WHITE, EMU_OVL_FONT_SMALL);
			label_w = r->text_width(hints[i + 1], EMU_OVL_FONT_SMALL);
		}
		// pair_w = gw + bm + label_w + bm; advance by pair_w + bm
		cx += gw + bm + label_w + bm + bm;
	}
}

// Is this button a navigation hint (d-pad, L/R, etc.) that should go in the
// left-aligned group, per NextUI's two-group footer convention?
static bool is_nav_hint(const char* btn) {
	return strcmp(btn, "LEFT/RIGHT") == 0 ||
		   strcmp(btn, "UP/DOWN") == 0 ||
		   strcmp(btn, "L/R") == 0 ||
		   strcmp(btn, "L1/R1") == 0;
}

// Draw the full bottom hint row, splitting the passed hints into two groups
// per NextUI's convention (see e.g. battery.c:760 where GFX_blitButtonGroup is
// called twice — nav hints left-aligned, action hints right-aligned):
//   - Left pill:  navigation hints (d-pad, L/R, …). If none are passed we
//                 fall back to POWER/SLEEP (the Quick Menu hardware hint).
//   - Right pill: action hints (A, B, etc.)
static void draw_footer_hints(EmuOvl* ovl, const char* hints[], int hint_count) {
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

	if (left_count == 0) {
		// Quick-Menu style: no nav hints, so show the POWER/SLEEP hardware hint
		const char* power_hint[] = {"POWER", "SLEEP"};
		draw_button_group(ovl, power_hint, 2, false);
	} else {
		draw_button_group(ovl, left, left_count, false);
	}
	if (right_count > 0)
		draw_button_group(ovl, right, right_count, true);
}

// Draw a settings row (label on left, optional value on right)
// Matches the visual style of UI_renderSettingsRow from ui_list.c
static void draw_settings_row(EmuOvl* ovl, int x, int y, int w, int h,
							  const char* label, const char* value,
							  bool selected, bool cycleable, int label_font) {
	EmuOvlRenderBackend* r = ovl->render;
	int row_pad = S(BUTTON_PADDING);

	if (selected) {
		if (value) {
			// 2-layer: full-width COLOR2 + label-width COLOR1
			draw_pill(r, x, y, w, h, EMU_OVL_COLOR_ROW_BG);

			int lw = r->text_width(label, label_font);
			int label_pill_w = lw + row_pad * 2;
			draw_pill(r, x, y, label_pill_w, h, EMU_OVL_COLOR_ROW_SEL);

			// Label text (black on white pill)
			int text_y_pos = y + (h - r->text_height(label_font)) / 2;
			r->draw_text(label, x + row_pad, text_y_pos,
						 EMU_OVL_COLOR_TEXT_SEL, label_font);

			// Value text (white, right-aligned, with arrows if cycleable)
			char display[192];
			if (cycleable)
				snprintf(display, sizeof(display), "< %s >", value);
			else
				snprintf(display, sizeof(display), "%s", value);

			int vw = r->text_width(display, EMU_OVL_FONT_TINY);
			int val_x = x + w - row_pad - vw;
			int val_y = y + (h - r->text_height(EMU_OVL_FONT_TINY)) / 2;
			r->draw_text(display, val_x, val_y, EMU_OVL_COLOR_WHITE, EMU_OVL_FONT_TINY);
		} else {
			// Single label rect (no value)
			int lw = r->text_width(label, label_font);
			int label_pill_w = lw + row_pad * 2;
			draw_pill(r, x, y, label_pill_w, h, EMU_OVL_COLOR_ROW_SEL);

			int text_y_pos = y + (h - r->text_height(label_font)) / 2;
			r->draw_text(label, x + row_pad, text_y_pos,
						 EMU_OVL_COLOR_TEXT_SEL, label_font);
		}
	} else {
		// Unselected: no background, white text with shadow for readability
		int text_y_pos = y + (h - r->text_height(label_font)) / 2;
		draw_shadowed_text(r, label, x + row_pad, text_y_pos,
						   EMU_OVL_COLOR_WHITE, label_font);

		if (value) {
			int vw = r->text_width(value, EMU_OVL_FONT_TINY);
			int val_x = x + w - row_pad - vw;
			int val_y = y + (h - r->text_height(EMU_OVL_FONT_TINY)) / 2;
			draw_shadowed_text(r, value, val_x, val_y, EMU_OVL_COLOR_WHITE, EMU_OVL_FONT_TINY);
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

	draw_menu_bar(ovl, ovl->game_name);

	int row_h = S(PILL_SIZE);
	int content_x = PADDING_PX;
	int content_w = ovl->screen_w - PADDING_PX * 2;

	int vis_count = ovl->main_item_count;
	if (vis_count > ovl->items_per_page)
		vis_count = ovl->items_per_page;
	// Vertically center the list between the title pill and the footer pill,
	// matching NextUI's minarch.c Menu_loop():
	//   oy = ((DEVICE_HEIGHT/FIXED_SCALE - PADDING*2) - (n * PILL_SIZE)) / 2
	int list_y = calc_centered_list_y(ovl, vis_count);

	// Only use left half for menu items (right half reserved for save preview)
	int menu_w = ovl->screen_w / 2;

	for (int i = 0; i < vis_count; i++) {
		int iy = list_y + i * row_h;
		bool sel = (i == ovl->selected);
		draw_settings_row(ovl, content_x, iy, menu_w - PADDING_PX, row_h,
						  ovl->main_items[i].label, NULL, sel, false,
						  EMU_OVL_FONT_LARGE);
	}

	// Show save slot preview on the right when Save or Load is highlighted
	EmuOvlMainItemType sel_type = ovl->main_items[ovl->selected].type;
	if (sel_type == EMU_OVL_MAIN_SAVE || sel_type == EMU_OVL_MAIN_LOAD) {
		int preview_x = ovl->screen_w / 2 + PADDING_PX;
		int preview_w = ovl->screen_w / 2 - PADDING_PX * 2;
		int preview_cy = ovl->screen_h / 2;

		int icon_id = ovl->slot_icons[ovl->save_slot];
		if (icon_id >= 0 && r->draw_icon) {
			int iw = r->icon_width(icon_id);
			int ih = r->icon_height(icon_id);
			// Scale to fit the right half, preserve aspect
			int draw_w = preview_w;
			int draw_h = ih * draw_w / iw;
			int ix = preview_x + (preview_w - draw_w) / 2;
			int iy = preview_cy - draw_h / 2;
			r->draw_icon(icon_id, ix, iy);
		} else {
			draw_shadowed_text(r, "Empty", preview_x + preview_w / 2 - S(20),
							   preview_cy, EMU_OVL_COLOR_GRAY, EMU_OVL_FONT_SMALL);
		}

		// Slot pagination dots below preview
		int dot_size = S(4);
		int dot_gap = S(6);
		int dots_w = EMU_OVL_MAX_SLOTS * dot_size + (EMU_OVL_MAX_SLOTS - 1) * dot_gap;
		int dots_x = preview_x + (preview_w - dots_w) / 2;
		int dots_y = preview_cy + preview_w * 3 / 8 + S(8);
		for (int i = 0; i < EMU_OVL_MAX_SLOTS; i++) {
			uint32_t color = (i == ovl->save_slot) ? EMU_OVL_COLOR_WHITE : EMU_OVL_COLOR_GRAY;
			r->draw_rect(dots_x + i * (dot_size + dot_gap), dots_y, dot_size, dot_size, color);
		}
	}

	const char* hints[] = {"B", "BACK", "A", "OKAY"};
	draw_footer_hints(ovl, hints, 4);
}

static void render_slot_select(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;
	bool is_save = (ovl->state == EMU_OVL_STATE_SAVE_SELECT);

	draw_menu_bar(ovl, is_save ? "Save State" : "Load State");

	int bar_h = S(BUTTON_SIZE) + S(BUTTON_MARGIN) * 2;
	int center_y = ovl->screen_h / 2;

	// Slot screenshot (centered above slot text)
	int icon_id = ovl->slot_icons[ovl->save_slot];
	if (icon_id >= 0 && r->draw_icon) {
		int iw = r->icon_width(icon_id);
		int ih = r->icon_height(icon_id);
		int ix = (ovl->screen_w - iw) / 2;
		int iy = bar_h + (center_y - bar_h - ih) / 2;
		if (iy < bar_h)
			iy = bar_h;
		r->draw_icon(icon_id, ix, iy);
	} else {
		// No screenshot: show "Empty" text
		draw_centered_text(r, "Empty", ovl->screen_w / 2,
						   bar_h + (center_y - bar_h) / 2,
						   EMU_OVL_COLOR_GRAY, EMU_OVL_FONT_SMALL);
	}

	// Slot text below center
	char slot_text[32];
	snprintf(slot_text, sizeof(slot_text), "<  Slot %d  >", ovl->save_slot + 1);
	draw_centered_text(r, slot_text, ovl->screen_w / 2, center_y + S(PILL_SIZE) / 2,
					   EMU_OVL_COLOR_WHITE, EMU_OVL_FONT_LARGE);

	// Pagination dots
	int dot_size = S(4);
	int dot_gap = S(6);
	int dots_w = EMU_OVL_MAX_SLOTS * dot_size + (EMU_OVL_MAX_SLOTS - 1) * dot_gap;
	int dots_x = (ovl->screen_w - dots_w) / 2;
	int dots_y = center_y + S(PILL_SIZE) + S(PILL_SIZE) / 2;

	for (int i = 0; i < EMU_OVL_MAX_SLOTS; i++) {
		uint32_t color = (i == ovl->save_slot) ? EMU_OVL_COLOR_ACCENT : EMU_OVL_COLOR_GRAY;
		r->draw_rect(dots_x + i * (dot_size + dot_gap), dots_y, dot_size, dot_size, color);
	}

	const char* hints[] = {"LEFT/RIGHT", "SELECT", "B", "BACK", "A", "OKAY"};
	draw_footer_hints(ovl, hints, 6);
}

static void render_section_list(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;

	draw_menu_bar(ovl, "Options");

	int row_h = S(PILL_SIZE);
	int content_x = PADDING_PX;
	int content_w = ovl->screen_w - PADDING_PX * 2;

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
		draw_settings_row(ovl, content_x, iy, content_w, row_h,
						  name, NULL, sel, false, EMU_OVL_FONT_LARGE);
	}

	// Optional hint (e.g. "Restart game to apply changes")
	if (ovl->config->options_hint[0] != '\0') {
		int hint_y = list_y + vis_count * row_h + S(4);
		int tw = r->text_width(ovl->config->options_hint, EMU_OVL_FONT_TINY);
		r->draw_text(ovl->config->options_hint,
					 (ovl->screen_w - tw) / 2, hint_y,
					 EMU_OVL_COLOR_GRAY, EMU_OVL_FONT_TINY);
	}

	const char* hints[] = {"B", "BACK", "A", "OPEN"};
	draw_footer_hints(ovl, hints, 4);
}

static void render_section_items(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;
	EmuOvlSection* sec = &ovl->config->sections[ovl->current_section];

	draw_menu_bar(ovl, sec->name);

	int row_h = S(PILL_SIZE);
	int items_per_page = ovl->items_per_page;
	int list_y = calc_centered_list_y(ovl, items_per_page);
	int content_x = PADDING_PX;
	int content_w = ovl->screen_w - PADDING_PX * 2;

	int total_rows = sec->item_count + 1; // +1 for "Reset to Default"

	// Scroll
	ensure_scroll(ovl, total_rows);

	int vis_count = items_per_page;
	if (vis_count > total_rows)
		vis_count = total_rows;

	for (int vi = 0; vi < vis_count; vi++) {
		int idx = ovl->scroll_offset + vi;
		if (idx >= total_rows)
			break;

		int iy = list_y + vi * row_h;
		bool sel = (idx == ovl->selected);

		if (idx < sec->item_count) {
			EmuOvlItem* item = &sec->items[idx];
			char val_buf[64];
			const char* val_str = get_item_display_value(item, val_buf, sizeof(val_buf));
			draw_settings_row(ovl, content_x, iy, content_w, row_h,
							  item->label, val_str, sel, true,
							  EMU_OVL_FONT_SMALL);
		} else {
			// "Reset to Default" row
			draw_settings_row(ovl, content_x, iy, content_w, row_h,
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
						 EMU_OVL_COLOR_GRAY, EMU_OVL_FONT_TINY);
		}
	}

	const char* hints[] = {"LEFT/RIGHT", "CHANGE", "B", "BACK"};
	draw_footer_hints(ovl, hints, 4);
}

static void render_cheats(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;
	draw_menu_bar(ovl, "Cheats");

	int count = ovl->cheat_cb.get_count ? ovl->cheat_cb.get_count() : 0;

	if (count == 0) {
		draw_centered_text(r, "No cheats available", ovl->screen_w / 2,
						   ovl->screen_h / 2, EMU_OVL_COLOR_GRAY, EMU_OVL_FONT_SMALL);
		const char* hints[] = {"B", "BACK"};
		draw_footer_hints(ovl, hints, 2);
		return;
	}

	int row_h = S(PILL_SIZE);
	int items_per_page = ovl->items_per_page;
	int list_y = calc_centered_list_y(ovl, items_per_page);
	int content_x = PADDING_PX;
	int content_w = ovl->screen_w - PADDING_PX * 2;

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
		draw_settings_row(ovl, content_x, iy, content_w, row_h,
						  name, val, sel, true, EMU_OVL_FONT_SMALL);
	}

	// Description for selected cheat (inline, matching settings pattern)
	int desc_y = list_y + vis_count * row_h;
	int desc_cy = desc_y + row_h / 2 - r->text_height(EMU_OVL_FONT_TINY) / 2;
	const char* desc = ovl->cheat_cb.get_description ? ovl->cheat_cb.get_description(ovl->selected) : NULL;
	if (desc && desc[0] != '\0') {
		int tw = r->text_width(desc, EMU_OVL_FONT_TINY);
		r->draw_text(desc, (ovl->screen_w - tw) / 2, desc_cy,
					 EMU_OVL_COLOR_GRAY, EMU_OVL_FONT_TINY);
	}

	const char* hints[] = {"LEFT/RIGHT", "CHANGE", "B", "BACK"};
	draw_footer_hints(ovl, hints, 4);
}

static const char* scope_label(EmuConfigScope scope) {
	switch (scope) {
	case EMU_SCOPE_NONE:    return "Using defaults.";
	case EMU_SCOPE_CONSOLE: return "Using console config.";
	case EMU_SCOPE_GAME:    return "Using game config.";
	}
	return "";
}

static void render_save_changes(EmuOvl* ovl) {
	EmuOvlRenderBackend* r = ovl->render;

	draw_menu_bar(ovl, "Save Changes");

	// Scope indicator below the title
	const char* desc = scope_label(ovl->scope);
	int desc_tw = r->text_width(desc, EMU_OVL_FONT_TINY);
	int title_pill_h = S(PILL_SIZE);
	int desc_y = PADDING_PX + title_pill_h + S(2);
	r->draw_text(desc, PADDING_PX + S(BUTTON_PADDING), desc_y,
				 EMU_OVL_COLOR_GRAY, EMU_OVL_FONT_TINY);

	// 3 rows: Save for Console, Save for Game, Restore Defaults
	static const char* items[] = {
		"Save for Console", "Save for Game", "Restore Defaults"
	};
	int row_h = S(PILL_SIZE);
	int content_x = PADDING_PX;
	int content_w = ovl->screen_w - PADDING_PX * 2;
	int list_y = calc_centered_list_y(ovl, 3);

	for (int i = 0; i < 3; i++) {
		int iy = list_y + i * row_h;
		bool sel = (i == ovl->selected);
		draw_settings_row(ovl, content_x, iy, content_w, row_h,
						  items[i], NULL, sel, false, EMU_OVL_FONT_LARGE);
	}

	const char* hints[] = {"B", "BACK", "A", "OKAY"};
	draw_footer_hints(ovl, hints, 4);
}

void emu_ovl_render(EmuOvl* ovl) {
	if (ovl->state == EMU_OVL_STATE_CLOSED)
		return;

	EmuOvlRenderBackend* r = ovl->render;
	if (!r)
		return;

	r->begin_frame();
	r->draw_captured_frame(0.55f);

	switch (ovl->state) {
	case EMU_OVL_STATE_MAIN_MENU:
		render_main_menu(ovl);
		break;
	case EMU_OVL_STATE_SAVE_SELECT:
	case EMU_OVL_STATE_LOAD_SELECT:
		render_slot_select(ovl);
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
