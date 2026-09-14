#!/usr/bin/env bats
#
# The per-device pad mappings in config/shared/input/.
#
# default.cfg carries the TrimUI layout. Devices whose pad differs name a
# fragment in the platform profile, which launch.sh merges over the seeded
# config. These tests drive the real `ini` helper, so they cover the merge the
# device actually performs rather than re-deriving it.
#
# The h700 indices come from NextUI's h700 SDL2 enumerating a pad's buttons in
# ascending evdev keycode order, with the Anbernic pad's ESC and volume keys
# taking 0-2. Measured by the nextui-portmaster-h700 project on hardware and
# corroborated by the NextCommander-h700 patch in NextUI.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    INPUT_DIR="$REPO_ROOT/config/shared/input"
    INI="$REPO_ROOT/tools/ini/build/ini"
    [ -x "$INI" ] || make -C "$REPO_ROOT/tools/ini" build-native >/dev/null
}

# binding <fragment> <key> — the value a fragment sets, via the real ini tool.
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

# ── h700 button indices, all three classes ──────────────────────────────────

@test "h700 face and shoulder buttons start at 3 on every class" {
    for f in h700-sticks.cfg h700-lstick.cfg h700-nosticks.cfg; do
        binding "$f" "A Button"; [ "$output" = "button(3)" ]
        binding "$f" "B Button"; [ "$output" = "button(4)" ]
        binding "$f" "L Trig";   [ "$output" = "button(7)" ]
        binding "$f" "R Trig";   [ "$output" = "button(8)" ]
        binding "$f" "Start";    [ "$output" = "button(10)" ]
    done
}

@test "h700 Z Trigger follows L2, which the stick clicks shift" {
    # No stick clicks: L2 is 12. A left stick adds L3 at 12 and pushes L2 to 13.
    binding h700-nosticks.cfg "Z Trig"; [ "$output" = "button(12)" ]
    binding h700-lstick.cfg   "Z Trig"; [ "$output" = "button(13)" ]
    binding h700-sticks.cfg   "Z Trig"; [ "$output" = "button(13)" ]
}

@test "h700 never binds an analog trigger, because it has none" {
    for f in h700-sticks.cfg h700-lstick.cfg h700-nosticks.cfg; do
        binding "$f" "Z Trig"
        [[ "$output" != *"axis"* ]]
    done
}

@test "h700 d-pad is the hat on every class" {
    for f in h700-sticks.cfg h700-lstick.cfg h700-nosticks.cfg; do
        binding "$f" "DPad U"; [ "$output" = "hat(0 Up)" ]
        binding "$f" "DPad R"; [ "$output" = "hat(0 Right)" ]
    done
}

# ── sticks are bound only where they exist ──────────────────────────────────

@test "the left stick drives the N64 analog stick where there is one" {
    binding h700-sticks.cfg "X Axis"; [ "$output" = "axis(0-,0+)" ]
    binding h700-lstick.cfg "X Axis"; [ "$output" = "axis(0-,0+)" ]
    binding h700-sticks.cfg "Y Axis"; [ "$output" = "axis(1-,1+)" ]
}

@test "with no left stick the d-pad drives the N64 analog stick instead" {
    # One hat() carrying both directions; the first drives the negative end, and
    # Y is inverted downstream, so Up leads.
    binding h700-nosticks.cfg "X Axis"; [ "$output" = "hat(0 Left Right)" ]
    binding h700-nosticks.cfg "Y Axis"; [ "$output" = "hat(0 Up Down)" ]
}

@test "the right stick drives the C-buttons where there is one" {
    binding h700-sticks.cfg "C Button R"; [ "$output" = "axis(2+,24000)" ]
    binding h700-sticks.cfg "C Button L"; [ "$output" = "axis(2-,24000)" ]
    binding h700-sticks.cfg "C Button D"; [ "$output" = "axis(3+,24000)" ]
    binding h700-sticks.cfg "C Button U"; [ "$output" = "axis(3-,24000)" ]
}

@test "no fragment binds a stick axis its class does not have" {
    for f in h700-nosticks.cfg tg5040-brick.cfg; do
        for key in "X Axis" "Y Axis" "C Button U" "C Button D" "C Button L" "C Button R"; do
            run "$INI" get "$INPUT_DIR/$f" "Input-SDL-Control1" "$key"
            [ "$status" -ne 0 ] || [[ "$output" != *"axis("* ]]
        done
    done
    # The left-stick-only class may use axes 0/1, never 2/3.
    for key in "C Button U" "C Button D" "C Button L" "C Button R"; do
        binding h700-lstick.cfg "$key"
        [[ "$output" != *"axis("* ]]
    done
}

# ── C-buttons without a right stick ─────────────────────────────────────────

@test "stickless classes reach the C-buttons through a held modifier" {
    # R2 + face button, by physical position: X top, B bottom, Y left, A right.
    binding h700-nosticks.cfg "C Button U"; [ "$output" = "button(6)" ]   # X
    binding h700-nosticks.cfg "C Button D"; [ "$output" = "button(4)" ]   # B
    binding h700-nosticks.cfg "C Button L"; [ "$output" = "button(5)" ]   # Y
    binding h700-nosticks.cfg "C Button R"; [ "$output" = "button(3)" ]   # A
}

@test "the modifier is R2 for each stickless class" {
    # No stick clicks: R2 is 13. A left stick shifts it to 14.
    for key in "C Button U" "C Button D" "C Button L" "C Button R"; do
        binding h700-nosticks.cfg "${key}_mod"; [ "$output" = "13" ]
        binding h700-lstick.cfg   "${key}_mod"; [ "$output" = "14" ]
    done
}

@test "the Brick reaches its C-buttons the same way, on its analog R2" {
    # TrimUI indices, and R2 is analog axis 5, encoded as -(5 + 1).
    binding tg5040-brick.cfg "C Button U"; [ "$output" = "button(3)" ]   # X
    binding tg5040-brick.cfg "C Button D"; [ "$output" = "button(0)" ]   # B
    binding tg5040-brick.cfg "C Button L"; [ "$output" = "button(2)" ]   # Y
    binding tg5040-brick.cfg "C Button R"; [ "$output" = "button(1)" ]   # A
    for key in "C Button U" "C Button D" "C Button L" "C Button R"; do
        binding tg5040-brick.cfg "${key}_mod"; [ "$output" = "-6" ]
    done
}

@test "the Brick fragment touches nothing but the C-buttons" {
    # Its face buttons and sticks already match default.cfg.
    for key in "A Button" "B Button" "Start" "Z Trig" "X Axis" "DPad U"; do
        run "$INI" get "$INPUT_DIR/tg5040-brick.cfg" "Input-SDL-Control1" "$key"
        [ "$status" -ne 0 ]
    done
}

# ── the merge launch.sh performs ────────────────────────────────────────────

@test "merging leaves the platforms whose pad matches default.cfg untouched" {
    for spec in "tg5040 brickpro" "tg5040 smartpro" "tg5050 " "my355 "; do
        # shellcheck disable=SC2086
        set -- $spec
        merged "$1" "${2:-}" "A Button"; [ "$output" = "button(1)" ]
        merged "$1" "${2:-}" "Z Trig";   [ "$output" = "axis(2+)" ]
    done
}

@test "merging rewrites the h700 bindings and keeps everything else" {
    merged h700 rg35xxplus "A Button"; [ "$output" = "button(3)" ]
    merged h700 rg35xxplus "Z Trig";   [ "$output" = "button(12)" ]
    # A key no fragment names keeps default.cfg's value.
    merged h700 rg35xxplus "mode"; [ "$output" = "0" ]
}

@test "merging gives the Brick working C-buttons without moving its face buttons" {
    merged tg5040 brick "C Button U";     [ "$output" = "button(3)" ]
    merged tg5040 brick "C Button U_mod"; [ "$output" = "-6" ]
    merged tg5040 brick "A Button";       [ "$output" = "button(1)" ]
}

@test "every N64 button is reachable on every h700 class" {
    for spec in "h700 rg35xxh" "h700 rg40xxv" "h700 rg35xxplus"; do
        # shellcheck disable=SC2086
        set -- $spec
        for key in "A Button" "B Button" "Start" "Z Trig" "L Trig" "R Trig" \
                   "C Button U" "C Button D" "C Button L" "C Button R" \
                   "DPad U" "DPad D" "DPad L" "DPad R" "X Axis" "Y Axis"; do
            merged "$1" "$2" "$key"
            [ -n "$output" ]
            [ "$output" != '""' ]
        done
    done
}
