#ifndef EMU_I18N_H
#define EMU_I18N_H

/* Lightweight KEY=VALUE translations, matching Fun-Drastic's language files. */
void emu_i18n_init(void);
const char *emu_i18n(const char *english);
const char *emu_i18n_language(void);

#endif
