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
        ORIG_CPU_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        ORIG_CPU_MIN=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null)
        ORIG_CPU_MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
        ;;
    tg5050)
        ORIG_CPU5=$(cat /sys/devices/system/cpu/cpu5/online 2>/dev/null)
        ORIG_GPU_GOV=$(cat /sys/devices/platform/soc@3000000/1800000.gpu/devfreq/1800000.gpu/governor 2>/dev/null)
        ORIG_CPU_GOV=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_governor 2>/dev/null)
        ORIG_CPU_MIN=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 2>/dev/null)
        ORIG_CPU_MAX=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq 2>/dev/null)
        ;;
esac

# ── CPU / GPU setup (platform-specific) ──────────────────────────────────────
# CPU governor and frequency may be changed at runtime by the emulator (overlay
# menu CPU Mode). Original values are saved above and restored on exit.
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

# ── User data and device-specific config ─────────────────────────────────────
# Config lives under per-platform userdata (NextUI canonical — `minarch.c`
# uses `$USERDATA_PATH/<tag>-<name>/`). The tg5040 toolchain is shared between
# the Brick and Smart Pro variants, so those two need a suffix within the
# tg5040 platform dir. tg5050 has no variants.
USERDATA_DIR="$USERDATA_PATH/$EMU_TAG-mupen64plus"
case "$PLATFORM" in
    tg5040)
        if [ "$DEVICE" = "brick" ]; then
            DEVICE_CONFIG_DIR="$USERDATA_DIR/brick"
            DEVICE_RESOLUTION="1024x768"
            DEVICE_ANISOTROPY=0
        else
            DEVICE_CONFIG_DIR="$USERDATA_DIR/smart-pro"
            DEVICE_RESOLUTION="1280x720"
            DEVICE_ANISOTROPY=0
        fi
        ;;
    tg5050)
        DEVICE_CONFIG_DIR="$USERDATA_DIR"
        DEVICE_RESOLUTION="1280x720"
        # Anisotropic filtering: sharpens textures viewed at oblique angles.
        # Mali-G57 (tg5050) can handle level 2; PowerVR GE8300 (tg5040) cannot.
        DEVICE_ANISOTROPY=2
        ;;
esac

# Migrate from the legacy shared-userdata path if present. This moves the
# user's mupen64plus.cfg, .initialized marker, per-game/ overrides, and
# anything else into the new per-platform location. Kept for one release;
# can be removed afterwards.
LEGACY_USERDATA_DIR="$SHARED_USERDATA_PATH/N64-mupen64plus"
case "$PLATFORM" in
    tg5040)
        if [ "$DEVICE" = "brick" ]; then
            LEGACY_CONFIG_DIR="$LEGACY_USERDATA_DIR/config/tg5040-brick"
        else
            LEGACY_CONFIG_DIR="$LEGACY_USERDATA_DIR/config/tg5040-smart-pro"
        fi
        ;;
    tg5050)
        LEGACY_CONFIG_DIR="$LEGACY_USERDATA_DIR/config/tg5050"
        ;;
esac
MIGRATION_STAMP="$DEVICE_CONFIG_DIR/.migrated-from-shared"
if [ -d "$LEGACY_CONFIG_DIR" ] && [ ! -f "$MIGRATION_STAMP" ]; then
    mkdir -p "$DEVICE_CONFIG_DIR"
    # Preserve existing per-platform files; only move legacy items that don't
    # already exist in the new location so the migration is idempotent even
    # if a user has already hand-copied anything.
    for item in mupen64plus.cfg .initialized per-game; do
        if [ -e "$LEGACY_CONFIG_DIR/$item" ] && [ ! -e "$DEVICE_CONFIG_DIR/$item" ]; then
            mv "$LEGACY_CONFIG_DIR/$item" "$DEVICE_CONFIG_DIR/$item"
        fi
    done
    touch "$MIGRATION_STAMP"
fi
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

# Align save paths with NextUI conventions
BATTERY_SAVE_DIR="$SAVES_PATH/$EMU_TAG"
STATE_SAVE_DIR="$SHARED_USERDATA_PATH/$EMU_TAG-mupen64plus"
mkdir -p "$BATTERY_SAVE_DIR" "$STATE_SAVE_DIR"
sed -i "s|^SaveSRAMPath = .*|SaveSRAMPath = \"$BATTERY_SAVE_DIR/\"|" "$DEVICE_CFG"
sed -i "s|^SaveStatePath = .*|SaveStatePath = \"$STATE_SAVE_DIR/\"|" "$DEVICE_CFG"

# Migrate legacy battery saves from other N64 paks into our canonical
# $SAVES_PATH/N64/. Mupen64plus-core uses four separate files per game
# (.sra/.eep/.fla/.mpk); josegonzalez/minui-n64-pak lets the core fall back
# to $XDG_DATA_HOME/mupen64plus/save/ which resolves to
# $USERDATA_PATH/N64-mupen64plus/data/mupen64plus/save/. Older builds of
# our own pak may also have left files in $SHARED_USERDATA_PATH/N64-mupen64plus/.
# One-shot migration; stamp file prevents repeat runs. mv -n preserves any
# pre-existing saves in the target directory.
SRAM_STAMP="$DEVICE_CONFIG_DIR/.migrated-legacy-sram"
if [ ! -f "$SRAM_STAMP" ]; then
    for legacy_root in \
        "$USERDATA_PATH/N64-mupen64plus" \
        "$SHARED_USERDATA_PATH/N64-mupen64plus"; do
        if [ -d "$legacy_root" ]; then
            find "$legacy_root" -type f \
                \( -name '*.sra' -o -name '*.eep' -o -name '*.fla' \
                   -o -name '*.mpk' -o -name '*.srm' \) \
                ! -path "$BATTERY_SAVE_DIR/*" \
                -exec mv -n {} "$BATTERY_SAVE_DIR/" \; 2>/dev/null
        fi
    done
    touch "$SRAM_STAMP"
fi
# Screenshots go into the flat /mnt/SDCARD/Screenshots/ directory (NextUI
# canonical — `minarch.c:8385` writes `SDCARD_PATH "/Screenshots/%s.%s.png"`).
SCREENSHOT_DIR="/mnt/SDCARD/Screenshots"
mkdir -p "$SCREENSHOT_DIR"
# Migrate any screenshots left over from the legacy per-core subdirectory.
LEGACY_SCREENSHOT_DIR="/mnt/SDCARD/Screenshots/$EMU_TAG"
if [ -d "$LEGACY_SCREENSHOT_DIR" ]; then
    find "$LEGACY_SCREENSHOT_DIR" -maxdepth 1 -type f -exec mv -n {} "$SCREENSHOT_DIR/" \;
    rmdir "$LEGACY_SCREENSHOT_DIR" 2>/dev/null || true
fi
sed -i "s|^ScreenshotPath = .*|ScreenshotPath = \"$SCREENSHOT_DIR/\"|" "$DEVICE_CFG"

# ── Auto-resume: check if NextUI game switcher requested a state load ─────────
RESUME_SLOT=""
if [ -f /tmp/resume_slot.txt ]; then
    RESUME_SLOT=$(cat /tmp/resume_slot.txt)
    rm /tmp/resume_slot.txt
fi

# ── Environment ───────────────────────────────────────────────────────────────
export HOME="$USERDATA_PATH"
export LD_LIBRARY_PATH="$BIN_DIR:$SDCARD_PATH/.system/$PLATFORM/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export LD_PRELOAD="libEGL.so"
# Relative ROM path for auto_resume.txt (strip /mnt/SDCARD prefix)
export EMU_ROM_PATH="${ROM#/mnt/SDCARD}"
# Pass resume slot to emulator if game switcher requested it
[ -n "$RESUME_SLOT" ] && export EMU_RESUME_SLOT="$RESUME_SLOT"

# ── Overlay menu config ──────────────────────────────────────────────────────
export EMU_OVERLAY_JSON="$BIN_DIR/overlay_settings.json"
export EMU_OVERLAY_INI="$DEVICE_CONFIG_DIR/mupen64plus.cfg"
export EMU_OVERLAY_GAME="$(basename "$ROM" | sed 's/\.[^.]*$//')"
export EMU_DEFAULT_CFG="$BIN_DIR/default.cfg"

# ── Video plugin selection (reads [NextUI] VideoPlugin from mupen64plus.cfg) ─
VIDEO_PLUGIN_VALUE=$(awk -F' = ' '
    /^\[NextUI\]/ { in_section=1; next }
    /^\[/         { in_section=0 }
    in_section && $1 == "VideoPlugin" { gsub(/[[:space:]]+/, "", $2); print $2; exit }
' "$DEVICE_CFG" 2>/dev/null)
case "$VIDEO_PLUGIN_VALUE" in
    1)
        GFX_PLUGIN="mupen64plus-video-rice.so"
        export EMU_VIDEO_PLUGIN=rice
        ;;
    *)
        GFX_PLUGIN="mupen64plus-video-GLideN64.so"
        export EMU_VIDEO_PLUGIN=gliden64
        ;;
esac
# Font from NextUI system resources; pick font1.ttf or font2.ttf based on the
# user's `font=` setting in minuisettings.txt (matching NextUI's CFG_setFontId).
MINUI_SETTINGS="$SDCARD_PATH/.userdata/shared/minuisettings.txt"
FONT_ID=$(awk -F= '$1=="font"{print $2; exit}' "$MINUI_SETTINGS" 2>/dev/null)
case "$FONT_ID" in
    1) FONT_NAME="font1.ttf" ;;
    *) FONT_NAME="font2.ttf" ;;
esac
FONT_FILE="$SDCARD_PATH/.system/res/$FONT_NAME"
[ -f "$FONT_FILE" ] || FONT_FILE="$SDCARD_PATH/.system/res/font2.ttf"
[ -f "$FONT_FILE" ] || FONT_FILE="$SDCARD_PATH/.system/res/font1.ttf"
export EMU_OVERLAY_FONT="$FONT_FILE"
export EMU_OVERLAY_RES="$BIN_DIR"
# Screenshot directory (matches minarch's .minui path for game switcher)
MINUI_DIR="$SHARED_USERDATA_PATH/.minui/$EMU_TAG"
mkdir -p "$MINUI_DIR"
export EMU_OVERLAY_SCREENSHOT_DIR="$MINUI_DIR"
export EMU_OVERLAY_ROMFILE="$(basename "$ROM")"

# ── Per-game settings ────────────────────────────────────────────────────────
PER_GAME_DIR="$DEVICE_CONFIG_DIR/per-game"
mkdir -p "$PER_GAME_DIR"
PER_GAME_CFG="$PER_GAME_DIR/$(basename "$ROM").cfg"
export EMU_PER_GAME_CFG="$PER_GAME_CFG"

# If a per-game config exists, overlay its values onto mupen64plus.cfg for
# this run. Back up the console config first so it can be restored on exit
# and so the overlay can write Save for Console to the backup path.
if [ -f "$PER_GAME_CFG" ]; then
    cp "$DEVICE_CFG" "$DEVICE_CFG.console-backup"
    export EMU_CONSOLE_CFG="$DEVICE_CFG.console-backup"
    # Apply each "[section] key = value" line from the per-game file
    awk '
    NR == FNR {
        if (substr($0,1,1) == "[") {
            i = index($0, "]")
            if (i > 0) {
                sec = substr($0, 2, i - 2)
                rest = substr($0, i + 1)
                sub(/^ +/, "", rest)
                j = index(rest, " = ")
                if (j > 0) {
                    k = substr(rest, 1, j - 1)
                    v = substr(rest, j + 3)
                    ovr[sec, k] = v
                    okeys[sec, k] = 1
                }
            }
        }
        next
    }
    /^\[/ {
        gsub(/[\[\]]/, "")
        cur = $0
    }
    {
        if (cur != "" && index($0, " = ") > 0) {
            k = $0
            sub(/ = .*/, "", k)
            if (okeys[cur, k]) {
                print k " = " ovr[cur, k]
                delete okeys[cur, k]
                next
            }
        }
        print
    }
    ' "$PER_GAME_CFG" "$DEVICE_CFG" > "$DEVICE_CFG.tmp" && \
    mv "$DEVICE_CFG.tmp" "$DEVICE_CFG"
fi

# Brick-only d-pad vs joystick input mode. On devices with real analog
# sticks, leave $EMU_INPUT_MODE_FILE unset (plugin.c gates on $DEVICE).
if [ "$DEVICE" = "brick" ]; then
    export EMU_INPUT_MODE_FILE="$PER_GAME_DIR/$(basename "$ROM").input.cfg"
fi

# ── Archive extraction ───────────────────────────────────────────────────────
# If the ROM is a .zip or .7z, extract the inner N64 ROM to a tmpfs directory
# and hand that path to mupen64plus instead. We keep the *original* $ROM name
# (archive name minus its .zip/.7z) as the extracted file's basename so the
# core's save-filename logic (mupen64plus-ui-console.patch) derives the same
# save name it would for a raw .z64 — i.e. "Zelda.zip" saves to "Zelda.srm"
# just like "Zelda.z64" would. Magic-byte detection in rom.c makes the final
# extension irrelevant; we use .z64 as a placeholder for clarity.
#
# All metadata env vars exported above ($EMU_OVERLAY_GAME, $EMU_OVERLAY_ROMFILE,
# $EMU_INPUT_MODE_FILE, $EMU_ROM_PATH) intentionally still reference the
# original archive path so per-game settings, save states, and the overlay
# title all stay stable across runs.
case "$ROM" in
    *.zip|*.7z|*.ZIP|*.7Z)
        ROM_ARCHIVE="$ROM"
        ROM_EXTRACT_DIR=$(mktemp -d /tmp/m64p_extracted.XXXXXX)
        trap 'rm -rf "$ROM_EXTRACT_DIR"' EXIT INT TERM HUP QUIT
        if ! "$BIN_DIR/7zzs" e "$ROM_ARCHIVE" -o"$ROM_EXTRACT_DIR" -y >/dev/null; then
            echo "[launch] 7zzs failed to extract $ROM_ARCHIVE" >&2
            exit 1
        fi
        # Pick the first N64 ROM file; fall back to the largest regular file
        # if the archive didn't use a standard extension.
        ROM_INNER=""
        for f in "$ROM_EXTRACT_DIR"/*.z64 "$ROM_EXTRACT_DIR"/*.n64 \
                 "$ROM_EXTRACT_DIR"/*.v64 "$ROM_EXTRACT_DIR"/*.rom; do
            if [ -f "$f" ]; then
                ROM_INNER="$f"
                break
            fi
        done
        if [ -z "$ROM_INNER" ]; then
            for f in "$ROM_EXTRACT_DIR"/*; do
                if [ -f "$f" ]; then
                    ROM_INNER="$f"
                    break
                fi
            done
        fi
        if [ -z "$ROM_INNER" ]; then
            echo "[launch] no ROM file found inside $ROM_ARCHIVE" >&2
            exit 1
        fi
        # Rename so the basename matches the archive (sans .zip/.7z). This is
        # what mupen64plus-ui-console.patch reads for M64CMD_SET_ROM_FILENAME.
        ROM_BASENAME=$(basename "$ROM_ARCHIVE")
        ROM_STEM="${ROM_BASENAME%.*}"
        ROM_RENAMED="$ROM_EXTRACT_DIR/${ROM_STEM}.z64"
        if [ "$ROM_INNER" != "$ROM_RENAMED" ]; then
            mv "$ROM_INNER" "$ROM_RENAMED"
        fi
        ROM="$ROM_RENAMED"
        ;;
esac

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
    --gfx "$BIN_DIR/$GFX_PLUGIN" \
    --audio mupen64plus-audio-sdl.so \
    --input mupen64plus-input-sdl.so \
    --rsp mupen64plus-rsp-hle.so \
    "$ROM" > "$LOGS_PATH/$EMU_TAG.mupen64plus.txt" 2>&1 &
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

# Restore console config backup if per-game overrides were applied
if [ -f "$DEVICE_CFG.console-backup" ]; then
    mv "$DEVICE_CFG.console-backup" "$DEVICE_CFG"
fi

# Restore CPU online state, CPU governor/frequency, and GPU governor
case "$PLATFORM" in
    tg5040)
        [ -n "$ORIG_CPU3" ] && echo "$ORIG_CPU3" >/sys/devices/system/cpu/cpu3/online 2>/dev/null
        [ -n "$ORIG_CPU2" ] && echo "$ORIG_CPU2" >/sys/devices/system/cpu/cpu2/online 2>/dev/null
        [ -n "$ORIG_CPU1" ] && echo "$ORIG_CPU1" >/sys/devices/system/cpu/cpu1/online 2>/dev/null
        [ -n "$ORIG_CPU_GOV" ] && echo "$ORIG_CPU_GOV" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
        [ -n "$ORIG_CPU_MIN" ] && echo "$ORIG_CPU_MIN" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null
        [ -n "$ORIG_CPU_MAX" ] && echo "$ORIG_CPU_MAX" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null
        ;;
    tg5050)
        [ -n "$ORIG_GPU_GOV" ] && echo "$ORIG_GPU_GOV" >/sys/devices/platform/soc@3000000/1800000.gpu/devfreq/1800000.gpu/governor 2>/dev/null
        [ -n "$ORIG_CPU5" ] && echo "$ORIG_CPU5" >/sys/devices/system/cpu/cpu5/online 2>/dev/null
        [ -n "$ORIG_CPU_GOV" ] && echo "$ORIG_CPU_GOV" >/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor 2>/dev/null
        [ -n "$ORIG_CPU_MIN" ] && echo "$ORIG_CPU_MIN" >/sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 2>/dev/null
        [ -n "$ORIG_CPU_MAX" ] && echo "$ORIG_CPU_MAX" >/sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq 2>/dev/null
        ;;
esac

# Restore speaker, swap, VM settings
[ -n "$ORIG_SPEAKER_MUTE" ] && echo "$ORIG_SPEAKER_MUTE" >/sys/class/speaker/mute 2>/dev/null
swapoff "$SWAPFILE" 2>/dev/null
[ -n "$ORIG_VFS_CACHE" ] && echo "$ORIG_VFS_CACHE" >/proc/sys/vm/vfs_cache_pressure 2>/dev/null
