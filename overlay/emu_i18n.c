#include "emu_i18n.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define I18N_MAX_ENTRIES 512
#define I18N_KEY_LEN 128
#define I18N_VALUE_LEN 256
#define I18N_LANGUAGE_LEN 32

typedef struct {
	char key[I18N_KEY_LEN];
	char value[I18N_VALUE_LEN];
} I18nEntry;

static I18nEntry g_entries[I18N_MAX_ENTRIES];
static int g_entry_count;
static int g_initialized;
static char g_language[I18N_LANGUAGE_LEN] = "en";

static void trim(char *s) {
	char *start = s;
	while (*start == ' ' || *start == '\t') start++;
	if (start != s) memmove(s, start, strlen(start) + 1);
	size_t n = strlen(s);
	while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' ||
	                 s[n - 1] == '\r' || s[n - 1] == '\n'))
		s[--n] = '\0';
}

static void load_file(const char *path) {
	FILE *f = fopen(path, "r");
	if (!f) return;
	char line[I18N_VALUE_LEN + I18N_KEY_LEN + 8];
	while (fgets(line, sizeof(line), f) && g_entry_count < I18N_MAX_ENTRIES) {
		trim(line);
		if (!line[0] || line[0] == '#') continue;
		/* Use the final delimiter so English keys may contain an equals sign. */
		char *eq = strrchr(line, '=');
		if (!eq) continue;
		*eq = '\0';
		char *key = line;
		char *value = eq + 1;
		trim(key);
		trim(value);
		if (!key[0] || !value[0]) continue;
		strncpy(g_entries[g_entry_count].key, key, I18N_KEY_LEN - 1);
		g_entries[g_entry_count].key[I18N_KEY_LEN - 1] = '\0';
		strncpy(g_entries[g_entry_count].value, value, I18N_VALUE_LEN - 1);
		g_entries[g_entry_count].value[I18N_VALUE_LEN - 1] = '\0';
		g_entry_count++;
	}
	fclose(f);
}

void emu_i18n_init(void) {
	if (g_initialized) return;
	g_initialized = 1;
	g_entry_count = 0;
	const char *language = getenv("EMU_LANGUAGE");
	if (!language || !language[0]) language = getenv("UMRK_LANGUAGE");
	if (!language || !language[0]) language = getenv("JAWAKA_LANGUAGE");
	if (strcmp(language, "en") == 0 || strcmp(language, "english") == 0) {
		strcpy(g_language, "en");
		return;
	}
	strncpy(g_language, language, sizeof(g_language) - 1);
	g_language[sizeof(g_language) - 1] = '\0';
	const char *dir = getenv("EMU_LANGUAGE_DIR");
	if (!dir || !dir[0]) return;
	char path[512];
	snprintf(path, sizeof(path), "%s/%s.txt", dir, g_language);
	load_file(path);
}

const char *emu_i18n(const char *english) {
	emu_i18n_init();
	if (!english || g_entry_count == 0) return english;
	for (int i = 0; i < g_entry_count; i++)
		if (strcmp(g_entries[i].key, english) == 0)
			return g_entries[i].value;
	return english;
}

const char *emu_i18n_language(void) {
	emu_i18n_init();
	return g_language;
}
