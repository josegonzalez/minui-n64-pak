"""Generate the per-device [Input-SDL-Control1] fragments in config/shared/input/.

Run from the repo root: python3 scripts/gen-input-cfg.py Regenerate whenever a table changes; the output is
committed, and tests/input.bats asserts the files rather than re-deriving them.

Devices with no right analog stick reach the C-buttons by holding R2 and pressing
a face button, by physical position. That combo is expressed with the `<key>_mod`
suffix the overlay's config loader understands: it writes the pair into
$EMU_BUTTON_MAP_FILE, and the patched input plugin applies the modifier there.
The plain binding on the same key is what mupen64plus's own parser sees, which
has no notion of modifiers, but the plugin clears and re-derives every N64 button
bit from the map file each frame, so the map file is what actually takes effect.

Modifier encoding matches the overlay: a non-negative value is an SDL button
index, and a negative value is -(axis index + 1) for an analog shoulder.
"""
import pathlib

HEADER = """; {title}
;
; Merged over default.cfg by launch.sh via the bundled `ini merge`, once per
; device. Only the keys below are replaced, so anything the user changes
; afterwards survives.
;
{layout}
[Input-SDL-Control1]
"""

H700_LAYOUT = """; SDL button indices for NextUI's h700 SDL2, which enumerates a pad's buttons in
; ascending evdev keycode order. The Anbernic pad reports ESC (1) and the two
; volume keys (114/115) first, so its gamepad buttons start at index 3:
;
{table}
;
; The d-pad is SDL hat 0 (ABS_HAT0X/Y). {sticks}
;
"""

BRICK_LAYOUT = """; The TrimUI Brick has no analog sticks at all. default.cfg points the C-buttons
; at right-stick axes the Brick does not have, so they are unreachable; bind them
; to R2 + a face button by physical position instead. R2 is analog axis 5 here,
; so the modifier is encoded as -(5 + 1).
;
"""

# (evdev code, label) in ascending code order after ESC/VOL, which take 0-2.
BASE = [
    (304, "A"), (305, "B"), (306, "Y"), (307, "X"),
    (308, "L1"), (309, "R1"), (310, "Select"), (311, "Start"), (312, "Menu"),
]


def indices(has_l, has_r):
    codes = list(BASE)
    if has_l:
        codes.append((313, "L3"))
    codes += [(314, "L2"), (315, "R2")]
    if has_r:
        codes.append((316, "R3"))
    return {label: i + 3 for i, (_c, label) in enumerate(codes)}


def render_table(idx):
    return "\n".join(f";   {label:<10} button({n})" for label, n in idx.items())


def write(name, body):
    out = pathlib.Path("config/shared/input") / name
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(body)
    print(f"wrote {out}")


def cbuttons_from_modifier(idx, mod):
    """R2 + face button, by physical position on the pad."""
    return [
        f'C Button U = "button({idx["X"]})"',   # X is the top face button
        f'C Button U_mod = {mod}',
        f'C Button D = "button({idx["B"]})"',   # B is the bottom one
        f'C Button D_mod = {mod}',
        f'C Button L = "button({idx["Y"]})"',   # Y is the left one
        f'C Button L_mod = {mod}',
        f'C Button R = "button({idx["A"]})"',   # A is the right one
        f'C Button R_mod = {mod}',
    ]


def h700_fragment(name, title, has_l, has_r):
    idx = indices(has_l, has_r)
    if has_r:
        sticks = ("Left stick is axes 0/1 and drives the N64 analog stick;\n"
                  "; right stick is axes 2/3 and drives the C-buttons.")
    elif has_l:
        sticks = ("Left stick is axes 0/1 and drives the N64 analog stick.\n"
                  "; With no right stick, C-buttons are R2 + a face button.")
    else:
        sticks = ("With no sticks at all, the d-pad drives the N64 analog stick\n"
                  "; as well as the N64 d-pad, and C-buttons are R2 + a face button.\n"
                  "; Double-binding the d-pad is deliberate: nearly every N64 game reads\n"
                  "; one or the other, so binding both leaves neither dead. The Brick\n"
                  "; instead has trimui_inputd swap them at the kernel level, which h700\n"
                  "; has no equivalent of.")

    layout = H700_LAYOUT.format(table=render_table(idx), sticks=sticks)
    lines = [HEADER.format(title=title, layout=layout)]
    add = lines.append

    add('DPad R = "hat(0 Right)"')
    add('DPad L = "hat(0 Left)"')
    add('DPad D = "hat(0 Down)"')
    add('DPad U = "hat(0 Up)"')
    add(f'Start = "button({idx["Start"]})"')
    # H700 has no analog triggers: L2 and R2 are plain buttons.
    add(f'Z Trig = "button({idx["L2"]})"')
    add(f'B Button = "button({idx["B"]})"')
    add(f'A Button = "button({idx["A"]})"')

    if has_r:
        # Right stick X = axis 2, Y = axis 3; negative is left/up.
        add('C Button R = "axis(2+,24000)"')
        add('C Button L = "axis(2-,24000)"')
        add('C Button D = "axis(3+,24000)"')
        add('C Button U = "axis(3-,24000)"')
    else:
        for line in cbuttons_from_modifier(idx, idx["R2"]):
            add(line)

    add(f'R Trig = "button({idx["R1"]})"')
    add(f'L Trig = "button({idx["L1"]})"')

    if has_l:
        add('X Axis = "axis(0-,0+)"')
        add('Y Axis = "axis(1-,1+)"')
    else:
        # One hat() carrying both directions: the parser reads
        # hat(N first second), where the first drives the negative end. Y is
        # inverted downstream (iY = -axis_val), so Up leads there.
        add('X Axis = "hat(0 Left Right)"')
        add('Y Axis = "hat(0 Up Down)"')

    write(name, "\n".join(lines) + "\n")


def brick_fragment():
    # TrimUI pad indices, from default.cfg: B=0 A=1 Y=2 X=3.
    idx = {"A": 1, "B": 0, "Y": 2, "X": 3}
    lines = [HEADER.format(
        title="TrimUI Brick — C-buttons on R2 + face buttons",
        layout=BRICK_LAYOUT)]
    for line in cbuttons_from_modifier(idx, -6):
        lines.append(line)
    write("tg5040-brick.cfg", "\n".join(lines) + "\n")


h700_fragment("h700-sticks.cfg", "Anbernic H700 — left and right analog sticks", True, True)
h700_fragment("h700-lstick.cfg", "Anbernic H700 — left analog stick only (RG40XXV)", True, False)
h700_fragment("h700-nosticks.cfg", "Anbernic H700 — no analog sticks", False, False)
brick_fragment()
