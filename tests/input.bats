#!/usr/bin/env bats
#
# The per-device pad mappings in config/shared/input/.
#
# Every supported pad reports the same SDL button and axis numbers — B=0 A=1 Y=2
# X=3 L1=4 R1=5 Select=6 Start=7 Menu=8, axes 0/1 the left stick, 3/4 the right,
# 2 and 5 the L2/R2 triggers, d-pad on hat 0 — so default.cfg fits them all.
# NextUI h700 rc11 made the Anbernic pads match; before it their numbers differed
# per model and from TrimUI's.
#
# What varies is which sticks a model physically has. default.cfg binds the left
# stick to the N64 analog stick and the right stick to the C-buttons, so a model
# missing either needs those rebound. These tests drive the real `ini` helper, so
# they cover the merge the device actually performs.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    INPUT_DIR="$REPO_ROOT/config/shared/input"
    INI="$REPO_ROOT/tools/ini/build/ini"
    [ -x "$INI" ] || make -C "$REPO_ROOT/tools/ini" build-native >/dev/null
}

# binding <fragment> <key>
binding() {
    run "$INI" get "$INPUT_DIR/$1" "Input-SDL-Control1" "$2"
    [ "$status" -eq 0 ]
}

# merged <platform> <device> <key> — the value after launch.sh's merge.
merged() {
    # shellcheck source=/dev/null
    . "$REPO_ROOT/config/shared/platform.sh"
    n64_platform_profile "$1" "$2"
    cp "$REPO_ROOT/config/shared/default.cfg" "$BATS_TEST_TMPDIR/merged.cfg"
    if [ -n "$PROFILE_INPUT_CFG" ]; then
        "$INI" merge "$BATS_TEST_TMPDIR/merged.cfg" "$REPO_ROOT/config/shared/$PROFILE_INPUT_CFG"
    fi
    run "$INI" get "$BATS_TEST_TMPDIR/merged.cfg" "Input-SDL-Control1" "$3"
    [ "$status" -eq 0 ]
}

# ── the fragments exist and are well-formed ─────────────────────────────────

@test "every fragment a profile names is actually shipped" {
    # shellcheck source=/dev/null
    . "$REPO_ROOT/config/shared/platform.sh"
    for spec in "tg5040 brick" "tg5040 brickpro" "tg5040 smartpro" "tg5050 " "my355 " \
                "h700 rg35xxh" "h700 rg35xxpro" "h700 rg40xxh" "h700 rgcubexx" \
                "h700 rg34xxsp" "h700 rg40xxv" "h700 rg28xx" "h700 rg34xx" \
                "h700 rg35xxplus" "h700 rg35xxsp" "h700 rgsp" "h700 "; do
        # shellcheck disable=SC2086
        set -- $spec
        n64_platform_profile "$1" "${2:-}"
        [ -z "$PROFILE_INPUT_CFG" ] || [ -f "$REPO_ROOT/config/shared/$PROFILE_INPUT_CFG" ]
    done
}

@test "every fragment declares the controller section" {
    for f in "$INPUT_DIR"/*.cfg; do
        run grep -q '^\[Input-SDL-Control1\]' "$f"
        [ "$status" -eq 0 ]
    done
}

@test "no fragment rebinds a button, only what a missing stick made unreachable" {
    # Face buttons, shoulders, Start and the d-pad are the same on every pad, so
    # a fragment touching them would be re-introducing a per-device layout.
    for f in "$INPUT_DIR"/*.cfg; do
        for key in "A Button" "B Button" "Start" "Z Trig" "L Trig" "R Trig" \
                   "DPad U" "DPad D" "DPad L" "DPad R"; do
            run "$INI" get "$f" "Input-SDL-Control1" "$key"
            [ "$status" -ne 0 ]
        done
    done
}

# ── C-buttons without a right stick ─────────────────────────────────────────

@test "the C-button fragment uses R2 plus a face button by position" {
    # X top, B bottom, Y left, A right.
    binding cbuttons-on-r2.cfg "C Button U"; [ "$output" = "button(3)" ]
    binding cbuttons-on-r2.cfg "C Button D"; [ "$output" = "button(0)" ]
    binding cbuttons-on-r2.cfg "C Button L"; [ "$output" = "button(2)" ]
    binding cbuttons-on-r2.cfg "C Button R"; [ "$output" = "button(1)" ]
}

@test "the modifier is R2, encoded as its analog axis" {
    # R2 is axis 5, and an axis modifier is stored as -(index + 1).
    for key in "C Button U" "C Button D" "C Button L" "C Button R"; do
        binding cbuttons-on-r2.cfg "${key}_mod"; [ "$output" = "-6" ]
        binding h700-nosticks.cfg  "${key}_mod"; [ "$output" = "-6" ]
    done
}

@test "no fragment leaves a C-button on an axis its device cannot reach" {
    for f in "$INPUT_DIR"/*.cfg; do
        for key in "C Button U" "C Button D" "C Button L" "C Button R"; do
            run "$INI" get "$f" "Input-SDL-Control1" "$key"
            [ "$status" -ne 0 ] || [[ "$output" != *"axis("* ]]
        done
    done
}

# ── the analog stick on a device with no sticks ─────────────────────────────

@test "with no sticks the d-pad drives the N64 analog stick" {
    # One hat() carrying both directions; the first drives the negative end, and
    # Y is inverted downstream, so Up leads.
    binding h700-nosticks.cfg "X Axis"; [ "$output" = "hat(0 Left Right)" ]
    binding h700-nosticks.cfg "Y Axis"; [ "$output" = "hat(0 Up Down)" ]
}

@test "a device that keeps its left stick does not touch the analog axes" {
    # rg40xxv and the Brick both have a usable left stick binding in default.cfg.
    for key in "X Axis" "Y Axis"; do
        run "$INI" get "$INPUT_DIR/cbuttons-on-r2.cfg" "Input-SDL-Control1" "$key"
        [ "$status" -ne 0 ]
    done
}

# ── the merge launch.sh performs ────────────────────────────────────────────

@test "devices with both sticks keep default.cfg untouched" {
    for spec in "tg5040 brickpro" "tg5040 smartpro" "tg5050 " "my355 " \
                "h700 rg35xxh" "h700 rgcubexx"; do
        # shellcheck disable=SC2086
        set -- $spec
        merged "$1" "${2:-}" "A Button";   [ "$output" = "button(1)" ]
        merged "$1" "${2:-}" "Z Trig";     [ "$output" = "axis(2+)" ]
        merged "$1" "${2:-}" "X Axis";     [ "$output" = "axis(0-,0+)" ]
        merged "$1" "${2:-}" "C Button R"; [ "$output" = "axis(3+,24000)" ]
    done
}

@test "merging keeps the shared buttons and rebinds only the unreachable parts" {
    merged h700 rg35xxplus "A Button"; [ "$output" = "button(1)" ]
    merged h700 rg35xxplus "Z Trig";   [ "$output" = "axis(2+)" ]
    merged h700 rg35xxplus "X Axis";   [ "$output" = "hat(0 Left Right)" ]
    merged h700 rg35xxplus "C Button U_mod"; [ "$output" = "-6" ]
    # A key no fragment names keeps default.cfg's value.
    merged h700 rg35xxplus "mode"; [ "$output" = "0" ]
}

@test "rg40xxv keeps its left stick and moves only the C-buttons" {
    merged h700 rg40xxv "X Axis";         [ "$output" = "axis(0-,0+)" ]
    merged h700 rg40xxv "C Button U";     [ "$output" = "button(3)" ]
    merged h700 rg40xxv "C Button U_mod"; [ "$output" = "-6" ]
}

@test "the Brick gets working C-buttons without moving its face buttons" {
    merged tg5040 brick "C Button U";     [ "$output" = "button(3)" ]
    merged tg5040 brick "C Button U_mod"; [ "$output" = "-6" ]
    merged tg5040 brick "A Button";       [ "$output" = "button(1)" ]
    # trimui_inputd swaps its d-pad and analog stick, so leave the axes alone.
    merged tg5040 brick "X Axis";         [ "$output" = "axis(0-,0+)" ]
}

@test "every N64 button is reachable on every device" {
    for spec in "h700 rg35xxh" "h700 rg40xxv" "h700 rg35xxplus" "tg5040 brick" \
                "tg5040 smartpro" "tg5050 " "my355 "; do
        # shellcheck disable=SC2086
        set -- $spec
        for key in "A Button" "B Button" "Start" "Z Trig" "L Trig" "R Trig" \
                   "C Button U" "C Button D" "C Button L" "C Button R" \
                   "DPad U" "DPad D" "DPad L" "DPad R" "X Axis" "Y Axis"; do
            merged "$1" "${2:-}" "$key"
            [ -n "$output" ]
            [ "$output" != '""' ]
        done
    done
}
