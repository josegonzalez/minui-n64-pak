"""Generate the per-device [Input-SDL-Control1] fragments in config/shared/input/.

Run from the repo root: python3 scripts/gen-input-cfg.py

Every supported pad reports the same SDL button and axis numbers, so default.cfg
fits them all: B=0 A=1 Y=2 X=3 L1=4 R1=5 Select=6 Start=7 Menu=8 L3=9 R3=10, with
axes 0/1 the left stick, 3/4 the right stick, 2 and 5 the L2/R2 triggers, and the
d-pad on hat 0. NextUI h700 rc11 made the Anbernic pads match; before it their
numbers differed per model and from TrimUI's.

What still varies is which sticks a model physically has. default.cfg binds the
left stick to the N64 analog stick and the right stick to the C-buttons, so a
model missing either cannot reach those inputs and needs them rebound:

  cbuttons-on-r2.cfg   no right stick — C-buttons move to R2 + a face button
  h700-nosticks.cfg    no sticks at all — the above, plus the d-pad driving the
                       N64 analog stick

The modifier combo is expressed with the `<key>_mod` suffix the overlay's config
loader understands: it writes the pair into $EMU_BUTTON_MAP_FILE, and the patched
input plugin applies the modifier from there. The plain binding on the same key is
what mupen64plus's own parser sees, which has no notion of modifiers, but the
plugin clears and re-derives every N64 button bit from the map file each frame, so
the map file is what takes effect.

Modifier encoding matches the overlay: a non-negative value is an SDL button
index, a negative one is -(axis index + 1) for an analog shoulder. R2 is axis 5,
hence -6.
"""
import pathlib

HEADER = """; {title}
;
; Merged over default.cfg by launch.sh via the bundled `ini merge`, once per
; device. Only the keys below are replaced, so anything the user changes
; afterwards survives.
;
{note}
[Input-SDL-Control1]
"""

# SDL button indices, shared by every supported pad.
A, B, Y, X = 1, 0, 2, 3
R2_MODIFIER = -6  # axis 5, encoded as -(5 + 1)

CBUTTONS_NOTE = """; This device has no right analog stick, so default.cfg's C-buttons — which read
; axes 3 and 4 — cannot be reached. Bind them to R2 + a face button by physical
; position instead: X is the top button, B the bottom, Y the left, A the right.
;
"""

NOSTICKS_NOTE = """; This device has no analog sticks at all, so neither the N64 analog stick (axes
; 0/1) nor the C-buttons (axes 3/4) can be reached from default.cfg.
;
; C-buttons move to R2 + a face button by physical position: X top, B bottom,
; Y left, A right.
;
; The d-pad drives the N64 analog stick as well as the N64 d-pad. Double-binding
; it is deliberate: nearly every N64 game reads one or the other, so binding both
; leaves neither dead. The Brick instead has trimui_inputd swap the two at the
; kernel level, which h700 has no equivalent of.
;
"""


def cbuttons():
    """R2 + face button, by physical position on the pad."""
    return [
        f'C Button U = "button({X})"',
        f'C Button U_mod = {R2_MODIFIER}',
        f'C Button D = "button({B})"',
        f'C Button D_mod = {R2_MODIFIER}',
        f'C Button L = "button({Y})"',
        f'C Button L_mod = {R2_MODIFIER}',
        f'C Button R = "button({A})"',
        f'C Button R_mod = {R2_MODIFIER}',
    ]


def dpad_as_analog():
    # One hat() carrying both directions: the parser reads hat(N first second),
    # where the first drives the negative end. Y is inverted downstream
    # (iY = -axis_val), so Up leads there.
    return [
        'X Axis = "hat(0 Left Right)"',
        'Y Axis = "hat(0 Up Down)"',
    ]


def write(name, title, note, lines):
    body = HEADER.format(title=title, note=note) + "\n".join(lines) + "\n"
    out = pathlib.Path("config/shared/input") / name
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(body)
    print(f"wrote {out}")


write("cbuttons-on-r2.cfg",
      "No right analog stick — C-buttons on R2 + face buttons",
      CBUTTONS_NOTE,
      cbuttons())

write("h700-nosticks.cfg",
      "No analog sticks — C-buttons on R2, d-pad drives the N64 analog stick",
      NOSTICKS_NOTE,
      cbuttons() + dpad_as_analog())
