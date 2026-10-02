#!/usr/bin/env bash
# Fail the MLP1 build when a binary or plugin we built references a dynamic
# symbol that nothing in its runtime scope defines.
#
# The plugins are shared objects, so the linker lets undefined symbols through
# and the first place they surface is dlopen() on the device ("undefined
# symbol: emu_i18n", exit 12). This script resolves each object the way the
# loader will: the object itself, its NEEDED closure (bundled libs first, then
# the sysroot), plus, for plugins, the frontend and the core library, which the
# frontend loads with RTLD_GLOBAL.
#
# Usage: verify-mlp1-symbols.sh <build dir>   (runs inside the toolchain image)
set -euo pipefail

BUILD_DIR="${1:?usage: $0 <build dir>}"
: "${SYSROOT:?SYSROOT is required from the MLP1 toolchain image}"
: "${CROSS_COMPILE:=aarch64-buildroot-linux-gnu-}"
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-/opt/mlp1-toolchain/bin}"
NM="${NM:-$TOOLCHAIN_BIN/${CROSS_COMPILE}nm}"
READELF="${READELF:-$TOOLCHAIN_BIN/${CROSS_COMPILE}readelf}"
[ -x "$NM" ] || NM="${CROSS_COMPILE}nm"
[ -x "$READELF" ] || READELF="${CROSS_COMPILE}readelf"

LIB_DIR="$BUILD_DIR/lib"
FRONTEND="$BUILD_DIR/bin/mupen64plus"
CORE="$LIB_DIR/libmupen64plus.so.2"
PLUGINS=("$LIB_DIR"/mupen64plus-*.so)
ALLOWLIST="${ALLOWLIST:-$(dirname "${BASH_SOURCE[0]}")/mlp1-symbol-allowlist.txt}"

cache="$(mktemp -d)"
trap 'rm -rf "$cache"' EXIT

# Symbols the device resolves but the sysroot cannot; see the file for why.
if [ -f "$ALLOWLIST" ]; then
    sed 's/#.*//' "$ALLOWLIST" | awk 'NF {print $1}' | LC_ALL=C sort -u >"$cache/allow"
else
    : >"$cache/allow"
fi

cache_key() { printf '%s' "$1" | shasum -a 256 | cut -c1-32; }

# Symbol names only; strip "@VERSION" / "@@VERSION" suffixes.
defined_syms() {
    local f="$1" key
    key="$cache/def.$(cache_key "$f")"
    if [ ! -f "$key" ]; then
        "$NM" -D --defined-only "$f" 2>/dev/null | awk 'NF >= 2 {print $NF}' | sed 's/@.*//' | LC_ALL=C sort -u >"$key"
    fi
    cat "$key"
}

# Strong undefined references only ("U"); weak ones ("w", "v") may stay unresolved.
undefined_syms() {
    "$NM" -D --undefined-only "$1" 2>/dev/null | awk '$1 == "U" {print $2}' | sed 's/@.*//' | LC_ALL=C sort -u
}

needed_libs() {
    "$READELF" -d "$1" 2>/dev/null | awk '/\(NEEDED\)/ {gsub(/[\[\]]/, "", $NF); print $NF}'
}

has_dynamic_section() {
    "$READELF" -d "$1" 2>/dev/null | grep -q 'Dynamic section'
}

resolve_lib() {
    local soname="$1" dir
    for dir in "$LIB_DIR" "$SYSROOT/usr/lib" "$SYSROOT/lib"; do
        if [ -e "$dir/$soname" ]; then
            printf '%s\n' "$dir/$soname"
            return 0
        fi
    done
    return 1
}

# Print the transitive NEEDED closure of the given objects, one path per line.
closure() {
    local queue=("$@") seen=" " obj soname path
    while [ ${#queue[@]} -gt 0 ]; do
        obj="${queue[0]}"; queue=("${queue[@]:1}")
        for soname in $(needed_libs "$obj"); do
            case "$seen" in *" $soname "*) continue ;; esac
            seen="$seen$soname "
            if ! path="$(resolve_lib "$soname")"; then
                echo "error: $(basename "$obj") needs $soname, which is neither bundled nor in the sysroot" >&2
                exit 1
            fi
            printf '%s\n' "$path"
            queue+=("$path")
        done
    done
}

# check <object> <scope objects...>: every strong undefined symbol in <object>
# must be defined by <object> itself or by something in its scope.
status=0
check() {
    local obj="$1"; shift
    local scope=("$obj" "$@") provided missing count
    if ! has_dynamic_section "$obj"; then
        echo "skip   $(basename "$obj") (static)"
        return 0
    fi
    while IFS= read -r path; do scope+=("$path"); done < <(closure "${scope[@]}")
    provided="$cache/scope.$(cache_key "$obj")"
    : >"$provided"
    for path in "${scope[@]}"; do defined_syms "$path" >>"$provided"; done
    LC_ALL=C sort -u -o "$provided" "$provided"
    undefined_syms "$obj" | LC_ALL=C comm -23 - "$provided" >"$cache/missing"
    allowed="$(LC_ALL=C comm -12 "$cache/missing" "$cache/allow")"
    missing="$(LC_ALL=C comm -23 "$cache/missing" "$cache/allow")"
    count="$(undefined_syms "$obj" | wc -l | tr -d ' ')"
    if [ -n "$missing" ]; then
        echo "FAIL   $(basename "$obj"): unresolved dynamic symbols:"
        printf '         %s\n' $missing
        status=1
    else
        echo "ok     $(basename "$obj") ($count imports resolved)"
    fi
    if [ -n "$allowed" ]; then
        echo "       allowlisted (device-only providers): $(printf '%s ' $allowed)"
    fi
}

for f in "$FRONTEND" "$CORE" "${PLUGINS[@]}"; do
    [ -f "$f" ] || { echo "error: missing build artifact: $f" >&2; exit 1; }
done

echo "Checking dynamic symbol resolution in $BUILD_DIR"
check "$FRONTEND"
check "$CORE" "$FRONTEND"
for plugin in "${PLUGINS[@]}"; do
    check "$plugin" "$FRONTEND" "$CORE"
done
check "$BUILD_DIR/bin/ini"

if [ "$status" -ne 0 ]; then
    echo "error: undefined dynamic symbols would fail at dlopen() on the device" >&2
    exit 1
fi
