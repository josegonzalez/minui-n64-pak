#!/bin/sh
set -eu
# LOG-SAFE-1. The session log lives on a FAT card and can go unwritable (a bad
# cluster chain, a full card, or the FAT32 4 GiB per-file ceiling). stdout and
# stderr here are inherited from the launcher and point at that file. Under
# set -e a failed echo would abort this script and the game would never start,
# so probe both once and fall back to /dev/null, then never let a log write
# decide whether a game launches.
leaf_log_probe() {
    # A real byte, not a zero-length write: a 0-byte write can succeed without
    # touching the device and would not detect EIO/EFBIG. The subshell ignores
    # SIGXFSZ: past a file-size rlimit the kernel raises it, and its default
    # action would kill this shell before the write could fail with EFBIG.
    ( trap '' XFSZ; printf '\n' ) 2>/dev/null
}
leaf_log_probe >/dev/null 2>&1 || true
if ! leaf_log_probe; then
    exec >/dev/null
fi
if ! leaf_log_probe >&2; then
    exec 2>/dev/null
fi

log() { ( trap '' XFSZ; printf '%s\n' "$*" ) 2>/dev/null || true; }

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [ -f "$SELF_DIR/../../launcher/env.sh" ]; then
    . "$SELF_DIR/../../launcher/env.sh"
elif [ -n "${UMRK_ENV_FILE:-}" ] && [ -f "$UMRK_ENV_FILE" ]; then
    . "$UMRK_ENV_FILE"
fi

if [ "$#" -lt 1 ]; then
    log "usage: launch.sh <rom-path>"
    exit 64
fi

if [ "${MUPEN64PLUS_DEBUG:-0}" = "1" ]; then
    set -x
fi

PLATFORM="${PLATFORM:-mlp1}"
SDCARD_PATH="${SDCARD_PATH:-/mnt/sdcard}"
UMRK_PLATFORM_PATH="${UMRK_PLATFORM_PATH:-${SYSTEM_PATH:-$SDCARD_PATH/.system/leaf/platforms/$PLATFORM}}"
USERDATA_PATH="${USERDATA_PATH:-$SDCARD_PATH/.userdata/$PLATFORM}"
SHARED_USERDATA_PATH="${SHARED_USERDATA_PATH:-$SDCARD_PATH/.userdata/shared}"
SAVES_PATH="${SAVES_PATH:-$SDCARD_PATH/Saves}"
STATES_PATH="${STATES_PATH:-$SDCARD_PATH/States}"
LOGS_PATH="${LOGS_PATH:-$USERDATA_PATH/logs}"
ROMS_PATH="${ROMS_PATH:-$SDCARD_PATH/Roms}"

BIN_DIR="$SELF_DIR/bin"
LIB_DIR="$SELF_DIR/lib"
DEFAULTS_DIR="$SELF_DIR/defaults"
INI="$BIN_DIR/ini"
ROM="$1"
ORIGINAL_ROM="$ROM"
ROM_BASE="$(basename "$ROM")"
ROM_STEM="${ROM_BASE%.*}"

STATE_ROOT="${MUPEN64PLUS_STATE_ROOT:-$USERDATA_PATH/mupen64plus}"
CONFIG_DIR="$STATE_ROOT/config"
CACHE_DIR="$STATE_ROOT/cache"
PER_GAME_DIR="$STATE_ROOT/per-game"
BATTERY_SAVE_DIR="$SAVES_PATH/N64"
STATE_SAVE_DIR="$STATES_PATH/Mupen64Plus Standalone"
SCREENSHOT_DIR="${SCREENSHOTS_PATH:-$STATE_ROOT/screenshots}"

mkdir -p \
    "$CONFIG_DIR" \
    "$CACHE_DIR" \
    "$PER_GAME_DIR" \
    "$BATTERY_SAVE_DIR" \
    "$STATE_SAVE_DIR" \
    "$SCREENSHOT_DIR" \
    "$LOGS_PATH"

# LOG-SAFE-1. The mupen64plus log lives on the same FAT card as the session
# log, so this redirect gets the same treatment: prove the file can take a real
# byte, then either log there or log nowhere, but never fail the launch on it.
if leaf_log_probe >>"$LOGS_PATH/mupen64plus.log"; then
    exec >>"$LOGS_PATH/mupen64plus.log"
    exec 2>&1
else
    exec >/dev/null 2>&1
fi

PAUSED_JAWAKA_PIDS=""

pause_foreground_jawaka_for_direct_launch() {
    [ "${MUPEN64PLUS_PAUSE_FOREGROUND_JAWAKA:-1}" != "0" ] || return 0
    [ -z "${JAWAKA_GAME_SYSTEM:-}" ] || return 0

    pids="$(pgrep -x jawaka-launcher 2>/dev/null || true)"
    [ -n "$pids" ] || return 0

    for pid in $pids; do
        if kill -STOP "$pid" 2>/dev/null; then
            PAUSED_JAWAKA_PIDS="${PAUSED_JAWAKA_PIDS:+$PAUSED_JAWAKA_PIDS }$pid"
        fi
    done

    if [ -n "$PAUSED_JAWAKA_PIDS" ]; then
        log "[mupen64plus] paused jawaka-launcher for direct launch: $PAUSED_JAWAKA_PIDS"
    fi
}

resume_paused_jawaka() {
    [ -n "$PAUSED_JAWAKA_PIDS" ] || return 0
    for pid in $PAUSED_JAWAKA_PIDS; do
        kill -CONT "$pid" 2>/dev/null || true
    done
    log "[mupen64plus] resumed jawaka-launcher after direct launch: $PAUSED_JAWAKA_PIDS"
    PAUSED_JAWAKA_PIDS=""
}

cleanup() {
    if [ -n "${ROM_EXTRACT_DIR:-}" ] && [ -d "$ROM_EXTRACT_DIR" ]; then
        rm -rf "$ROM_EXTRACT_DIR"
    fi
    if [ -n "${DEVICE_CFG_BACKUP:-}" ] && [ -f "$DEVICE_CFG_BACKUP" ]; then
        mv "$DEVICE_CFG_BACKUP" "$DEVICE_CFG"
    fi
    resume_paused_jawaka
}
trap cleanup EXIT INT TERM HUP QUIT

pause_foreground_jawaka_for_direct_launch

DEVICE_CFG="$CONFIG_DIR/mupen64plus.cfg"
if [ ! -f "$DEVICE_CFG" ]; then
    cp "$DEFAULTS_DIR/default.cfg" "$DEVICE_CFG"
fi

INPUT_PROFILE_VERSION="mlp1-loong-sdl-calibrated-20260628"
INPUT_PROFILE_STAMP="$CONFIG_DIR/.input-profile-$INPUT_PROFILE_VERSION"
if [ "$PLATFORM" = "mlp1" ] && [ ! -f "$INPUT_PROFILE_STAMP" ]; then
    INPUT_PROFILE_CFG="$CONFIG_DIR/mlp1-input-profile.ini"
    cat >"$INPUT_PROFILE_CFG" <<'EOF'
[Input-SDL-Control1]
mode = 0
device = 0
name = "Loong Gamepad"
DPad R = "hat(0 Right)"
DPad L = "hat(0 Left)"
DPad D = "hat(0 Down)"
DPad U = "hat(0 Up)"
Start = "button(9)"
Z Trig = "button(6)"
B Button = "button(0)"
A Button = "button(1)"
C Button R = ""
C Button L = ""
C Button D = ""
C Button U = ""
R Trig = "button(5)"
L Trig = "button(4)"
X Axis = "axis(0-,0+)"
Y Axis = "axis(1-,1+)"
AnalogDeadzone = "4096,4096"
AnalogPeak = "32767,32767"
Select = "button(8)"
Hotkey = "button(10)"
EOF
    if "$INI" merge "$DEVICE_CFG" "$INPUT_PROFILE_CFG"; then
        : >"$INPUT_PROFILE_STAMP"
    fi
fi

# The expansion slot moved from the Controller Pak to the Rumble Pak when Leaf
# gained haptics, and a config written before then still says Mem pak. Only a
# config that predates the change is touched, and only once: after this the
# Options menu owns the setting, so anyone who switches back stays switched.
EXPANSION_PAK_VERSION="mlp1-rumble-pak-20260726"
EXPANSION_PAK_STAMP="$CONFIG_DIR/.expansion-pak-$EXPANSION_PAK_VERSION"
if [ ! -f "$EXPANSION_PAK_STAMP" ]; then
    EXPANSION_PAK_CFG="$CONFIG_DIR/mlp1-expansion-pak.ini"
    cat >"$EXPANSION_PAK_CFG" <<'EOF'
[Input-SDL-Control1]
plugin = 5
EOF
    if "$INI" merge "$DEVICE_CFG" "$EXPANSION_PAK_CFG"; then
        : >"$EXPANSION_PAK_STAMP"
    fi
    rm -f "$EXPANSION_PAK_CFG"
fi

PER_GAME_CFG="$PER_GAME_DIR/$ROM_BASE.cfg"
if [ -f "$PER_GAME_CFG" ]; then
    DEVICE_CFG_BACKUP="$DEVICE_CFG.console-backup"
    cp "$DEVICE_CFG" "$DEVICE_CFG_BACKUP"
    export EMU_CONSOLE_CFG="$DEVICE_CFG_BACKUP"
    "$INI" merge "$DEVICE_CFG" "$PER_GAME_CFG" || true
fi

# Jawaka freezes a controller roster for each launch and publishes it in
# SDL_JOYSTICK_DEVICE in player order, backed by a private /dev/input holding
# exactly those devices, so SDL joystick N is roster slot N.
#
# The shipped sections bound port 1 manually to SDL device 0 with the built-in
# pad's mapping. That is only correct when nothing is paired: connect a
# wireless controller and device 0 becomes the wireless pad, which then plays
# port 1 through the Loong's button layout. Full-auto sections let the input
# plugin map each pad from InputAutoCfg.ini by its SDL name instead -- that is
# what the packaged Loong profile is for.
CONTROLLER_MODE_VERSION="mlp1-roster-autoconfig-20260813"
CONTROLLER_MODE_STAMP="$CONFIG_DIR/.controller-mode-$CONTROLLER_MODE_VERSION"
if [ ! -f "$CONTROLLER_MODE_STAMP" ]; then
    CONTROLLER_MODE_CFG="$CONFIG_DIR/mlp1-controller-mode.ini"
    : >"$CONTROLLER_MODE_CFG"
    for port in 1 2 3 4; do
        # Only move a section still sitting on the shipped fully-manual value.
        # A port someone has already reconfigured keeps whatever they chose.
        current_mode="$("$INI" get "$DEVICE_CFG" "Input-SDL-Control$port" "mode" 2>/dev/null || true)"
        case "$current_mode" in
            0|0.0|0.000000)
                printf '[Input-SDL-Control%s]\nmode = 2\n' "$port" \
                    >>"$CONTROLLER_MODE_CFG"
                ;;
        esac
    done
    if [ -s "$CONTROLLER_MODE_CFG" ]; then
        "$INI" merge "$DEVICE_CFG" "$CONTROLLER_MODE_CFG" || true
    fi
    rm -f "$CONTROLLER_MODE_CFG"
    : >"$CONTROLLER_MODE_STAMP"
fi

# How many N64 ports are occupied describes what is plugged in right now, not a
# preference, so it is rewritten every launch rather than migrated once. Ports
# past the roster are emptied so an absent player cannot acquire one.
roster_count=""
if [ -n "${SDL_JOYSTICK_DEVICE:-}" ]; then
    roster_count="$(printf '%s' "$SDL_JOYSTICK_DEVICE" | awk -F: '{ print NF }')"
elif [ -n "${JAWAKA_INPUT_ROSTER_COUNT:-}" ]; then
    roster_count="$JAWAKA_INPUT_ROSTER_COUNT"
fi
case "$roster_count" in
    ''|*[!0-9]*) roster_count="" ;;
esac
if [ -n "$roster_count" ] && [ "$roster_count" -ge 1 ]; then
    if [ "$roster_count" -gt 4 ]; then
        roster_count=4
    fi
    ROSTER_PORTS_CFG="$CONFIG_DIR/mlp1-roster-ports.ini"
    : >"$ROSTER_PORTS_CFG"
    for port in 1 2 3 4; do
        if [ "$port" -le "$roster_count" ]; then
            printf '[Input-SDL-Control%s]\nplugged = True\n' "$port" \
                >>"$ROSTER_PORTS_CFG"
        else
            printf '[Input-SDL-Control%s]\nplugged = False\ndevice = -1\n' "$port" \
                >>"$ROSTER_PORTS_CFG"
        fi
    done
    "$INI" merge "$DEVICE_CFG" "$ROSTER_PORTS_CFG" || true
    rm -f "$ROSTER_PORTS_CFG"
    log "[mupen64plus] launch roster: $roster_count controller(s) plugged"
fi

resolve_font() {
    if [ -n "${CAT_FONT_PATH:-}" ]; then
        case "$CAT_FONT_PATH" in
            /*)
                if [ -f "$CAT_FONT_PATH" ]; then
                    printf '%s\n' "$CAT_FONT_PATH" 2>/dev/null || true
                    return 0
                fi
                ;;
            *)
                if [ -n "${CAT_FONTS_DIR:-}" ] && [ -f "$CAT_FONTS_DIR/$CAT_FONT_PATH" ]; then
                    printf '%s\n' "$CAT_FONTS_DIR/$CAT_FONT_PATH" 2>/dev/null || true
                    return 0
                fi
                ;;
        esac
    fi
    for candidate in \
        "${UMRK_LAUNCHER_PATH:-$UMRK_PLATFORM_PATH/launcher}/res/font.ttf" \
        "${UMRK_LAUNCHER_PATH:-$UMRK_PLATFORM_PATH/launcher}/res/fonts/SpaceGrotesk/SpaceGrotesk-Regular.ttf"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate" 2>/dev/null || true
            return 0
        fi
    done
    return 1
}

FONT_FILE="$(resolve_font || true)"

case "$ROM" in
    *.zip|*.ZIP|*.7z|*.7Z)
        ROM_EXTRACT_DIR="$(mktemp -d /tmp/m64p_extracted.XXXXXX)"
        "$LIB_DIR/7zzs" e "$ROM" -o"$ROM_EXTRACT_DIR" -y >/dev/null
        ROM_INNER=""
        for f in "$ROM_EXTRACT_DIR"/*.z64 "$ROM_EXTRACT_DIR"/*.n64 "$ROM_EXTRACT_DIR"/*.v64 "$ROM_EXTRACT_DIR"/*.rom; do
            if [ -f "$f" ]; then
                ROM_INNER="$f"
                break
            fi
        done
        if [ -z "$ROM_INNER" ]; then
            ROM_INNER="$(find "$ROM_EXTRACT_DIR" -maxdepth 1 -type f -print | sort | head -n 1)"
        fi
        if [ -z "$ROM_INNER" ] || [ ! -f "$ROM_INNER" ]; then
            log "[mupen64plus] no ROM file found inside archive: $ORIGINAL_ROM"
            exit 1
        fi
        ROM_RENAMED="$ROM_EXTRACT_DIR/$ROM_STEM.z64"
        if [ "$ROM_INNER" != "$ROM_RENAMED" ]; then
            mv "$ROM_INNER" "$ROM_RENAMED"
        fi
        ROM="$ROM_RENAMED"
        ;;
esac

VIDEO_PLUGIN_VALUE="$("$INI" get "$DEVICE_CFG" "Leaf" "VideoPlugin" 2>/dev/null || true)"
if [ -z "$VIDEO_PLUGIN_VALUE" ]; then
    VIDEO_PLUGIN_VALUE="$("$INI" get "$DEVICE_CFG" "NextUI" "VideoPlugin" 2>/dev/null || true)"
fi
case "$VIDEO_PLUGIN_VALUE" in
    0|gliden64|GLideN64)
        if [ -f "$LIB_DIR/mupen64plus-video-GLideN64.so" ]; then
            GFX_PLUGIN="mupen64plus-video-GLideN64.so"
            export EMU_VIDEO_PLUGIN=gliden64
        else
            GFX_PLUGIN="mupen64plus-video-rice.so"
            export EMU_VIDEO_PLUGIN=rice
        fi
        ;;
    *)
        GFX_PLUGIN="mupen64plus-video-rice.so"
        export EMU_VIDEO_PLUGIN=rice
        ;;
esac

export HOME="$STATE_ROOT/home"
export XDG_CONFIG_HOME="$CONFIG_DIR"
export XDG_DATA_HOME="$STATE_ROOT/data"
export XDG_CACHE_HOME="$CACHE_DIR"
export LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export SDL_VIDEODRIVER="${MUPEN64PLUS_SDL_VIDEODRIVER:-kmsdrm}"
export SDL_KMSDRM_REQUIRE_DRM_MASTER="${SDL_KMSDRM_REQUIRE_DRM_MASTER:-0}"

resolve_mlp1_virtual_gamepad() {
    awk '
        /^I:/ {
            name = 0
            virtual = 0
            event = ""
        }
        /^N: Name="Loong Gamepad"/ {
            name = 1
        }
        /^S: Sysfs=\/devices\/virtual\/input\// {
            virtual = 1
        }
        /^H: Handlers=/ {
            # "H: Handlers=event6 dmcfreq" glues the first handler to the key,
            # so the field is "Handlers=event6" and a bare /^event[0-9]+$/ test
            # silently misses any device whose event node happens to come
            # first. Strip the key before matching.
            for (i = 1; i <= NF; i++) {
                handler = $i
                sub(/^Handlers=/, "", handler)
                if (handler ~ /^event[0-9]+$/) {
                    event = handler
                }
            }
        }
        name && virtual && event != "" {
            print "/dev/input/" event
            exit
        }
    ' /proc/bus/input/devices 2>/dev/null
}

if [ "$PLATFORM" = "mlp1" ] && [ -z "${SDL_JOYSTICK_DEVICE:-}" ]; then
    if [ -n "${JAWAKA_RETROARCH_VIRTUAL_EVENT:-}" ] &&
       [ -e "$JAWAKA_RETROARCH_VIRTUAL_EVENT" ]; then
        MLP1_VIRTUAL_GAMEPAD="$JAWAKA_RETROARCH_VIRTUAL_EVENT"
    else
        MLP1_VIRTUAL_GAMEPAD="$(resolve_mlp1_virtual_gamepad || true)"
    fi

    if [ -n "$MLP1_VIRTUAL_GAMEPAD" ] && [ -e "$MLP1_VIRTUAL_GAMEPAD" ]; then
        export SDL_JOYSTICK_DEVICE="$MLP1_VIRTUAL_GAMEPAD"
        log "[mupen64plus] using calibrated Jawaka virtual gamepad: $SDL_JOYSTICK_DEVICE"
    else
        log "[mupen64plus] calibrated Jawaka virtual gamepad not found; using SDL default joystick scan"
    fi
fi

export DISPLAY_ROTATION="${MUPEN64PLUS_DISPLAY_ROTATION:-${DISPLAY_ROTATION:-270}}"
if [ "$EMU_VIDEO_PLUGIN" = "gliden64" ]; then
    export DISPLAY_ROTATION="${MUPEN64PLUS_DISPLAY_ROTATION:-0}"
    export MUPEN64PLUS_GLIDEN64_FINAL_ROTATION="${MUPEN64PLUS_GLIDEN64_FINAL_ROTATION:-90}"
    export MUPEN64PLUS_OVERLAY_ROTATION="${MUPEN64PLUS_OVERLAY_ROTATION:-270}"
fi
export MUPEN64PLUS_C_BUTTON_MOD="${MUPEN64PLUS_C_BUTTON_MOD:-1}"
export MUPEN64PLUS_C_BUTTON_MOD_BUTTON="${MUPEN64PLUS_C_BUTTON_MOD_BUTTON:-7}"
export MUPEN64PLUS_C_BUTTON_A_BUTTON="${MUPEN64PLUS_C_BUTTON_A_BUTTON:-1}"
export MUPEN64PLUS_C_BUTTON_B_BUTTON="${MUPEN64PLUS_C_BUTTON_B_BUTTON:-0}"
export MUPEN64PLUS_C_BUTTON_X_BUTTON="${MUPEN64PLUS_C_BUTTON_X_BUTTON:-2}"
export MUPEN64PLUS_C_BUTTON_Y_BUTTON="${MUPEN64PLUS_C_BUTTON_Y_BUTTON:-3}"
export EMU_OVERLAY_JOYSTICK_INDEX="${EMU_OVERLAY_JOYSTICK_INDEX:-0}"

# Every EMU_*_BUTTON index below describes the built-in pad's raw button
# layout. The overlay watches roster slot 0, which is the built-in pad only
# while nothing is paired -- with a wireless controller connected that slot is
# the wireless pad, whose buttons sit at different indices. Forcing the
# built-in numbers there binds the menu to whichever button happens to share
# the index: on an Xbox pad index 10 is View, which is exactly what opened the
# menu while Guide did nothing. Leave them unset for a wireless slot 0 so the
# overlay resolves that pad's own Guide and Back from SDL's controller
# database. An index the caller set explicitly still wins either way.
overlay_pad_is_builtin=1
if [ -n "${SDL_JOYSTICK_DEVICE:-}" ]; then
    overlay_first_pad="${SDL_JOYSTICK_DEVICE%%:*}"
    overlay_virtual_pad="${JAWAKA_INPUT_VIRTUAL_EVENT:-${JAWAKA_RETROARCH_VIRTUAL_EVENT:-}}"
    if [ -n "$overlay_virtual_pad" ] &&
       [ "$overlay_first_pad" != "$overlay_virtual_pad" ]; then
        overlay_pad_is_builtin=0
        log "[mupen64plus] overlay pad: $overlay_first_pad (wireless); resolving its own buttons"
    fi
fi
if [ "$overlay_pad_is_builtin" = "1" ]; then
    export EMU_MENU_BUTTON="${EMU_MENU_BUTTON:-10}"
    export EMU_SELECT_BUTTON="${EMU_SELECT_BUTTON:-8}"
    export EMU_START_BUTTON="${EMU_START_BUTTON:-9}"
    export EMU_L1_BUTTON="${EMU_L1_BUTTON:-4}"
    export EMU_R1_BUTTON="${EMU_R1_BUTTON:-5}"
fi
export EMU_L2_BUTTON="${EMU_L2_BUTTON:-6}"
export EMU_R2_BUTTON="${EMU_R2_BUTTON:-7}"
export EMU_L2_AXIS="${EMU_L2_AXIS:--1}"
export EMU_R2_AXIS="${EMU_R2_AXIS:--1}"
export EMU_ROM_PATH="$ORIGINAL_ROM"
export EMU_OVERLAY_JSON="$DEFAULTS_DIR/overlay_settings.json"
export EMU_OVERLAY_INI="$DEVICE_CFG"
export EMU_OVERLAY_GAME="$ROM_STEM"
export EMU_OVERLAY_CONSOLE="${EMU_OVERLAY_CONSOLE:-Nintendo 64}"
export EMU_DEFAULT_CFG="$DEFAULTS_DIR/default.cfg"
export EMU_LANGUAGE_DIR="$DEFAULTS_DIR/language"
export EMU_LANGUAGE="${EMU_LANGUAGE:-${UMRK_LANGUAGE:-${JAWAKA_LANGUAGE:-en}}}"
export EMU_OVERLAY_FONT="$FONT_FILE"
export EMU_OVERLAY_SCREENSHOT_DIR="$STATE_SAVE_DIR"
export EMU_OVERLAY_ROMFILE="$ROM_BASE"
export EMU_OVERLAY_STATE_DIR="$STATE_SAVE_DIR"
export EMU_OVERLAY_STATE_STEM="$ROM_STEM"
export EMU_DISABLE_NEXTUI_MARKERS="${EMU_DISABLE_NEXTUI_MARKERS:-1}"
export EMU_PER_GAME_CFG="$PER_GAME_CFG"
export EMU_BUTTON_MAP_FILE="$PER_GAME_DIR/$ROM_BASE.buttons"
rm -f "$EMU_BUTTON_MAP_FILE"

mkdir -p "$HOME" "$XDG_DATA_HOME"

RESOLUTION="${MUPEN64PLUS_RESOLUTION:-${CAT_WINDOW_WIDTH:-960}x${CAT_WINDOW_HEIGHT:-720}}"
SCREEN_W="${RESOLUTION%x*}"
SCREEN_H="${RESOLUTION#*x}"

cd "$SELF_DIR"
set +e
"$BIN_DIR/mupen64plus" \
    --fullscreen \
    --resolution "$RESOLUTION" \
    --configdir "$CONFIG_DIR" \
    --datadir "$DEFAULTS_DIR" \
    --plugindir "$LIB_DIR" \
    --sshotdir "$SCREENSHOT_DIR" \
    --cachedir "$CACHE_DIR" \
    --set "Video-General[ScreenWidth]=$SCREEN_W" \
    --set "Video-General[ScreenHeight]=$SCREEN_H" \
    --set "Core[SaveSRAMPath]=$BATTERY_SAVE_DIR/" \
    --set "Core[SaveStatePath]=$STATE_SAVE_DIR/" \
    --set "Video-GLideN64[txPath]=$ROMS_PATH/N64/.hires_texture" \
    --set "Video-GLideN64[txCachePath]=$CACHE_DIR/gliden64-texture-cache" \
    --set "Video-GLideN64[fontName]=$FONT_FILE" \
    --set "Video-GLideN64[ShowFPS]=False" \
    --set "Video-GLideN64[ShowVIS]=False" \
    --set "Video-GLideN64[ShowPercent]=False" \
    --set "Video-Rice[ShowFPS]=False" \
    --gfx "$LIB_DIR/$GFX_PLUGIN" \
    --audio "$LIB_DIR/mupen64plus-audio-sdl.so" \
    --input "$LIB_DIR/mupen64plus-input-sdl.so" \
    --rsp "$LIB_DIR/mupen64plus-rsp-hle.so" \
    "$ROM"
rc=$?
set -e
exit "$rc"
