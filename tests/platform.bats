#!/usr/bin/env bats
#
# Unit tests for n64_platform_profile and n64_video_plugin in
# config/shared/platform.sh.
#
# Neither function does I/O — they read their arguments plus $SDL_VIDEO_EGL_DRIVER
# and set PROFILE_* / VIDEO_* variables — so these run on any host with no
# device, no toolchain and no cloned upstream tree.

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

# ── Glide64mk2 EGL preload ──────────────────────────────────────────────────
#
# Glide64mk2 showed a black screen on the tg5040's PowerVR GE8300 with libEGL.so
# preloaded. spruceOS runs the same upstream plugin there without the preload,
# so tg5040 drops it for Glide64mk2 alone.

@test "Glide64mk2 skips the EGL preload on every tg5040 device" {
    for device in brick brickpro ""; do
        profile tg5040 "$device"
        [ -z "$PROFILE_GLIDE64MK2_LD_PRELOAD" ]
        # The other plugins keep theirs.
        [ "$PROFILE_LD_PRELOAD" = "libEGL.so" ]
    done
}

@test "Glide64mk2 keeps the platform EGL preload everywhere else" {
    for platform in tg5050 my355 h700; do
        profile "$platform" ""
        [ -n "$PROFILE_GLIDE64MK2_LD_PRELOAD" ]
        [ "$PROFILE_GLIDE64MK2_LD_PRELOAD" = "$PROFILE_LD_PRELOAD" ]
    done
}

@test "Glide64mk2 on h700 follows the EGL library NextUI resolved" {
    SDL_VIDEO_EGL_DRIVER=/usr/lib/aarch64-linux-gnu/libEGL.so.1
    profile h700 rg35xxplus
    [ "$PROFILE_GLIDE64MK2_LD_PRELOAD" = "/usr/lib/aarch64-linux-gnu/libEGL.so.1" ]
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
# Every supported pad reports the same SDL button and axis numbers, so
# default.cfg fits them all; NextUI h700 rc11 made the Anbernic pads match. What
# varies is which sticks a model has, taken from NextUI's own table in
# workspace/h700/platform/platform.c. Its settings.cpp carries a second copy that
# is wrong about rg40xxv, so platform.c is the one followed here.

@test "h700 models with both sticks need no fragment" {
    for device in rg35xxh rg35xxpro rg40xxh rgcubexx rg34xxsp; do
        profile h700 "$device"
        [ "$PROFILE_HAS_LSTICK" -eq 1 ]
        [ "$PROFILE_HAS_RSTICK" -eq 1 ]
        [ -z "$PROFILE_INPUT_CFG" ]
    done
}

@test "rg40xxv has a left stick but no right one" {
    profile h700 rg40xxv
    [ "$PROFILE_HAS_LSTICK" -eq 1 ]
    [ "$PROFILE_HAS_RSTICK" -eq 0 ]
    [ "$PROFILE_INPUT_CFG" = "input/cbuttons-on-r2.cfg" ]
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

@test "the Brick has no sticks and shares the C-button fragment" {
    # Same fragment as rg40xxv: neither has a right stick, and both pads number
    # their buttons the same way.
    profile tg5040 brick
    [ "$PROFILE_HAS_LSTICK" -eq 0 ]
    [ "$PROFILE_HAS_RSTICK" -eq 0 ]
    [ "$PROFILE_INPUT_CFG" = "input/cbuttons-on-r2.cfg" ]
}

@test "the devices with both sticks need no fragment at all" {
    for spec in "tg5040 brickpro" "tg5040 smartpro" "tg5050 " "my355 "; do
        # shellcheck disable=SC2086
        set -- $spec
        profile "$1" "${2:-}"
        [ "$PROFILE_HAS_LSTICK" -eq 1 ]
        [ "$PROFILE_HAS_RSTICK" -eq 1 ]
        [ -z "$PROFILE_INPUT_CFG" ]
    done
}

@test "the profile carries no pad index overrides any more" {
    # rc11 made every pad report the same numbers, so these were removed. A
    # reappearance means someone is hardcoding a layout again.
    run grep -nE "PROFILE_(BTN_(A|B|L1|R1|MENU|SELECT|COUNT)|MOD_(L2|R2))=" \
        "$REPO_ROOT/config/shared/platform.sh"
    [ "$status" -ne 0 ]
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

# ── video plugin selection ──────────────────────────────────────────────────
#
# [NextUI] VideoPlugin uses the overlay's values: 0=GLideN64, 1=Rice,
# 2=Glide64mk2. VIDEO_PLUGIN_NAME is what the overlay filters its items on.

@test "VideoPlugin 0 selects GLideN64" {
    n64_video_plugin 0
    [ "$VIDEO_GFX_PLUGIN" = "mupen64plus-video-GLideN64.so" ]
    [ "$VIDEO_PLUGIN_NAME" = "gliden64" ]
}

@test "VideoPlugin 1 selects Rice" {
    n64_video_plugin 1
    [ "$VIDEO_GFX_PLUGIN" = "mupen64plus-video-rice.so" ]
    [ "$VIDEO_PLUGIN_NAME" = "rice" ]
}

@test "VideoPlugin 2 selects Glide64mk2" {
    n64_video_plugin 2
    [ "$VIDEO_GFX_PLUGIN" = "mupen64plus-video-glide64mk2.so" ]
    [ "$VIDEO_PLUGIN_NAME" = "glide64mk2" ]
}

@test "an unset or unknown VideoPlugin falls back to Rice" {
    for value in "" 3 -1 glide64mk2; do
        n64_video_plugin "$value"
        [ "$VIDEO_GFX_PLUGIN" = "mupen64plus-video-rice.so" ]
        [ "$VIDEO_PLUGIN_NAME" = "rice" ]
    done
}

@test "every plugin the selector names is one the overlay offers" {
    run python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
for sec in cfg["sections"]:
    for it in sec["items"]:
        if it["key"] == "VideoPlugin":
            print(" ".join(str(v) for v in it["values"]))
' "$REPO_ROOT/config/shared/overlay_settings.json"
    [ "$status" -eq 0 ]
    [ "$output" = "0 1 2" ]
    # Unknown values fall back to Rice, so check each one lands on its own plugin.
    seen=""
    for value in $output; do
        n64_video_plugin "$value"
        [[ " $seen " != *" $VIDEO_PLUGIN_NAME "* ]]
        seen="$seen $VIDEO_PLUGIN_NAME"
    done
}
