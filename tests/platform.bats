#!/usr/bin/env bats
#
# Unit tests for n64_platform_profile in config/shared/platform.sh.
#
# The function does no I/O — it reads its two arguments plus $SDL_VIDEO_EGL_DRIVER
# and sets PROFILE_* variables — so these run on any host with no device, no
# toolchain and no cloned upstream tree.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    unset SDL_VIDEO_EGL_DRIVER
    # shellcheck source=/dev/null
    . "$REPO_ROOT/config/shared/platform.sh"
}

# profile <platform> <device>
profile() {
    n64_platform_profile "$1" "$2"
}

# ── tg5040: three devices share one toolchain ────────────────────────────────

@test "tg5040 brick renders at 1024x768 in its own config dir" {
    profile tg5040 brick
    [ "$PROFILE_RESOLUTION" = "1024x768" ]
    [ "$PROFILE_CONFIG_SUBDIR" = "brick" ]
    [ "$PROFILE_LEGACY_SUBDIR" = "tg5040-brick" ]
}

@test "tg5040 brickpro shares the Brick panel but not its config dir" {
    profile tg5040 brickpro
    [ "$PROFILE_RESOLUTION" = "1024x768" ]
    [ "$PROFILE_CONFIG_SUBDIR" = "brick-pro" ]
    [ "$PROFILE_LEGACY_SUBDIR" = "tg5040-brick-pro" ]
}

@test "tg5040 falls back to the Smart Pro profile for any other device" {
    profile tg5040 ""
    [ "$PROFILE_RESOLUTION" = "1280x720" ]
    [ "$PROFILE_CONFIG_SUBDIR" = "smart-pro" ]
    [ "$PROFILE_LEGACY_SUBDIR" = "tg5040-smart-pro" ]
}

@test "tg5040 disables anisotropy and brings cpu1-3 online" {
    profile tg5040 brick
    [ "$PROFILE_ANISOTROPY" -eq 0 ]
    [ "$PROFILE_ONLINE_CPUS" = "1 2 3" ]
    [ "$PROFILE_CPUFREQ_PATH" = "/sys/devices/system/cpu/cpu0/cpufreq" ]
}

@test "tg5040 has no GPU devfreq node and keeps the trimui lib dir" {
    profile tg5040 brick
    [ -z "$PROFILE_GPU_GOVERNOR_GLOB" ]
    [ "$PROFILE_LD_EXTRA_DIRS" = "/usr/trimui/lib" ]
    [ "$PROFILE_LD_PRELOAD" = "libEGL.so" ]
}

# ── tg5050: the only big.LITTLE platform ─────────────────────────────────────

@test "tg5050 drives the BIG cluster" {
    profile tg5050 ""
    [ "$PROFILE_CPUFREQ_PATH" = "/sys/devices/system/cpu/cpu4/cpufreq" ]
    [ "$PROFILE_ONLINE_CPUS" = "5" ]
    [ "$PROFILE_MAIN_MASK" = "0x10" ]
    [ "$PROFILE_HELPER_MASK" = "0x3" ]
    [ "$PROFILE_VIDEO_MASK" = "0x20" ]
}

@test "tg5050 enables anisotropy and uses the userdata dir directly" {
    profile tg5050 ""
    [ "$PROFILE_RESOLUTION" = "1280x720" ]
    [ "$PROFILE_ANISOTROPY" -eq 2 ]
    [ -z "$PROFILE_CONFIG_SUBDIR" ]
    [ "$PROFILE_LEGACY_SUBDIR" = "tg5050" ]
}

# ── my355 ────────────────────────────────────────────────────────────────────

@test "my355 is a 640x480 symmetric quad core" {
    profile my355 ""
    [ "$PROFILE_RESOLUTION" = "640x480" ]
    [ "$PROFILE_ANISOTROPY" -eq 2 ]
    [ "$PROFILE_ONLINE_CPUS" = "1 2 3" ]
    [ "$PROFILE_MAIN_MASK" = "1" ]
    [ "$PROFILE_HELPER_MASK" = "0xc" ]
    [ "$PROFILE_VIDEO_MASK" = "2" ]
}

@test "my355 has a GPU governor and no trimui lib dir" {
    profile my355 ""
    [ "$PROFILE_GPU_GOVERNOR_GLOB" = "/sys/class/devfreq/fde60000.gpu/governor" ]
    [ -z "$PROFILE_LD_EXTRA_DIRS" ]
}

# ── h700: one toolchain, eleven Anbernic models, three panel sizes ───────────

@test "h700 defaults to the 640x480 panel" {
    for device in rg28xx rg35xxplus rg35xxh rg35xxpro rg35xxsp rg40xxh rg40xxv; do
        profile h700 "$device"
        [ "$PROFILE_RESOLUTION" = "640x480" ]
    done
}

@test "h700 widescreen models render at 720x480" {
    for device in rg34xx rg34xxsp rgsp; do
        profile h700 "$device"
        [ "$PROFILE_RESOLUTION" = "720x480" ]
    done
}

@test "h700 rgcubexx renders at its square 720x720 panel" {
    profile h700 rgcubexx
    [ "$PROFILE_RESOLUTION" = "720x720" ]
}

@test "h700 gives each model its own config dir" {
    profile h700 rgcubexx
    [ "$PROFILE_CONFIG_SUBDIR" = "rgcubexx" ]
    [ "$PROFILE_LEGACY_SUBDIR" = "h700" ]
}

@test "h700 falls back to rg35xxplus when DEVICE is unset" {
    profile h700 ""
    [ "$PROFILE_CONFIG_SUBDIR" = "rg35xxplus" ]
    [ "$PROFILE_RESOLUTION" = "640x480" ]
}

@test "h700 disables anisotropy on the Mali-G31 MP1" {
    profile h700 rg35xxplus
    [ "$PROFILE_ANISOTROPY" -eq 0 ]
}

@test "h700 is a symmetric quad core with a globbed GPU devfreq node" {
    profile h700 rg35xxplus
    [ "$PROFILE_CPUFREQ_PATH" = "/sys/devices/system/cpu/cpu0/cpufreq" ]
    [ "$PROFILE_ONLINE_CPUS" = "1 2 3" ]
    [ "$PROFILE_MAIN_MASK" = "1" ]
    [ "$PROFILE_HELPER_MASK" = "0xc" ]
    [ "$PROFILE_VIDEO_MASK" = "2" ]
    [ "$PROFILE_GPU_GOVERNOR_GLOB" = '/sys/class/devfreq/*gpu*/governor' ]
}

@test "h700 skips swap and adds no extra loader directories" {
    profile h700 rg35xxplus
    [ -z "$PROFILE_SWAPFILE" ]
    [ -z "$PROFILE_LD_EXTRA_DIRS" ]
}

@test "h700 preloads the EGL library NextUI resolved, else the plain soname" {
    profile h700 rg35xxplus
    [ "$PROFILE_LD_PRELOAD" = "libEGL.so.1" ]

    SDL_VIDEO_EGL_DRIVER=/usr/lib/aarch64-linux-gnu/libEGL.so.1
    profile h700 rg35xxplus
    [ "$PROFILE_LD_PRELOAD" = "/usr/lib/aarch64-linux-gnu/libEGL.so.1" ]
}

# ── swap is only for platforms with a writable non-FAT partition ─────────────

@test "the TrimUI and Miyoo platforms all swap to /mnt/UDISK" {
    for platform in tg5040 tg5050 my355; do
        profile "$platform" ""
        [ "$PROFILE_SWAPFILE" = "/mnt/UDISK/n64_swap" ]
    done
}

# ── pad capabilities ────────────────────────────────────────────────────────
#
# Stick presence per h700 model is NextUI's own table, from
# workspace/h700/platform/platform.c. Its settings.cpp carries a second copy that
# is wrong about rg40xxv, so platform.c is the one followed here.

@test "h700 models with both sticks take the two-stick profile" {
    for device in rg35xxh rg35xxpro rg40xxh rgcubexx rg34xxsp; do
        profile h700 "$device"
        [ "$PROFILE_HAS_LSTICK" -eq 1 ]
        [ "$PROFILE_HAS_RSTICK" -eq 1 ]
        [ "$PROFILE_INPUT_CFG" = "input/h700-sticks.cfg" ]
    done
}

@test "rg40xxv has a left stick but no right one" {
    profile h700 rg40xxv
    [ "$PROFILE_HAS_LSTICK" -eq 1 ]
    [ "$PROFILE_HAS_RSTICK" -eq 0 ]
    [ "$PROFILE_INPUT_CFG" = "input/h700-lstick.cfg" ]
}

@test "the remaining h700 models have no sticks" {
    for device in rg28xx rg34xx rg35xxplus rg35xxsp rgsp; do
        profile h700 "$device"
        [ "$PROFILE_HAS_LSTICK" -eq 0 ]
        [ "$PROFILE_HAS_RSTICK" -eq 0 ]
        [ "$PROFILE_INPUT_CFG" = "input/h700-nosticks.cfg" ]
    done
}

@test "an unknown h700 device falls back to the stickless profile" {
    # NextUI defaults DEVICE to rg35xxplus, which has no sticks; assuming sticks
    # that are not there would leave the analog stick dead.
    profile h700 ""
    [ "$PROFILE_HAS_LSTICK" -eq 0 ]
    [ "$PROFILE_INPUT_CFG" = "input/h700-nosticks.cfg" ]
}

@test "h700 shoulder modifiers are buttons, and shift with the stick clicks" {
    profile h700 rg35xxplus          # no stick clicks
    [ "$PROFILE_MOD_L2" = "b12" ]
    [ "$PROFILE_MOD_R2" = "b13" ]
    profile h700 rg40xxv             # L3 takes 12
    [ "$PROFILE_MOD_L2" = "b13" ]
    [ "$PROFILE_MOD_R2" = "b14" ]
    profile h700 rgcubexx
    [ "$PROFILE_MOD_L2" = "b13" ]
    [ "$PROFILE_MOD_R2" = "b14" ]
}

@test "h700 Menu and Select sit where the ESC and volume keys push them" {
    for device in rg35xxplus rg40xxv rgcubexx; do
        profile h700 "$device"
        [ "$PROFILE_BTN_MENU" -eq 11 ]
        [ "$PROFILE_BTN_SELECT" -eq 9 ]
    done
}

@test "the h700 button scan stops short of Menu's KEY_GOTO echo" {
    # The pad emits Menu twice, and the echo would read as a phantom press.
    profile h700 rg35xxplus; [ "$PROFILE_BTN_COUNT" -eq 14 ]
    profile h700 rg40xxv;    [ "$PROFILE_BTN_COUNT" -eq 15 ]
    profile h700 rgcubexx;   [ "$PROFILE_BTN_COUNT" -eq 16 ]
}

# The overlay polls the pad directly, so its own navigation buttons need the
# layout as well. On h700 the TrimUI indices land on ESC, the volume keys and R1,
# which is what made Menu open on R1 and the menu keys misbehave.
@test "h700 overlay navigation uses the shifted indices" {
    for device in rg35xxplus rg40xxv rgcubexx; do
        profile h700 "$device"
        [ "$PROFILE_BTN_A" -eq 3 ]
        [ "$PROFILE_BTN_B" -eq 4 ]
        [ "$PROFILE_BTN_L1" -eq 7 ]
        [ "$PROFILE_BTN_R1" -eq 8 ]
        [ "$PROFILE_BTN_MENU" -eq 11 ]
    done
}

@test "no h700 navigation button collides with another" {
    profile h700 rgcubexx
    printf '%s\n' "$PROFILE_BTN_A" "$PROFILE_BTN_B" "$PROFILE_BTN_L1" \
        "$PROFILE_BTN_R1" "$PROFILE_BTN_MENU" "$PROFILE_BTN_SELECT" > "$BATS_TEST_TMPDIR/idx"
    [ "$(sort -u "$BATS_TEST_TMPDIR/idx" | wc -l)" -eq 6 ]
}

@test "h700 Menu is not R1, which is what the bug report showed" {
    profile h700 rg35xxplus
    [ "$PROFILE_BTN_MENU" -ne "$PROFILE_BTN_R1" ]
    # The TrimUI Menu index is h700's R1; using it opened the menu on R1.
    [ "$PROFILE_BTN_R1" -eq 8 ]
}

@test "the TrimUI and Miyoo pads keep the layout compiled into the overlay" {
    for spec in "tg5040 brickpro" "tg5040 smartpro" "tg5050 " "my355 "; do
        # shellcheck disable=SC2086
        set -- $spec
        profile "$1" "${2:-}"
        [ "$PROFILE_BTN_A" -eq 1 ]
        [ "$PROFILE_BTN_B" -eq 0 ]
        [ "$PROFILE_BTN_L1" -eq 4 ]
        [ "$PROFILE_BTN_R1" -eq 5 ]
        [ "$PROFILE_BTN_MENU" -eq 8 ]
        [ "$PROFILE_BTN_SELECT" -eq 6 ]
        [ "$PROFILE_MOD_L2" = "a2" ]
        [ "$PROFILE_MOD_R2" = "a5" ]
        [ "$PROFILE_BTN_COUNT" -eq 11 ]
        [ -z "$PROFILE_INPUT_CFG" ]
    done
}

@test "the Brick has no sticks and gets the C-button fragment" {
    profile tg5040 brick
    [ "$PROFILE_HAS_LSTICK" -eq 0 ]
    [ "$PROFILE_HAS_RSTICK" -eq 0 ]
    [ "$PROFILE_INPUT_CFG" = "input/tg5040-brick.cfg" ]
}

@test "the other TrimUI devices have both sticks and need no fragment" {
    for device in brickpro smartpro; do
        profile tg5040 "$device"
        [ "$PROFILE_HAS_LSTICK" -eq 1 ]
        [ "$PROFILE_HAS_RSTICK" -eq 1 ]
    done
}

# ── every shipped platform must be covered ──────────────────────────────────

@test "every platform in pak.json resolves a profile" {
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        unset PROFILE_RESOLUTION PROFILE_CPUFREQ_PATH PROFILE_LEGACY_SUBDIR
        profile "$platform" ""
        [ -n "$PROFILE_RESOLUTION" ]
        [ -n "$PROFILE_CPUFREQ_PATH" ]
        [ -n "$PROFILE_LEGACY_SUBDIR" ]
    done
}
