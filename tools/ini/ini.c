/*
 * ini — lightweight CLI for reading and merging INI files.
 *
 * Usage:
 *   ini get  <file> <section> <key>    Print value, exit 0=found 1=missing 2=error
 *   ini merge <base> <overlay>         Merge overlay values into base (atomic write)
 *
 * Built on top of inih (https://github.com/benhoyt/inih), BSD-3-Clause.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>

#include "lib/ini.h"

/* ── helpers ─────────────────────────────────────────────────────────────── */

/* Strip leading/trailing whitespace in-place, return pointer into buf. */
static char *strip(char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    char *end = s + strlen(s);
    while (end > s && isspace((unsigned char)*(end - 1))) end--;
    *end = '\0';
    return s;
}

/* Remove surrounding double-quotes if present. */
static char *strip_quotes(char *s) {
    size_t len = strlen(s);
    if (len >= 2 && s[0] == '"' && s[len - 1] == '"') {
        s[len - 1] = '\0';
        return s + 1;
    }
    return s;
}

/* ── get ─────────────────────────────────────────────────────────────────── */

typedef struct {
    const char *section;
    const char *key;
    char value[4096];
    int found;
} GetCtx;

static int get_handler(void *user, const char *section,
                       const char *name, const char *value) {
    GetCtx *ctx = (GetCtx *)user;
    if (strcmp(section, ctx->section) == 0 && strcmp(name, ctx->key) == 0) {
        snprintf(ctx->value, sizeof(ctx->value), "%s", value);
        ctx->found = 1;
    }
    return 1; /* keep parsing — last match wins */
}

static int cmd_get(const char *file, const char *section, const char *key) {
    GetCtx ctx;
    ctx.section = section;
    ctx.key     = key;
    ctx.value[0] = '\0';
    ctx.found   = 0;

    int err = ini_parse(file, get_handler, &ctx);
    if (err == -1) {
        fprintf(stderr, "ini: cannot open %s\n", file);
        return 2;
    }
    /* err > 0 means a parse error on that line — we still return any value
       that was successfully parsed before the error. */

    if (!ctx.found)
        return 1;

    char *out = strip_quotes(ctx.value);
    printf("%s\n", out);
    return 0;
}

/* ── merge ───────────────────────────────────────────────────────────────── */

#define MERGE_MAX_ENTRIES 512
#define MERGE_MAX_LINE   4096

typedef struct {
    char section[256];
    char key[256];
    char value[1024];
    int  written;
} MergeEntry;

typedef struct {
    MergeEntry entries[MERGE_MAX_ENTRIES];
    int count;
} MergeCtx;

static int merge_handler(void *user, const char *section,
                         const char *name, const char *value) {
    MergeCtx *ctx = (MergeCtx *)user;
    if (ctx->count >= MERGE_MAX_ENTRIES)
        return 0; /* stop parsing */

    /* Skip entries with no section — they would produce [] in the output */
    if (section[0] == '\0')
        return 1;

    /* If the same section+key already exists (duplicate), update it. */
    for (int i = 0; i < ctx->count; i++) {
        if (strcmp(ctx->entries[i].section, section) == 0 &&
            strcmp(ctx->entries[i].key, name) == 0) {
            snprintf(ctx->entries[i].value, sizeof(ctx->entries[i].value),
                     "%s", value);
            return 1;
        }
    }

    MergeEntry *e = &ctx->entries[ctx->count++];
    snprintf(e->section, sizeof(e->section), "%s", section);
    snprintf(e->key,     sizeof(e->key),     "%s", name);
    snprintf(e->value,   sizeof(e->value),   "%s", value);
    e->written = 0;
    return 1;
}

/* Flush unwritten entries for a given section. */
static void flush_section(FILE *out, MergeCtx *ctx, const char *section) {
    for (int i = 0; i < ctx->count; i++) {
        MergeEntry *e = &ctx->entries[i];
        if (!e->written && strcmp(e->section, section) == 0) {
            fprintf(out, "%s = %s\n", e->key, e->value);
            e->written = 1;
        }
    }
}

/* Extract key name from a "key = value" line. Returns pointer into buf
   (modifies buf by NUL-terminating after the key). Returns NULL if no
   '=' found. */
static char *extract_key(char *buf) {
    char *eq = strchr(buf, '=');
    if (!eq) {
        eq = strchr(buf, ':');
        if (!eq) return NULL;
    }
    *eq = '\0';
    return strip(buf);
}

static int cmd_merge(const char *base_path, const char *overlay_path) {
    /* 1. Parse overlay into entry list */
    MergeCtx ctx;
    memset(&ctx, 0, sizeof(ctx));

    int err = ini_parse(overlay_path, merge_handler, &ctx);
    if (err == -1) {
        fprintf(stderr, "ini: cannot open overlay %s\n", overlay_path);
        return 1;
    }
    if (ctx.count == 0) return 0; /* nothing to merge */

    /* 2. Open base for reading */
    FILE *base = fopen(base_path, "r");
    if (!base) {
        fprintf(stderr, "ini: cannot open base %s\n", base_path);
        return 1;
    }

    /* 3. Write to temp file */
    char tmp_path[4096];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", base_path);
    FILE *out = fopen(tmp_path, "w");
    if (!out) {
        fprintf(stderr, "ini: cannot create %s\n", tmp_path);
        fclose(base);
        return 1;
    }

    char line[MERGE_MAX_LINE];
    char cur_section[256] = "";

    while (fgets(line, sizeof(line), base)) {
        /* Make a mutable copy for parsing */
        char copy[MERGE_MAX_LINE];
        snprintf(copy, sizeof(copy), "%s", line);
        char *trimmed = strip(copy);

        if (trimmed[0] == '[') {
            /* Section header — flush pending entries for the previous section */
            if (cur_section[0] != '\0')
                flush_section(out, &ctx, cur_section);

            /* Extract new section name */
            char *end = strchr(trimmed, ']');
            if (end) {
                *end = '\0';
                snprintf(cur_section, sizeof(cur_section), "%s", trimmed + 1);
            }
            fputs(line, out);
        } else if (trimmed[0] == '#' || trimmed[0] == ';' || trimmed[0] == '\0') {
            /* Comment or blank — pass through */
            fputs(line, out);
        } else {
            /* Potential key=value line */
            char *key = extract_key(copy);
            if (key) {
                /* Check overlay for a matching entry */
                int replaced = 0;
                for (int i = 0; i < ctx.count; i++) {
                    MergeEntry *e = &ctx.entries[i];
                    if (!e->written &&
                        strcmp(e->section, cur_section) == 0 &&
                        strcmp(e->key, key) == 0) {
                        fprintf(out, "%s = %s\n", e->key, e->value);
                        e->written = 1;
                        replaced = 1;
                        break;
                    }
                }
                if (!replaced)
                    fputs(line, out);
            } else {
                fputs(line, out);
            }
        }
    }

    /* Flush remaining entries for the last section */
    if (cur_section[0] != '\0')
        flush_section(out, &ctx, cur_section);

    /* Append entries for sections that don't exist in the base file */
    char appended_sections[MERGE_MAX_ENTRIES][256];
    int  appended_count = 0;

    for (int i = 0; i < ctx.count; i++) {
        MergeEntry *e = &ctx.entries[i];
        if (e->written) continue;

        /* Check if we already emitted this section header */
        int found = 0;
        for (int j = 0; j < appended_count; j++) {
            if (strcmp(appended_sections[j], e->section) == 0) {
                found = 1;
                break;
            }
        }
        if (!found) {
            fprintf(out, "\n[%s]\n", e->section);
            snprintf(appended_sections[appended_count++], 256, "%s", e->section);
            /* Write all entries for this new section */
            flush_section(out, &ctx, e->section);
        }
    }

    fclose(base);
    fclose(out);

    /* 4. Atomic replace */
    if (rename(tmp_path, base_path) != 0) {
        perror("ini: rename failed");
        unlink(tmp_path);
        return 1;
    }
    return 0;
}

/* ── main ────────────────────────────────────────────────────────────────── */

static void usage(void) {
    fprintf(stderr,
        "Usage:\n"
        "  ini get  <file> <section> <key>\n"
        "  ini merge <base> <overlay>\n");
}

int main(int argc, char *argv[]) {
    if (argc < 2) { usage(); return 2; }

    if (strcmp(argv[1], "get") == 0) {
        if (argc != 5) { usage(); return 2; }
        return cmd_get(argv[2], argv[3], argv[4]);
    }

    if (strcmp(argv[1], "merge") == 0) {
        if (argc != 4) { usage(); return 2; }
        return cmd_merge(argv[2], argv[3]);
    }

    usage();
    return 2;
}
