#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/build"
SRC="${MLP1_SRC:-$ROOT_DIR/workdir/mlp1/src}"
BUILD_DIR="${MLP1_BUILD_DIR:-$ROOT_DIR/output/mlp1/build}"
JOBS="${BUILD_JOBS:-$(nproc)}"
BUILD_GLIDEN64="${MLP1_BUILD_GLIDEN64:-1}"

: "${CROSS_COMPILE:=aarch64-buildroot-linux-gnu-}"
: "${SYSROOT:?SYSROOT is required from the MLP1 toolchain image}"
: "${CC:=/opt/mlp1-toolchain/bin/${CROSS_COMPILE}gcc}"
: "${CXX:=/opt/mlp1-toolchain/bin/${CROSS_COMPILE}g++}"
: "${AR:=/opt/mlp1-toolchain/bin/${CROSS_COMPILE}ar}"
: "${STRIP:=/opt/mlp1-toolchain/bin/${CROSS_COMPILE}strip}"

export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-$SYSROOT}"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig}"
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-$PKG_CONFIG_LIBDIR}"
export SDL_CFLAGS="${SDL_CFLAGS:-$(pkg-config --cflags sdl2)}"
export SDL_LDLIBS="${SDL_LDLIBS:-$(pkg-config --libs sdl2)}"
export LIBDRM_CFLAGS="${LIBDRM_CFLAGS:-$(pkg-config --cflags libdrm) -DEMU_OVL_ENABLE_DRM_HUD}"
export LIBDRM_LDLIBS="${LIBDRM_LDLIBS:-$(pkg-config --libs libdrm)}"

MLP1_BUILD_PROFILE="${MLP1_BUILD_PROFILE:-perf}"
if [ -f /opt/mlp1-toolchain/umrk/mlp1-build-flags.env ]; then
    . /opt/mlp1-toolchain/umrk/mlp1-build-flags.env
else
    UMRK_MLP1_PROFILE_CFLAGS="-O3 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
fi
OPTFLAGS="${MLP1_OPTFLAGS:-$UMRK_MLP1_PROFILE_CFLAGS}"
OVERLAY_DIR="$SRC/../overlay"

core_flags=(
    "CROSS_COMPILE=$CROSS_COMPILE"
    "HOST_CPU=aarch64"
    "USE_GLES=1"
    "NEON=1"
    "PIE=1"
    "VULKAN=0"
    "PKG_CONFIG=pkg-config"
    "OPTFLAGS=$OPTFLAGS"
)

plugin_flags=(
    "CROSS_COMPILE=$CROSS_COMPILE"
    "HOST_CPU=aarch64"
    "PIE=1"
    "PKG_CONFIG=pkg-config"
    "APIDIR=$SRC/mupen64plus-core/src/api"
    "OPTFLAGS=$OPTFLAGS"
)

build_make() {
    local dir="$1"
    shift
    make -C "$dir" -j"$JOBS" all "$@"
}

rm -rf "$OVERLAY_DIR"
mkdir -p "$(dirname "$OVERLAY_DIR")"
cp -R "$ROOT_DIR/overlay" "$OVERLAY_DIR"

mkdir -p "$BUILD_DIR/bin" "$BUILD_DIR/lib" "$BUILD_DIR/defaults"
mkdir -p "$SRC/mupen64plus-video-rice/projects/unix/_obj/overlay/cjson"

build_make "$SRC/mupen64plus-core/projects/unix" "${core_flags[@]}"
build_make "$SRC/mupen64plus-ui-console/projects/unix" "${plugin_flags[@]}" COREDIR="./" PLUGINDIR="./"
build_make "$SRC/mupen64plus-audio-sdl/projects/unix" "${plugin_flags[@]}"
build_make "$SRC/mupen64plus-input-sdl/projects/unix" "${plugin_flags[@]}"
build_make "$SRC/mupen64plus-rsp-hle/projects/unix" "${plugin_flags[@]}"
build_make "$SRC/mupen64plus-video-rice/projects/unix" "${plugin_flags[@]}" USE_GLES=1 \
    OVERLAY_DIR="$OVERLAY_DIR" \
    LIBDRM_CFLAGS="$LIBDRM_CFLAGS" \
    LIBDRM_LDLIBS="$LIBDRM_LDLIBS" \
    CPPFLAGS="-I$ROOT_DIR/include -I$OVERLAY_DIR -I$OVERLAY_DIR/cjson"

make -C "$ROOT_DIR/tools/ini" clean all CROSS_COMPILE="$CROSS_COMPILE"

if [ "$BUILD_GLIDEN64" = "1" ]; then
    cat >"$SRC/GLideN64/src/toolchain-aarch64.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER $CC)
set(CMAKE_CXX_COMPILER $CXX)
set(CMAKE_SYSROOT $SYSROOT)
set(CMAKE_FIND_ROOT_PATH $SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_C_FLAGS "\${CMAKE_C_FLAGS} $OPTFLAGS")
set(CMAKE_CXX_FLAGS "\${CMAKE_CXX_FLAGS} $OPTFLAGS")
set(SDL_TTF_INCLUDE_DIRS $SYSROOT/usr/include/SDL2)
set(SDL_TTF_LIBRARIES $SYSROOT/usr/lib/libSDL2_ttf.so)
set(PNG_LIBRARY $SYSROOT/usr/lib/libpng16.so)
set(PNG_PNG_INCLUDE_DIR $SYSROOT/usr/include/libpng16)
set(ZLIB_LIBRARY $SYSROOT/usr/lib/libz.so)
set(ZLIB_INCLUDE_DIR $SYSROOT/usr/include)
set(FREETYPE_INCLUDE_DIRS $SYSROOT/usr/include/freetype2)
set(FREETYPE_LIBRARIES $SYSROOT/usr/lib/libfreetype.so)
set(LIBDRM_INCLUDE_DIRS $SYSROOT/usr/include $SYSROOT/usr/include/libdrm)
set(LIBDRM_LIBRARIES $SYSROOT/usr/lib/libdrm.so)
EOF
    cmake -S "$SRC/GLideN64/src" -B "$SRC/GLideN64/src/build-mlp1" \
        -DCMAKE_TOOLCHAIN_FILE="$SRC/GLideN64/src/toolchain-aarch64.cmake" \
        -DMUPENPLUSAPI=ON -DEGL=ON -DMESA=ON -DNEON_OPT=ON -DCRC_ARMV8=ON \
        -DUSE_SYSTEM_LIBS=ON
    cmake --build "$SRC/GLideN64/src/build-mlp1" --target mupen64plus-video-GLideN64 --parallel "$JOBS"
fi

copy_file() {
    local src="$1"
    local dst="$2"
    [ -f "$src" ] || { echo "missing build artifact: $src" >&2; exit 1; }
    cp -f "$src" "$dst"
}

copy_file "$SRC/mupen64plus-ui-console/projects/unix/mupen64plus" "$BUILD_DIR/bin/mupen64plus"
copy_file "$ROOT_DIR/tools/ini/build/ini" "$BUILD_DIR/bin/ini"
copy_file "$SRC/mupen64plus-core/projects/unix/libmupen64plus.so.2.0.0" "$BUILD_DIR/lib/libmupen64plus.so.2"
copy_file "$SRC/mupen64plus-audio-sdl/projects/unix/mupen64plus-audio-sdl.so" "$BUILD_DIR/lib/mupen64plus-audio-sdl.so"
copy_file "$SRC/mupen64plus-input-sdl/projects/unix/mupen64plus-input-sdl.so" "$BUILD_DIR/lib/mupen64plus-input-sdl.so"
copy_file "$SRC/mupen64plus-rsp-hle/projects/unix/mupen64plus-rsp-hle.so" "$BUILD_DIR/lib/mupen64plus-rsp-hle.so"
copy_file "$SRC/mupen64plus-video-rice/projects/unix/mupen64plus-video-rice.so" "$BUILD_DIR/lib/mupen64plus-video-rice.so"
copy_file "$SRC/GLideN64/src/build-mlp1/plugin/Release/mupen64plus-video-GLideN64.so" "$BUILD_DIR/lib/mupen64plus-video-GLideN64.so"
copy_file "$SRC/7zip/7zzs" "$BUILD_DIR/lib/7zzs"
copy_file "$SRC/7zip/License.txt" "$BUILD_DIR/lib/7zzs.LICENSE"

copy_runtime_lib() {
    local soname="$1"
    local path
    path=""
    for dir in "$SYSROOT/usr/lib" "$SYSROOT/lib"; do
        if [ -e "$dir/$soname" ]; then
            path="$dir/$soname"
            break
        fi
    done
    if [ -z "$path" ]; then
        path="$(find "$SYSROOT/usr/lib" "$SYSROOT/lib" -maxdepth 1 \( -type f -o -type l \) -name "$soname*" | sort | tail -n 1)"
    fi
    [ -n "$path" ] || { echo "missing runtime library in sysroot: $soname" >&2; exit 1; }
    cp -Lf "$path" "$BUILD_DIR/lib/$soname"
}

copy_runtime_lib libSDL2-2.0.so.0
copy_runtime_lib libSDL2_ttf-2.0.so.0
copy_runtime_lib libz.so.1
copy_runtime_lib libpng16.so.16
copy_runtime_lib libstdc++.so.6
copy_runtime_lib libgcc_s.so.1
copy_runtime_lib libfreetype.so.6
copy_runtime_lib libharfbuzz.so.0
copy_runtime_lib libdrm.so.2

cp -f "$ROOT_DIR/config/shared/default.cfg" "$BUILD_DIR/defaults/default.cfg"
cp -f "$ROOT_DIR/config/shared/overlay_settings.json" "$BUILD_DIR/defaults/overlay_settings.json"
copy_file "$SRC/mupen64plus-core/data/mupen64plus.ini" "$BUILD_DIR/defaults/mupen64plus.ini"
copy_file "$SRC/mupen64plus-input-sdl/data/InputAutoCfg.ini" "$BUILD_DIR/defaults/InputAutoCfg.ini"
# Full-auto controller sections map each pad by SDL name, and upstream has no
# entry for Jawaka's calibrated virtual Loong.
cat "$ROOT_DIR/config/shared/loong-autocfg.ini" >> "$BUILD_DIR/defaults/InputAutoCfg.ini"
copy_file "$SRC/mupen64plus-core/data/mupencheat.txt" "$BUILD_DIR/defaults/mupencheat.txt"
copy_file "$SRC/mupen64plus-video-rice/data/RiceVideoLinux.ini" "$BUILD_DIR/defaults/RiceVideoLinux.ini"

find "$BUILD_DIR/bin" "$BUILD_DIR/lib" -type f -exec chmod 755 {} +
"$STRIP" -s "$BUILD_DIR/bin/mupen64plus" "$BUILD_DIR/bin/ini" "$BUILD_DIR/lib/"*.so* 2>/dev/null || true

# Shared objects link with undefined symbols; catch them here instead of at
# dlopen() on the device. Runs after strip: it reads the dynamic symbol table.
CROSS_COMPILE="$CROSS_COMPILE" bash "$ROOT_DIR/scripts/verify-mlp1-symbols.sh" "$BUILD_DIR"

if [ -x /mlp1-toolchain/scripts/verify-binary.sh ]; then
    /mlp1-toolchain/scripts/verify-binary.sh "$BUILD_DIR/bin/mupen64plus" \
        >"$BUILD_DIR/mupen64plus.verify.txt"
fi
