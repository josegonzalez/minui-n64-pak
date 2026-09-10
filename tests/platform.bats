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
