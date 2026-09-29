#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${MLP1_BUILD_DIR:-$ROOT_DIR/output/mlp1/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/mlp1/mupen64plus}"
SOURCE_REF="$(git -C "$ROOT_DIR" rev-parse --short=40 HEAD 2>/dev/null || printf unknown)"
MLP1_BUILD_PROFILE="${MLP1_BUILD_PROFILE:-perf}"
if [ -f "$ROOT_DIR/../mlp1-toolchain/flags/mlp1-build-flags.env" ]; then
    . "$ROOT_DIR/../mlp1-toolchain/flags/mlp1-build-flags.env"
else
    UMRK_MLP1_TARGET_SOC="rk3566"
    UMRK_MLP1_TARGET_CPU="cortex-a55"
    UMRK_MLP1_PROFILE_CFLAGS="-O3 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
    UMRK_MLP1_PROFILE_LDFLAGS="-Wl,--gc-sections"
fi

need_file() {
    local path="$1"
    [ -f "$path" ] || { echo "missing required build artifact: $path" >&2; exit 1; }
}

need_file "$BUILD_DIR/bin/mupen64plus"
need_file "$BUILD_DIR/bin/ini"
need_file "$BUILD_DIR/lib/libmupen64plus.so.2"
need_file "$BUILD_DIR/lib/mupen64plus-audio-sdl.so"
need_file "$BUILD_DIR/lib/mupen64plus-input-sdl.so"
need_file "$BUILD_DIR/lib/mupen64plus-rsp-hle.so"
need_file "$BUILD_DIR/lib/mupen64plus-video-rice.so"
need_file "$BUILD_DIR/lib/mupen64plus-video-GLideN64.so"
need_file "$BUILD_DIR/lib/7zzs"
need_file "$BUILD_DIR/defaults/default.cfg"
need_file "$BUILD_DIR/defaults/overlay_settings.json"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/defaults" "$OUTPUT_DIR/defaults/language"

cp -f "$BUILD_DIR/bin/mupen64plus" "$OUTPUT_DIR/bin/mupen64plus"
cp -f "$BUILD_DIR/bin/ini" "$OUTPUT_DIR/bin/ini"
cp -f "$BUILD_DIR/lib/"* "$OUTPUT_DIR/lib/"
cp -f "$BUILD_DIR/defaults/"* "$OUTPUT_DIR/defaults/"
cp -f "$ROOT_DIR/language/"*.txt "$OUTPUT_DIR/defaults/language/"
cp -f "$ROOT_DIR/config/mlp1/launch.sh" "$OUTPUT_DIR/launch.sh"
cp -f "$ROOT_DIR/LICENSE" "$OUTPUT_DIR/LICENSE.txt"
chmod 755 "$OUTPUT_DIR/launch.sh" "$OUTPUT_DIR/bin/"* "$OUTPUT_DIR/lib/"*.so* "$OUTPUT_DIR/lib/7zzs"
chmod 644 "$OUTPUT_DIR/lib/"*.LICENSE

video_plugins='"rice", "gliden64"'

cat >"$OUTPUT_DIR/manifest.json" <<EOF
{
  "id": "mupen64plus_standalone",
  "name": "Mupen64Plus Standalone",
  "platform": "mlp1",
  "kind": "standalone-emulator",
  "source_repo": "josegonzalez/minui-n64-pak",
  "source_ref": "$SOURCE_REF",
  "upstream_ref": "c3a90408ec93f44b3a5b47e828c3fc69f95c091e",
  "toolchain": "UMRK mlp1-toolchain",
  "target_soc": "$UMRK_MLP1_TARGET_SOC",
  "target_cpu": "$UMRK_MLP1_TARGET_CPU",
  "build_profile": "$MLP1_BUILD_PROFILE",
  "cflags": "$UMRK_MLP1_PROFILE_CFLAGS",
  "ldflags": "$UMRK_MLP1_PROFILE_LDFLAGS",
  "entrypoint": "launch.sh",
  "binary": "bin/mupen64plus",
  "menu": "embedded-mupen64plus-overlay",
  "default_video_plugin": "rice",
  "video_plugins": [$video_plugins],
  "bundled_libraries": [
    "libSDL2-2.0.so.0",
    "libSDL2_ttf-2.0.so.0",
    "libfreetype.so.6",
    "libgcc_s.so.1",
    "libharfbuzz.so.0",
    "libpng16.so.16",
    "libstdc++.so.6",
    "libz.so.1"
  ],
  "exceptions": [
    {
      "artifact": "lib/7zzs",
      "reason": "sha256-verified upstream prebuilt AArch64 7-Zip binary"
    }
  ]
}
EOF

cat >"$OUTPUT_DIR/README.txt" <<'EOF'
Mupen64Plus standalone payload for Leaf on Miniloong Pocket 1.

Launch through Jawaka with a .z64, .n64, .v64, .zip, or .7z N64 ROM under
Roms/N64. The wrapper sources Leaf's launcher/env.sh, stores durable config
under USERDATA_PATH/mupen64plus, battery saves under Saves/N64, and states
under States/Mupen64Plus Standalone.

Rice is the default video plugin for the first MLP1 performance pass. GLideN64
is built and bundled for users who prefer the higher-accuracy renderer.
EOF

find "$OUTPUT_DIR" -maxdepth 3 -type f | sort
