#!/bin/sh
# Per-platform and per-device facts for the N64 pak.
#
# Sourced by launch.sh, which is the only consumer at runtime. Kept separate so
# tests/platform.bats can assert the table without a device: n64_platform_profile
# does no I/O — it reads its two arguments plus $SDL_VIDEO_EGL_DRIVER and sets
# PROFILE_* variables.

# n64_platform_profile <platform> <device>
n64_platform_profile() {
    _platform="$1"
    _device="$2"

    # Defaults shared by the TrimUI and Miyoo platforms. Overridden per platform below.
    PROFILE_CPUFREQ_PATH="/sys/devices/system/cpu/cpu0/cpufreq"
    PROFILE_ONLINE_CPUS="1 2 3"
    PROFILE_GPU_GOVERNOR_GLOB=""
    PROFILE_RESOLUTION="1280x720"
    PROFILE_ANISOTROPY=0
    PROFILE_CONFIG_SUBDIR=""
    PROFILE_LEGACY_SUBDIR="$_platform"
    # cpu0-3 symmetric: main on cpu0, video on cpu1, helpers on cpu2-3.
    PROFILE_MAIN_MASK=1
    PROFILE_HELPER_MASK=0xc
    PROFILE_VIDEO_MASK=2
    # Swap backs hi-res texture loading. Only the TrimUI and Miyoo devices have a
    # writable non-FAT partition to put it on.
    PROFILE_SWAPFILE="/mnt/UDISK/n64_swap"
    PROFILE_LD_EXTRA_DIRS=""
    PROFILE_LD_PRELOAD="libEGL.so"

    case "$_platform" in
        tg5040)
            # Single cluster of Cortex-A53. No GPU devfreq node: the PowerVR
            # GE8300 does not expose one.
            PROFILE_LD_EXTRA_DIRS="/usr/trimui/lib"
            # The tg5040 toolchain is shared between the Brick, Brick Pro and
            # Smart Pro, so each needs its own config dir within the platform.
            if [ "$_device" = "brick" ]; then
                PROFILE_CONFIG_SUBDIR="brick"
                PROFILE_RESOLUTION="1024x768"
                PROFILE_LEGACY_SUBDIR="tg5040-brick"
            elif [ "$_device" = "brickpro" ]; then
                PROFILE_CONFIG_SUBDIR="brick-pro"
                PROFILE_RESOLUTION="1024x768"
                PROFILE_LEGACY_SUBDIR="tg5040-brick-pro"
            else
                PROFILE_CONFIG_SUBDIR="smart-pro"
                PROFILE_RESOLUTION="1280x720"
                PROFILE_LEGACY_SUBDIR="tg5040-smart-pro"
            fi
            # Anisotropic filtering sharpens textures viewed at oblique angles.
            # PowerVR GE8300 cannot handle it.
            PROFILE_ANISOTROPY=0
            ;;
        tg5050)
            # big.LITTLE: cpu4-5 are the BIG Cortex-A55 pair, cpu0-1 the LITTLE.
            PROFILE_CPUFREQ_PATH="/sys/devices/system/cpu/cpu4/cpufreq"
            PROFILE_ONLINE_CPUS="5"
            PROFILE_GPU_GOVERNOR_GLOB="/sys/devices/platform/soc@3000000/1800000.gpu/devfreq/1800000.gpu/governor"
            PROFILE_RESOLUTION="1280x720"
            PROFILE_ANISOTROPY=2  # Mali-G57 handles level 2
            PROFILE_MAIN_MASK=0x10   # cpu4
            PROFILE_HELPER_MASK=0x3  # cpu0-1
            PROFILE_VIDEO_MASK=0x20  # cpu5
            PROFILE_LD_EXTRA_DIRS="/usr/trimui/lib"
            ;;
        my355)
            # Single cluster of Cortex-A55.
            PROFILE_GPU_GOVERNOR_GLOB="/sys/class/devfreq/fde60000.gpu/governor"
            PROFILE_RESOLUTION="640x480"
            PROFILE_ANISOTROPY=2  # Mali-G52 handles level 2 anisotropy smoothly
            ;;
        h700)
            # Single cluster of Cortex-A53. NextUI's h700 port exports DEVICE for
            # each Anbernic model; panel size is the only thing that varies.
            PROFILE_GPU_GOVERNOR_GLOB="/sys/class/devfreq/*gpu*/governor"
            case "$_device" in
                rg34xx|rg34xxsp|rgsp) PROFILE_RESOLUTION="720x480" ;;
                rgcubexx)             PROFILE_RESOLUTION="720x720" ;;
                # rg28xx's panel is physically portrait; NextUI exports
                # SDL_ROTATION=1 so applications still see 640x480 landscape.
                *)                    PROFILE_RESOLUTION="640x480" ;;
            esac
            # Mali-G31 MP1 is the weakest GPU the pak targets.
            PROFILE_ANISOTROPY=0
            PROFILE_CONFIG_SUBDIR="${_device:-rg35xxplus}"
            PROFILE_LEGACY_SUBDIR="h700"
            # No writable non-FAT partition: the SD card is FAT and the stock
            # Ubuntu rootfs is too small to give up 512 MB.
            PROFILE_SWAPFILE=""
            # The stock OS keeps its EGL under /usr/lib or the multiarch dir;
            # NextUI has already resolved it for us.
            PROFILE_LD_PRELOAD="${SDL_VIDEO_EGL_DRIVER:-libEGL.so.1}"
            ;;
    esac

    unset _platform _device
}
