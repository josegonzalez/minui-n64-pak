#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
set -x

rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

EMU_TAG=$(basename "$(dirname "$0")" .pak)
BIN_DIR="$PAK_DIR/$PLATFORM"
ROM="$1"

mkdir -p "$SAVES_PATH/$EMU_TAG"

# ── Save original system settings (restored on exit) ─────────────────────────
ORIG_SPEAKER_MUTE=$(cat /sys/class/speaker/mute 2>/dev/null)
ORIG_VFS_CACHE=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)
case "$PLATFORM" in
    tg5040)
        ORIG_CPU1=$(cat /sys/devices/system/cpu/cpu1/online 2>/dev/null)
        ORIG_CPU2=$(cat /sys/devices/system/cpu/cpu2/online 2>/dev/null)
        ORIG_CPU3=$(cat /sys/devices/system/cpu/cpu3/online 2>/dev/null)
        ;;
    tg5050)
        ORIG_CPU5=$(cat /sys/devices/system/cpu/cpu5/online 2>/dev/null)
        ORIG_GPU_GOV=$(cat /sys/devices/platform/soc@3000000/1800000.gpu/devfreq/1800000.gpu/governor 2>/dev/null)
        ;;
esac

# ── CPU / GPU setup (platform-specific) ──────────────────────────────────────
# CPU governor and frequency are managed by the emulator (overlay menu CPU Mode).
# launch.sh only brings CPUs online and sets the GPU governor.
case "$PLATFORM" in
    tg5040)
        # Bring all cores online (single cluster: cpu0-3 Cortex-A53)
        echo 1 >/sys/devices/system/cpu/cpu1/online 2>/dev/null
        echo 1 >/sys/devices/system/cpu/cpu2/online 2>/dev/null
        echo 1 >/sys/devices/system/cpu/cpu3/online 2>/dev/null
        ;;
    tg5050)
        # Bring BIG core online (cpu4-5 Cortex-A55)
        echo 1 >/sys/devices/system/cpu/cpu5/online 2>/dev/null
        # GPU: lock to performance for GLideN64 rendering
        echo performance >/sys/devices/platform/soc@3000000/1800000.gpu/devfreq/1800000.gpu/governor 2>/dev/null
        ;;
esac

# ── Memory management: swap + VM tuning for hi-res texture loading ────────────
SWAPFILE="/mnt/UDISK/n64_swap"
if [ ! -f "$SWAPFILE" ]; then
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=512 2>/dev/null
    mkswap "$SWAPFILE" 2>/dev/null
fi
swapon "$SWAPFILE" 2>/dev/null
echo 200 >/proc/sys/vm/vfs_cache_pressure 2>/dev/null
sync
echo 3 >/proc/sys/vm/drop_caches 2>/dev/null

# ── User data and device-specific config ──────────────────────────────────────
USERDATA_DIR="$SHARED_USERDATA_PATH/N64-mupen64plus"
mkdir -p "$USERDATA_DIR/save"

# Device-specific config directory and display resolution
case "$PLATFORM" in
    tg5040)
        if [ "$DEVICE" = "brick" ]; then
            DEVICE_CONFIG_DIR="$USERDATA_DIR/config/tg5040-brick"
            DEVICE_RESOLUTION="1024x768"
            DEVICE_ANISOTROPY=0
        else
            DEVICE_CONFIG_DIR="$USERDATA_DIR/config/tg5040-smart-pro"
            DEVICE_RESOLUTION="1280x720"
            DEVICE_ANISOTROPY=0
        fi
        ;;
    tg5050)
        DEVICE_CONFIG_DIR="$USERDATA_DIR/config/tg5050"
        DEVICE_RESOLUTION="1280x720"
        # Anisotropic filtering: sharpens textures viewed at oblique angles.
        # Mali-G57 (tg5050) can handle level 2; PowerVR GE8300 (tg5040) cannot.
        DEVICE_ANISOTROPY=2
        ;;
esac
mkdir -p "$DEVICE_CONFIG_DIR"

# First run: seed config from base defaults
if [ ! -f "$DEVICE_CONFIG_DIR/.initialized" ]; then
    cp "$BIN_DIR/default.cfg" "$DEVICE_CONFIG_DIR/mupen64plus.cfg"
    touch "$DEVICE_CONFIG_DIR/.initialized"
fi

# Patch platform-specific values on every launch so the config stays correct
# even if the pak is moved to a different device.
DEVICE_CFG="$DEVICE_CONFIG_DIR/mupen64plus.cfg"
SCREEN_W="${DEVICE_RESOLUTION%x*}"
SCREEN_H="${DEVICE_RESOLUTION#*x}"
sed -i "s/^ScreenWidth = .*/ScreenWidth = $SCREEN_W/" "$DEVICE_CFG"
sed -i "s/^ScreenHeight = .*/ScreenHeight = $SCREEN_H/" "$DEVICE_CFG"
sed -i "s/^anisotropy = .*/anisotropy = $DEVICE_ANISOTROPY/" "$DEVICE_CFG"

# ── Environment ───────────────────────────────────────────────────────────────
export HOME="$USERDATA_PATH"
export LD_LIBRARY_PATH="$BIN_DIR:$SDCARD_PATH/.system/$PLATFORM/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export LD_PRELOAD="libEGL.so"

# ── Overlay menu config ──────────────────────────────────────────────────────
export EMU_OVERLAY_JSON="$BIN_DIR/overlay_settings.json"
export EMU_OVERLAY_INI="$DEVICE_CONFIG_DIR/mupen64plus.cfg"
export EMU_OVERLAY_GAME="$(basename "$ROM" | sed 's/\.[^.]*$//')"
# Font from NextUI system resources; icon PNGs vendored in platform dir
FONT_FILE=$(ls "$SDCARD_PATH/.system/res/"*.ttf 2>/dev/null | head -1)
export EMU_OVERLAY_FONT="${FONT_FILE:-$SDCARD_PATH/.system/res/font.ttf}"
export EMU_OVERLAY_RES="$BIN_DIR"
# Screenshot directory (matches minarch's .minui path for game switcher)
MINUI_DIR="$SHARED_USERDATA_PATH/.minui/$EMU_TAG"
mkdir -p "$MINUI_DIR"
export EMU_OVERLAY_SCREENSHOT_DIR="$MINUI_DIR"
export EMU_OVERLAY_ROMFILE="$(basename "$ROM")"

# ── Launch ────────────────────────────────────────────────────────────────────
# Mute speaker before launch to prevent audio pop, then unmute after init
echo 1 > /sys/class/speaker/mute 2>/dev/null || true
(sleep 5; echo 0 > /sys/class/speaker/mute 2>/dev/null; command -v syncsettings.elf >/dev/null && syncsettings.elf) &
SYNC_PID=$!

# Start power button sleep/poweroff handler (if available — GLideN64 handles it natively)
command -v sleepmon.elf >/dev/null && sleepmon.elf &

# Launch from BIN_DIR so core library resolves via ./
cd "$BIN_DIR"
./mupen64plus --fullscreen --resolution "$DEVICE_RESOLUTION" \
    --configdir "$DEVICE_CONFIG_DIR" \
    --datadir "$BIN_DIR" \
    --plugindir "$BIN_DIR" \
    --gfx "$BIN_DIR/mupen64plus-video-GLideN64.so" \
    --audio mupen64plus-audio-sdl.so \
    --input mupen64plus-input-sdl.so \
    --rsp mupen64plus-rsp-hle.so \
    "$ROM" &> "$LOGS_PATH/$EMU_TAG.mupen64plus.txt" &
EMU_PID=$!
sleep 4

# ── Thread pinning (platform-specific CPU topology) ──────────────────────────
case "$PLATFORM" in
    tg5040)
        # cpu0-3 are all Cortex-A53 @ 2000 MHz
        MAIN_MASK=1     # cpu0
        HELPER_MASK=0xc # cpu2-3
        VIDEO_MASK=2    # cpu1
        ;;
    tg5050)
        # big.LITTLE: cpu4-5 BIG (A55), cpu0-1 LITTLE
        MAIN_MASK=0x10  # cpu4
        HELPER_MASK=0x3 # cpu0-1
        VIDEO_MASK=0x20 # cpu5
        ;;
esac

taskset -p $MAIN_MASK "$EMU_PID" 2>/dev/null

# Pin known helper threads
for TID in $(ls /proc/$EMU_PID/task/ 2>/dev/null); do
    [ "$TID" = "$EMU_PID" ] && continue
    TNAME=$(cat /proc/$EMU_PID/task/$TID/comm 2>/dev/null)
    case "$TNAME" in
        SDLAudioP2|SDLHotplug*|SDLTimer|mali-*|m64pwq)
            taskset -p $HELPER_MASK "$TID" 2>/dev/null ;;
    esac
done

# Find the busiest non-main mupen64plus thread (video thread) and pin it
sleep 2
BEST_TID=""
BEST_UTIME=0
for TID in $(ls /proc/$EMU_PID/task/ 2>/dev/null); do
    [ "$TID" = "$EMU_PID" ] && continue
    TNAME=$(cat /proc/$EMU_PID/task/$TID/comm 2>/dev/null)
    [ "$TNAME" = "mupen64plus" ] || continue
    UTIME=$(awk '{print $14}' /proc/$EMU_PID/task/$TID/stat 2>/dev/null)
    UTIME=${UTIME:-0}
    if [ "$UTIME" -gt "$BEST_UTIME" ]; then
        BEST_UTIME=$UTIME
        BEST_TID=$TID
    fi
done
[ -n "$BEST_TID" ] && taskset -p $VIDEO_MASK "$BEST_TID" 2>/dev/null

# ── Cleanup: restore all saved system settings ───────────────────────────────
wait $EMU_PID
killall sleepmon.elf 2>/dev/null || true
kill $SYNC_PID 2>/dev/null || true

# Restore CPU online state and GPU governor (CPU governor/freq managed by emulator)
case "$PLATFORM" in
    tg5040)
        [ -n "$ORIG_CPU3" ] && echo "$ORIG_CPU3" >/sys/devices/system/cpu/cpu3/online 2>/dev/null
        [ -n "$ORIG_CPU2" ] && echo "$ORIG_CPU2" >/sys/devices/system/cpu/cpu2/online 2>/dev/null
        [ -n "$ORIG_CPU1" ] && echo "$ORIG_CPU1" >/sys/devices/system/cpu/cpu1/online 2>/dev/null
        ;;
    tg5050)
        [ -n "$ORIG_GPU_GOV" ] && echo "$ORIG_GPU_GOV" >/sys/devices/platform/soc@3000000/1800000.gpu/devfreq/1800000.gpu/governor 2>/dev/null
        [ -n "$ORIG_CPU5" ] && echo "$ORIG_CPU5" >/sys/devices/system/cpu/cpu5/online 2>/dev/null
        ;;
esac

# Restore speaker, swap, VM settings
[ -n "$ORIG_SPEAKER_MUTE" ] && echo "$ORIG_SPEAKER_MUTE" >/sys/class/speaker/mute 2>/dev/null
swapoff "$SWAPFILE" 2>/dev/null
[ -n "$ORIG_VFS_CACHE" ] && echo "$ORIG_VFS_CACHE" >/proc/sys/vm/vfs_cache_pressure 2>/dev/null
