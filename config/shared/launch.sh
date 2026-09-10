#!/bin/sh
PAK_DIR="$(dirname "$0")"
EMU_TAG="$(basename "$PAK_DIR")"
EMU_TAG="${EMU_TAG%.*}"
set -x

rm -f "$LOGS_PATH/$EMU_TAG.txt"
exec >>"$LOGS_PATH/$EMU_TAG.txt"
exec 2>&1

BIN_DIR="$PAK_DIR/$PLATFORM"
ROM="$1"
ROM_BASE="$(basename "$ROM")"

mkdir -p "$SAVES_PATH/$EMU_TAG"

# ── Platform / device profile ────────────────────────────────────────────────
# Every per-platform and per-device fact lives in platform.sh so it can be unit
# tested without a device; everything below reads the PROFILE_* variables it sets.
. "$PAK_DIR/platform.sh"
n64_platform_profile "$PLATFORM" "$DEVICE"

# Resolve the GPU devfreq governor node. Some platforms name that directory after
# the SoC's GPU node, so the profile is allowed to hand back a glob.
GPU_GOVERNOR=""
GPU_DEVFREQ_DIR=""
for candidate in $PROFILE_GPU_GOVERNOR_GLOB; do
    if [ -w "$candidate" ]; then
        GPU_GOVERNOR="$candidate"
        GPU_DEVFREQ_DIR="$(dirname "$candidate")"
        break
    fi
done

# ── Save original system settings (restored on exit) ─────────────────────────
ORIG_SPEAKER_MUTE=$(cat /sys/class/speaker/mute 2>/dev/null)
ORIG_VFS_CACHE=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)
# CPU online state is stored as "<cpu>:<0|1>" pairs so the restore below can put
# each core back exactly as it was found.
ORIG_CPU_ONLINE=""
for cpu in $PROFILE_ONLINE_CPUS; do
    ORIG_CPU_ONLINE="$ORIG_CPU_ONLINE $cpu:$(cat /sys/devices/system/cpu/cpu$cpu/online 2>/dev/null)"
done
ORIG_CPU_GOV=$(cat "$PROFILE_CPUFREQ_PATH/scaling_governor" 2>/dev/null)
ORIG_CPU_MIN=$(cat "$PROFILE_CPUFREQ_PATH/scaling_min_freq" 2>/dev/null)
ORIG_CPU_MAX=$(cat "$PROFILE_CPUFREQ_PATH/scaling_max_freq" 2>/dev/null)
ORIG_GPU_GOV=""
ORIG_GPU_MIN=""
if [ -n "$GPU_GOVERNOR" ]; then
    ORIG_GPU_GOV=$(cat "$GPU_GOVERNOR" 2>/dev/null)
    ORIG_GPU_MIN=$(cat "$GPU_DEVFREQ_DIR/min_freq" 2>/dev/null)
fi

# ── CPU / GPU setup (from the platform profile) ──────────────────────────────
# CPU governor and frequency may be changed at runtime by the emulator (overlay
# menu CPU Mode). Original values are saved above and restored on exit.
for cpu in $PROFILE_ONLINE_CPUS; do
    echo 1 >/sys/devices/system/cpu/cpu$cpu/online 2>/dev/null
done
# GPU: lock to performance for GLideN64 rendering. Where the devfreq node has no
# performance governor, pin its floor to the top available frequency instead.
if [ -n "$GPU_GOVERNOR" ]; then
    if ! echo performance >"$GPU_GOVERNOR" 2>/dev/null; then
        GPU_TOP_FREQ=$(tr ' ' '\n' <"$GPU_DEVFREQ_DIR/available_frequencies" 2>/dev/null | grep -v '^$' | sort -n | tail -1)
        [ -n "$GPU_TOP_FREQ" ] && echo "$GPU_TOP_FREQ" >"$GPU_DEVFREQ_DIR/min_freq" 2>/dev/null
    fi
fi

# ── Memory management: swap + VM tuning for hi-res texture loading ────────────
# Platforms with no writable non-FAT partition report an empty swapfile path and
# skip swap entirely.
if [ -n "$PROFILE_SWAPFILE" ]; then
    if [ ! -f "$PROFILE_SWAPFILE" ]; then
        dd if=/dev/zero of="$PROFILE_SWAPFILE" bs=1M count=512 2>/dev/null
        mkswap "$PROFILE_SWAPFILE" 2>/dev/null
    fi
    swapon "$PROFILE_SWAPFILE" 2>/dev/null
fi
echo 200 >/proc/sys/vm/vfs_cache_pressure 2>/dev/null
sync
echo 3 >/proc/sys/vm/drop_caches 2>/dev/null

# ── User data and device-specific config ─────────────────────────────────────
# Config lives under per-platform userdata (NextUI canonical — `minarch.c`
# uses `$USERDATA_PATH/<tag>-<name>/`). Platforms whose toolchain covers several
# devices need a per-device suffix within the platform dir; the profile supplies
# it. tg5050 and my355 have no variants.
USERDATA_DIR="$USERDATA_PATH/$EMU_TAG-mupen64plus"
# Migrate from the legacy shared-userdata path if present. This moves the
# user's mupen64plus.cfg, .initialized marker, per-game/ overrides, and
# anything else into the new per-platform location. Kept for one release;
# can be removed afterwards.
LEGACY_USERDATA_DIR="$SHARED_USERDATA_PATH/N64-mupen64plus"
# Platforms whose toolchain covers several devices (tg5040, h700) get a per-device
# subdirectory; single-variant platforms use the userdata dir as-is.
DEVICE_CONFIG_DIR="$USERDATA_DIR${PROFILE_CONFIG_SUBDIR:+/$PROFILE_CONFIG_SUBDIR}"
DEVICE_RESOLUTION="$PROFILE_RESOLUTION"
# Anisotropic filtering: sharpens textures viewed at oblique angles. Weaker GPUs
# get 0; platform.sh carries the per-device reasoning.
DEVICE_ANISOTROPY="$PROFILE_ANISOTROPY"
LEGACY_CONFIG_DIR="$LEGACY_USERDATA_DIR/config/$PROFILE_LEGACY_SUBDIR"
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

# Platform-specific values are applied via --set flags on the mupen64plus
# command line instead of patching the config file, so user edits persist.
DEVICE_CFG="$DEVICE_CONFIG_DIR/mupen64plus.cfg"
SCREEN_W="${DEVICE_RESOLUTION%x*}"
SCREEN_H="${DEVICE_RESOLUTION#*x}"

# Read the user's console-level anisotropy from the config file so we can
# detect whether they customised it away from the device default.
CONSOLE_ANISOTROPY=$("$BIN_DIR/ini" get "$DEVICE_CFG" "Video-GLideN64" "anisotropy" 2>/dev/null)

# Align save paths with NextUI conventions
BATTERY_SAVE_DIR="$SAVES_PATH/$EMU_TAG"
STATE_SAVE_DIR="$SHARED_USERDATA_PATH/$EMU_TAG-mupen64plus"
mkdir -p "$BATTERY_SAVE_DIR" "$STATE_SAVE_DIR"
# SaveSRAMPath and SaveStatePath are set via --set flags on the mupen64plus
# command line instead of sed-patching mupen64plus.cfg.

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
# ScreenshotPath is set via --sshotdir on the mupen64plus command line.

# ── Auto-resume: check if NextUI game switcher requested a state load ─────────
RESUME_SLOT=""
if [ -f /tmp/resume_slot.txt ]; then
    RESUME_SLOT=$(cat /tmp/resume_slot.txt)
    rm /tmp/resume_slot.txt
fi

# ── Environment ───────────────────────────────────────────────────────────────
export HOME="$USERDATA_PATH"
export XDG_DATA_HOME="$DEVICE_CONFIG_DIR"
# LD_LIBRARY_PATH and LD_PRELOAD are scoped to the mupen64plus invocation
# below to avoid affecting sleepmon.elf, syncsettings.elf, and taskset.
M64P_LD_LIBRARY_PATH="$BIN_DIR:$SDCARD_PATH/.system/$PLATFORM/lib"
for dir in $PROFILE_LD_EXTRA_DIRS; do
    M64P_LD_LIBRARY_PATH="$M64P_LD_LIBRARY_PATH:$dir"
done
M64P_LD_LIBRARY_PATH="$M64P_LD_LIBRARY_PATH:$LD_LIBRARY_PATH"
M64P_LD_PRELOAD="$PROFILE_LD_PRELOAD"
# Relative ROM path for auto_resume.txt (strip /mnt/SDCARD prefix)
export EMU_ROM_PATH="${ROM#/mnt/SDCARD}"
# Pass resume slot to emulator if game switcher requested it
[ -n "$RESUME_SLOT" ] && export EMU_RESUME_SLOT="$RESUME_SLOT"

# ── Overlay menu config ──────────────────────────────────────────────────────
export EMU_OVERLAY_JSON="$BIN_DIR/overlay_settings.json"
export EMU_OVERLAY_INI="$DEVICE_CONFIG_DIR/mupen64plus.cfg"
export EMU_OVERLAY_GAME="${ROM_BASE%.*}"
export EMU_DEFAULT_CFG="$BIN_DIR/default.cfg"

# ── Video plugin selection (reads [NextUI] VideoPlugin from mupen64plus.cfg) ─
VIDEO_PLUGIN_VALUE=$("$BIN_DIR/ini" get "$DEVICE_CFG" "NextUI" "VideoPlugin" 2>/dev/null)
case "$VIDEO_PLUGIN_VALUE" in
    0)
        GFX_PLUGIN="mupen64plus-video-GLideN64.so"
        export EMU_VIDEO_PLUGIN=gliden64
        ;;
    *)
        GFX_PLUGIN="mupen64plus-video-rice.so"
        export EMU_VIDEO_PLUGIN=rice
        ;;
esac
# Font: try NextUI's font1/font2.ttf (selected via minuisettings.txt font=),
# then fall back to MinUI's BPreplayBold-unhinted.otf, then any .ttf/.otf in
# the res directory. This keeps the overlay functional on both NextUI and MinUI.
RES_DIR="$SDCARD_PATH/.system/res"
MINUI_SETTINGS="$SDCARD_PATH/.userdata/shared/minuisettings.txt"
FONT_ID=$("$BIN_DIR/ini" get "$MINUI_SETTINGS" "" "font" 2>/dev/null)
case "$FONT_ID" in
    1) FONT_CANDIDATES="font1.ttf font2.ttf" ;;
    *) FONT_CANDIDATES="font2.ttf font1.ttf" ;;
esac
FONT_FILE=""
for name in $FONT_CANDIDATES BPreplayBold-unhinted.otf; do
    if [ -f "$RES_DIR/$name" ]; then
        FONT_FILE="$RES_DIR/$name"
        break
    fi
done
if [ -z "$FONT_FILE" ]; then
    # Last resort: pick the first .ttf or .otf in the res directory
    for f in "$RES_DIR"/*.ttf "$RES_DIR"/*.otf; do
        if [ -f "$f" ]; then
            FONT_FILE="$f"
            break
        fi
    done
fi
export EMU_OVERLAY_FONT="$FONT_FILE"
# Screenshot directory (matches minarch's .minui path for game switcher)
MINUI_DIR="$SHARED_USERDATA_PATH/.minui/$EMU_TAG"
mkdir -p "$MINUI_DIR"
export EMU_OVERLAY_SCREENSHOT_DIR="$MINUI_DIR"
export EMU_OVERLAY_ROMFILE="$ROM_BASE"

# ── Per-game settings ────────────────────────────────────────────────────────
PER_GAME_DIR="$DEVICE_CONFIG_DIR/per-game"
mkdir -p "$PER_GAME_DIR"
PER_GAME_CFG="$PER_GAME_DIR/$ROM_BASE.cfg"
export EMU_PER_GAME_CFG="$PER_GAME_CFG"

# If a per-game config exists, overlay its values onto mupen64plus.cfg for
# this run. Back up the console config first so it can be restored on exit
# and so the overlay can write Save for Console to the backup path.
if [ -f "$PER_GAME_CFG" ]; then
    cp "$DEVICE_CFG" "$DEVICE_CFG.console-backup"
    export EMU_CONSOLE_CFG="$DEVICE_CFG.console-backup"
    "$BIN_DIR/ini" merge "$DEVICE_CFG" "$PER_GAME_CFG"
fi

# Determine anisotropy for --set: per-game override > user console setting > device default
ANISO_SET=""
if [ -f "$PER_GAME_CFG" ]; then
    PER_GAME_ANISO=$("$BIN_DIR/ini" get "$PER_GAME_CFG" "Video-GLideN64" "anisotropy" 2>/dev/null)
fi
if [ -n "$PER_GAME_ANISO" ]; then
    # Per-game override takes highest priority
    ANISO_SET="--set Video-GLideN64[anisotropy]=$PER_GAME_ANISO"
elif [ "$CONSOLE_ANISOTROPY" != "$DEVICE_ANISOTROPY" ]; then
    # User customised console anisotropy — don't override, let config file value win
    ANISO_SET=""
else
    # No customisation — apply device-appropriate default
    ANISO_SET="--set Video-GLideN64[anisotropy]=$DEVICE_ANISOTROPY"
fi

# D-pad↔joystick input mode is handled by trimui_inputd via flag files
# in /tmp/trimui_inputd/. emu_frontend applies the per-game mode at init
# time and toggles on user action. Flag files are cleaned up on exit.

# Runtime button remap file for immediate application in input-sdl
export EMU_BUTTON_MAP_FILE="$PER_GAME_DIR/$ROM_BASE.buttons"

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
        ROM_STEM="${ROM_BASE%.*}"
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
env LD_LIBRARY_PATH="$M64P_LD_LIBRARY_PATH" LD_PRELOAD="$M64P_LD_PRELOAD" \
    ./mupen64plus --fullscreen --resolution "$DEVICE_RESOLUTION" \
    --configdir "$DEVICE_CONFIG_DIR" \
    --datadir "$BIN_DIR" \
    --plugindir "$BIN_DIR" \
    --sshotdir "$SCREENSHOT_DIR" \
    --cachedir "$DEVICE_CONFIG_DIR/cache" \
    --set "Video-General[ScreenWidth]=$SCREEN_W" \
    --set "Video-General[ScreenHeight]=$SCREEN_H" \
    --set "Core[SaveSRAMPath]=$BATTERY_SAVE_DIR/" \
    --set "Core[SaveStatePath]=$STATE_SAVE_DIR/" \
    $ANISO_SET \
    --gfx "$BIN_DIR/$GFX_PLUGIN" \
    --audio mupen64plus-audio-sdl.so \
    --input mupen64plus-input-sdl.so \
    --rsp mupen64plus-rsp-hle.so \
    "$ROM" > "$LOGS_PATH/$EMU_TAG.mupen64plus.txt" 2>&1 &
EMU_PID=$!
sleep 4

# ── Thread pinning (CPU topology from the platform profile) ──────────────────
MAIN_MASK="$PROFILE_MAIN_MASK"
HELPER_MASK="$PROFILE_HELPER_MASK"
VIDEO_MASK="$PROFILE_VIDEO_MASK"

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

# Clean up trimui_inputd flag files so we don't leak d-pad remap state
rm -f /tmp/trimui_inputd/input_dpad_to_joystick
rm -f /tmp/trimui_inputd/input_no_dpad

# Restore CPU online state, CPU governor/frequency, and GPU governor
if [ -n "$GPU_GOVERNOR" ]; then
    [ -n "$ORIG_GPU_GOV" ] && echo "$ORIG_GPU_GOV" >"$GPU_GOVERNOR" 2>/dev/null
    [ -n "$ORIG_GPU_MIN" ] && echo "$ORIG_GPU_MIN" >"$GPU_DEVFREQ_DIR/min_freq" 2>/dev/null
fi
# Walk the cores back in reverse so the highest-numbered one goes offline first.
REVERSED_CPU_ONLINE=""
for pair in $ORIG_CPU_ONLINE; do
    REVERSED_CPU_ONLINE="$pair $REVERSED_CPU_ONLINE"
done
for pair in $REVERSED_CPU_ONLINE; do
    cpu="${pair%%:*}"
    cpu_state="${pair#*:}"
    [ -n "$cpu_state" ] && echo "$cpu_state" >/sys/devices/system/cpu/cpu$cpu/online 2>/dev/null
done
[ -n "$ORIG_CPU_GOV" ] && echo "$ORIG_CPU_GOV" >"$PROFILE_CPUFREQ_PATH/scaling_governor" 2>/dev/null
[ -n "$ORIG_CPU_MIN" ] && echo "$ORIG_CPU_MIN" >"$PROFILE_CPUFREQ_PATH/scaling_min_freq" 2>/dev/null
[ -n "$ORIG_CPU_MAX" ] && echo "$ORIG_CPU_MAX" >"$PROFILE_CPUFREQ_PATH/scaling_max_freq" 2>/dev/null

# Restore speaker, swap, VM settings
[ -n "$ORIG_SPEAKER_MUTE" ] && echo "$ORIG_SPEAKER_MUTE" >/sys/class/speaker/mute 2>/dev/null
[ -n "$PROFILE_SWAPFILE" ] && swapoff "$PROFILE_SWAPFILE" 2>/dev/null
[ -n "$ORIG_VFS_CACHE" ] && echo "$ORIG_VFS_CACHE" >/proc/sys/vm/vfs_cache_pressure 2>/dev/null
