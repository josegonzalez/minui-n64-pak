#!/usr/bin/env bats
#
# The overlay menu definition in config/shared/overlay_settings.json and the
# defaults it shares with config/shared/default.cfg.
#
# A cycle item's default is what the menu shows before anything is saved, so it
# has to be one of the values the item can cycle through. String-valued cycles
# (such as RESAMPLE) are the exception: emu_overlay_cfg.c stores them as indices,
# so their default is an index into values.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    JSON="$REPO_ROOT/config/shared/overlay_settings.json"
    CFG="$REPO_ROOT/config/shared/default.cfg"
    INI="$REPO_ROOT/tools/ini/build/ini"
    [ -x "$INI" ] || make -C "$REPO_ROOT/tools/ini" build-native >/dev/null
}

# item <plugin> <key> <field> — one field of an overlay item, as JSON.
item() {
    run python3 - "$JSON" "$1" "$2" "$3" <<'EOF'
import json, sys
path, plugin, key, field = sys.argv[1:]
cfg = json.load(open(path))
for sec in cfg["sections"]:
    for it in sec["items"]:
        if it["key"] == key and it.get("plugin") == plugin:
            print(json.dumps(it.get(field)))
            sys.exit(0)
sys.exit(1)
EOF
    [ "$status" -eq 0 ]
}

@test "every cycle item has a label per value and a valid default" {
    run python3 - "$JSON" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
bad = []
for sec in cfg["sections"]:
    for it in sec["items"]:
        if it.get("type") != "cycle":
            continue
        name = f'{sec["name"]}/{it["key"]}/{it.get("plugin", "any")}'
        values, labels, default = it["values"], it["labels"], it["default"]
        if len(values) != len(labels):
            bad.append(f"{name}: {len(values)} values, {len(labels)} labels")
        if isinstance(values[0], str):
            if not 0 <= default < len(values):
                bad.append(f"{name}: default index {default} out of range")
        elif default not in values:
            bad.append(f"{name}: default {default} not in {values}")
for line in bad:
    print(line)
sys.exit(1 if bad else 0)
EOF
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "GLideN64 resolution factor offers screen, native and multiples" {
    item gliden64 UseNativeResolutionFactor values
    [ "$output" = "[0, 1, 2, 3, 4]" ]
    item gliden64 UseNativeResolutionFactor labels
    [ "$output" = '["Screen", "1x", "2x", "3x", "4x"]' ]
    item gliden64 UseNativeResolutionFactor restart_required
    [ "$output" = "true" ]
}

@test "Rice resolution factor offers screen, native and multiples" {
    item rice ResolutionFactor values
    [ "$output" = "[0, 1, 2, 3, 4]" ]
    item rice ResolutionFactor labels
    [ "$output" = '["Screen", "1x", "2x", "3x", "4x"]' ]
    item rice ResolutionFactor ini_section
    [ "$output" = '"Video-Rice"' ]
    item rice ResolutionFactor restart_required
    [ "$output" = "true" ]
}

@test "GLideN64 resolution factor default matches default.cfg" {
    item gliden64 UseNativeResolutionFactor default
    [ "$output" = "2" ]
    run "$INI" get "$CFG" "Video-GLideN64" "UseNativeResolutionFactor"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "Rice resolution factor defaults to screen resolution in default.cfg" {
    item rice ResolutionFactor default
    [ "$output" = "0" ]
    run "$INI" get "$CFG" "Video-Rice" "ResolutionFactor"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# GLideN64 reads AsyncShaderCompilation once, when it sets up the combiner, so
# a change only takes effect after a restart.
@test "GLideN64 async shaders is an off-by-default toggle that needs a restart" {
    item gliden64 AsyncShaderCompilation type
    [ "$output" = '"bool"' ]
    item gliden64 AsyncShaderCompilation default
    [ "$output" = "false" ]
    item gliden64 AsyncShaderCompilation restart_required
    [ "$output" = "true" ]
    run "$INI" get "$CFG" "Video-GLideN64" "AsyncShaderCompilation"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]
}

@test "the video plugin menu offers GLideN64, Rice and Glide64mk2" {
    run python3 - "$JSON" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
for sec in cfg["sections"]:
    for it in sec["items"]:
        if it["key"] == "VideoPlugin":
            print(json.dumps([it["values"], it["labels"], it["ini_section"]]))
EOF
    [ "$status" -eq 0 ]
    [ "$output" = '[[0, 1, 2], ["GLideN64", "Rice", "Glide64mk2"], "NextUI"]' ]
}

# The plugin reads its settings once at startup, so every item needs a restart,
# and each has to land in the plugin's own INI section.
@test "every Glide64mk2 item targets its section and needs a restart" {
    run python3 - "$JSON" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
items = [it for sec in cfg["sections"] for it in sec["items"]
         if it.get("plugin") == "glide64mk2"]
bad = [it["key"] for it in items
       if it.get("ini_section") != "Video-Glide64mk2" or it.get("restart_required") is not True]
print(len(items), bad)
sys.exit(1 if bad or not items else 0)
EOF
    echo "$output"
    [ "$status" -eq 0 ]
}

# The aspect shortcut syncs the menu through the item keyed "aspect".
@test "Glide64mk2 aspect ratio defaults to 4:3 in the menu and default.cfg" {
    item glide64mk2 aspect values
    [ "$output" = "[-1, 0, 1, 2, 3]" ]
    item glide64mk2 aspect default
    [ "$output" = "0" ]
    run "$INI" get "$CFG" "Video-Glide64mk2" "aspect"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# Upstream turns anisotropic filtering on, which the PowerVR GE8300 cannot handle.
@test "Glide64mk2 anisotropic filtering is off by default" {
    item glide64mk2 wrpAnisotropic default
    [ "$output" = "false" ]
    run "$INI" get "$CFG" "Video-Glide64mk2" "wrpAnisotropic"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]
}

# launch.sh merges video-glide64mk2.cfg into configs seeded before Glide64mk2
# shipped, so it has to carry exactly what default.cfg seeds new installs with.
@test "the Glide64mk2 defaults fragment matches default.cfg" {
    FRAGMENT="$REPO_ROOT/config/shared/video-glide64mk2.cfg"
    run python3 - "$FRAGMENT" "$CFG" <<'EOF'
import sys

def section(path, name):
    out, cur = {}, None
    for line in open(path):
        line = line.strip()
        if line.startswith("["):
            cur = line[1:line.index("]")]
        elif cur == name and line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip()
    return out

fragment = section(sys.argv[1], "Video-Glide64mk2")
default = section(sys.argv[2], "Video-Glide64mk2")
print(fragment)
print(default)
sys.exit(0 if fragment and fragment == default else 1)
EOF
    echo "$output"
    [ "$status" -eq 0 ]
    # The fragment carries nothing but that section.
    run grep -c '^\[' "$FRAGMENT"
    [ "$output" = "1" ]
}

@test "overlay defaults agree with default.cfg" {
    run python3 "$REPO_ROOT/scripts/check-defaults.py" --include-all-sections
    echo "$output"
    [ "$status" -eq 0 ]
}
