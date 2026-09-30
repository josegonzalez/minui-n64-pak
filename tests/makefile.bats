#!/usr/bin/env bats
#
# Build-wiring tests for the Makefile.
#
# These introspect the Makefile with `make print-<VAR>`, so they need neither a
# cross toolchain nor a cloned upstream tree and run on any host with make.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# print-<VAR>; sets $status/$output/$lines via bats `run`.
mk() { # <VAR>
    run make --no-print-directory -C "$REPO_ROOT" "print-$1"
    [ "$status" -eq 0 ]
}

# ── every shipped platform is fully wired ───────────────────────────────────

@test "every platform in pak.json has an image, CPU flags and a docker runner" {
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        upper="$(echo "$platform" | tr '[:lower:]' '[:upper:]')"

        mk "${upper}_IMAGE"
        [ "$output" != "${upper}_IMAGE=" ]

        mk "${upper}_CPUFLAGS"
        [[ "$output" == *"-mcpu=cortex-"* ]]

        mk "DOCKER_RUN_${upper}"
        [[ "$output" == *"docker run"* ]]
    done
}

@test "every platform in pak.json has build, stage and dist targets" {
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        for target in "$platform" "rice-$platform" "glide64mk2-$platform" "ini-$platform" \
                      "stage-$platform" "dist-$platform"; do
            run make --no-print-directory -C "$REPO_ROOT" -n "$target" --dry-run --question
            # `make -n` on an unknown target exits 2 with "No rule to make target"
            [ "$status" -ne 2 ]
        done
    done
}

@test "build and dist cover every platform in pak.json" {
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        run grep -q "MAKE) stage-$platform\$" "$REPO_ROOT/Makefile"
        [ "$status" -eq 0 ]
        run grep -q "MAKE) dist-$platform\$" "$REPO_ROOT/Makefile"
        [ "$status" -eq 0 ]
    done
}

# ── pinned upstream sources ─────────────────────────────────────────────────
#
# The emulator components track upstream master, so a branch name or tag would
# silently move the build. Each one is pinned to a full commit SHA instead.

# <dir under src/> <rev variable>
PINNED_SOURCES="
mupen64plus-core CORE_REV
mupen64plus-ui-console UI_REV
mupen64plus-audio-sdl AUDIO_REV
mupen64plus-input-sdl INPUT_REV
mupen64plus-rsp-hle RSP_REV
GLideN64 GLIDEN64_REV
mupen64plus-video-rice RICE_REV
mupen64plus-video-glide64mk2 GLIDE64MK2_REV
"

@test "every emulator component is pinned to a full commit SHA" {
    while read -r dir var; do
        [ -n "$dir" ] || continue
        mk "$var"
        [[ "$output" =~ ^${var}=[0-9a-f]{40}$ ]]
    done <<< "$PINNED_SOURCES"
}

@test "each component is shallow-fetched at its pinned commit" {
    while read -r dir var; do
        [ -n "$dir" ] || continue
        mk "$var"
        rev="${output#*=}"
        run make --no-print-directory -C "$REPO_ROOT" -n -B "$REPO_ROOT/src/$dir"
        [ "$status" -eq 0 ]
        [[ "$output" == *"git fetch --depth 1 origin $rev"* ]]
    done <<< "$PINNED_SOURCES"
}

# GLideNHQ ships an x86 libzstd.a. The build has to link an aarch64 one, built
# from the pinned zstd source that clone fetches.
@test "GLideNHQ links a zstd cross-built from the pinned source" {
    mk ZSTD_TAG
    tag="${output#*=}"
    [ -n "$tag" ]
    run make --no-print-directory -C "$REPO_ROOT" -n -B clone
    [ "$status" -eq 0 ]
    [[ "$output" == *"--branch $tag https://github.com/facebook/zstd $REPO_ROOT/src/zstd"* ]]
    run grep -q 'cp $(SRC)/zstd/lib/libzstd.a $(SRC)/GLideN64/src/GLideNHQ/lib/libzstd.a' "$REPO_ROOT/Makefile"
    [ "$status" -eq 0 ]
}

# ── patching ─────────────────────────────────────────────────────────────────

# A patch that no longer applies after an upstream bump has to stop the build
# there, not surface later as a compile error in a half-patched tree.
@test "make patch stops at the first patch that fails to apply" {
    run make --no-print-directory -C "$REPO_ROOT" -n -B "$REPO_ROOT/src/.patched"
    [ "$status" -eq 0 ]
    [[ "$output" == *"set -e;"* ]]
    # The stamp is written only after the last patch is applied.
    after_last_apply="${output##*git apply}"
    [[ "$after_last_apply" == *"touch $REPO_ROOT/src/.patched"* ]]
}

@test "every upstream patch is applied and regenerated" {
    for component in mupen64plus-core mupen64plus-ui-console mupen64plus-input-sdl \
                     mupen64plus-video-rice mupen64plus-video-glide64mk2; do
        [ -f "$REPO_ROOT/patches/shared/$component.patch" ]
        run grep -qF "cd \$(SRC)/$component && git apply \$(PATCHES)/$component.patch" "$REPO_ROOT/Makefile"
        [ "$status" -eq 0 ]
        run grep -qF "cd \$(SRC)/$component && git add -N . && git diff > \$(PATCHES)/$component.patch" "$REPO_ROOT/Makefile"
        [ "$status" -eq 0 ]
    done
}

# ── toolchain images ─────────────────────────────────────────────────────────

@test "the toolchains come from the LoveRetro registry" {
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        upper="$(echo "$platform" | tr '[:lower:]' '[:upper:]')"
        mk "${upper}_IMAGE"
        [ "$output" = "${upper}_IMAGE=ghcr.io/loveretro/${platform}-toolchain:latest" ]
    done
}

@test "h700 builds for the Cortex-A53 like tg5040, not the A55 platforms" {
    mk H700_CPUFLAGS
    [ "$output" = "H700_CPUFLAGS=-mcpu=cortex-a53 -mtune=cortex-a53" ]
    mk TG5040_CPUFLAGS
    [ "$output" = "TG5040_CPUFLAGS=-mcpu=cortex-a53 -mtune=cortex-a53" ]
    mk MY355_CPUFLAGS
    [ "$output" = "MY355_CPUFLAGS=-mcpu=cortex-a55 -mtune=cortex-a55" ]
}

# Passing OPTFLAGS overrides the upstream `-O3 -flto` default, so LTO has to be
# carried along with the CPU flags or it silently drops out.
@test "every platform keeps LTO alongside its CPU flags" {
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        upper="$(echo "$platform" | tr '[:lower:]' '[:upper:]')"
        mk "${upper}_CPUFLAGS"
        cpuflags="${output#*=}"

        mk "${upper}_OPTFLAGS"
        [ "$output" = "${upper}_OPTFLAGS=-O3 -flto $cpuflags" ]
    done
}

@test "no build target bypasses the per-platform OPTFLAGS" {
    run grep -n 'OPTFLAGS="-O3' "$REPO_ROOT/Makefile"
    [ "$status" -ne 0 ]
}

@test "shipped binaries are stripped" {
    run grep -q 'strip -s libmupen64plus.so.2 mupen64plus mupen64plus-\*.so' "$REPO_ROOT/Makefile"
    [ "$status" -eq 0 ]
    run grep -q 'strip -s plugin/Release/mupen64plus-video-GLideN64.so' "$REPO_ROOT/Makefile"
    [ "$status" -eq 0 ]
    # Each platform strips with its own toolchain.
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        upper="$(echo "$platform" | tr '[:lower:]' '[:upper:]')"
        run grep -q "STAGE_PLATFORM,$platform,\$(DOCKER_RUN_${upper}))" "$REPO_ROOT/Makefile"
        [ "$status" -eq 0 ]
    done
}

# ── the docker env helper is checked in, not generated ──────────────────────

@test "the docker runners invoke the checked-in env helper" {
    mk DOCKER_SCRIPT
    [ "$output" = "DOCKER_SCRIPT=/build/scripts/docker-env.sh" ]
    [ -x "$REPO_ROOT/scripts/docker-env.sh" ]

    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        upper="$(echo "$platform" | tr '[:lower:]' '[:upper:]')"
        mk "DOCKER_RUN_${upper}"
        [[ "$output" == *"/build/scripts/docker-env.sh"* ]]
    done
}

@test "the env helper prefers the toolchain's own SDL2 when it ships one" {
    run grep -q 'PREFIX_LOCAL:-/nonexistent}/lib/pkgconfig/sdl2.pc' "$REPO_ROOT/scripts/docker-env.sh"
    [ "$status" -eq 0 ]
    # That lookup must clear the sysroot prefix, or pkg-config rewrites the
    # absolute in-image paths in the toolchain's sdl2.pc.
    run grep -q 'PKG_CONFIG_SYSROOT_DIR= PKG_CONFIG_PATH="$PREFIX_LOCAL/lib/pkgconfig" pkg-config --cflags sdl2' "$REPO_ROOT/scripts/docker-env.sh"
    [ "$status" -eq 0 ]
}

# Run docker-env.sh outside a container with a stubbed pkg-config, so the SDL
# selection can be exercised on a host that has no cross toolchain and no SDL2.
run_docker_env() { # <UNION_PLATFORM> <PREFIX_LOCAL>
    stub_dir="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\necho "stub-pkg-config $*"\n' > "$stub_dir/pkg-config"
    chmod +x "$stub_dir/pkg-config"

    run env UNION_PLATFORM="$1" PREFIX_LOCAL="$2" PATH="$stub_dir:$PATH" \
        bash "$REPO_ROOT/scripts/docker-env.sh" true
}

# The h700 binaries have to link the patched SDL2 NextUI installs on the device.
# Falling back to the TrimUI SDK copy still builds, so the helper must refuse.
@test "the env helper refuses to build h700 against the sysroot SDL2" {
    run_docker_env h700 "$BATS_TEST_TMPDIR/absent"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing the patched SDL2"* ]]
}

@test "the env helper still falls back to the sysroot on the other platforms" {
    for platform in tg5040 tg5050 my355; do
        run_docker_env "$platform" "$BATS_TEST_TMPDIR/absent"
        [ "$status" -eq 0 ]
        [[ "$output" == *"SDL2 from sysroot"* ]]
    done
}

@test "the env helper takes the toolchain SDL2 when the pkgconfig file is there" {
    prefix_local="$BATS_TEST_TMPDIR/nextui"
    mkdir -p "$prefix_local/lib/pkgconfig"
    touch "$prefix_local/lib/pkgconfig/sdl2.pc"

    run_docker_env h700 "$prefix_local"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SDL2 from PREFIX_LOCAL"* ]]
}

# ── each platform bundles the libpng its binaries actually link ─────────────
#
# The toolchains disagree: the tg5040 and h700 sysroots carry libpng12, tg5050
# carries libpng16, and my355 links libpng statically. Bundling the wrong one is
# invisible at build time and only shows up as a missing library on the device,
# so pin each platform's choice here.

# bundles <platform> <soname> — the dist target installs this library.
bundles() {
    run grep -q "/build/dist/N64.pak/$1/$2\$" "$REPO_ROOT/Makefile"
    [ "$status" -eq 0 ]
}

# omits <platform> <pattern> — no library matching this is installed.
omits() {
    run grep -q "N64.pak/$1/$2" "$REPO_ROOT/Makefile"
    [ "$status" -ne 0 ]
}

@test "tg5040 bundles libpng12, which is what its sysroot links" {
    bundles tg5040 libpng12.so.0
    omits tg5040 libpng16
}

@test "tg5050 bundles libpng16, which is what its sysroot links" {
    bundles tg5050 libpng16.so.16
    omits tg5050 libpng12
}

@test "my355 bundles no libpng at all, it is linked statically" {
    omits my355 libpng
}

@test "h700 bundles libpng12, which is what its sysroot links" {
    bundles h700 libpng12.so.0
    omits h700 libpng16
}

# Each libpng has to come from the toolchain whose sysroot the binaries were
# linked against, or the bundled copy will not match what they reference.
@test "each platform takes its libpng from its own toolchain" {
    for platform in tg5040 h700; do
        upper="$(echo "$platform" | tr '[:lower:]' '[:upper:]')"
        run grep "N64.pak/$platform/libpng12.so.0\$" "$REPO_ROOT/Makefile"
        [ "$status" -eq 0 ]
        [[ "$output" == *"DOCKER_RUN_${upper}"* ]]
    done
}

# libpng16 is the only thing in the tree that needs ZLIB_1.2.9, so tg5050 is the
# one platform that genuinely depends on the newer zlib. Every platform still
# links libz.so.1 through libmupen64plus, so all of them ship it.
@test "every platform ships the libz its core links" {
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        bundles "$platform" libz.so.1
    done
}

# ── the pak ships the launcher and its profile helper ───────────────────────

@test "every dist target ships launch.sh and platform.sh at the pak root" {
    count_launch="$(grep -c 'cp $(CONFIG)/shared/launch.sh $(DIST)/launch.sh' "$REPO_ROOT/Makefile")"
    count_profile="$(grep -c 'cp $(CONFIG)/shared/platform.sh $(DIST)/platform.sh' "$REPO_ROOT/Makefile")"
    platforms="$(jq -r '.platforms | length' "$REPO_ROOT/pak.json")"
    [ "$count_launch" -eq "$platforms" ]
    [ "$count_profile" -eq "$platforms" ]
}

@test "every platform dir gets the per-device pad mappings" {
    run grep -q 'cp $(CONFIG)/shared/input/\*.cfg $(1)/input/' "$REPO_ROOT/Makefile"
    [ "$status" -eq 0 ]
    # DIST_COMMON runs for every platform, so one copy step covers them all.
    run grep -c 'DIST_COMMON,$(DIST)/' "$REPO_ROOT/Makefile"
    [ "$output" -eq "$(jq -r '.platforms | length' "$REPO_ROOT/pak.json")" ]
}

# ── Glide64mk2 ──────────────────────────────────────────────────────────────

@test "every platform stages and ships its own Glide64mk2 build" {
    run grep -qF 'cp $(SRC)/mupen64plus-video-glide64mk2/projects/unix/mupen64plus-video-glide64mk2.so $(BUILD)/$(1)/' "$REPO_ROOT/Makefile"
    [ "$status" -eq 0 ]
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        run grep -q "^stage-$platform: .*glide64mk2-$platform" "$REPO_ROOT/Makefile"
        [ "$status" -eq 0 ]
        run grep -qF "cp \$(BUILD)/$platform/mupen64plus-video-glide64mk2.so \$(DIST)/$platform/" "$REPO_ROOT/Makefile"
        [ "$status" -eq 0 ]
    done
}

# The plugin refuses to start without Glide64mk2.ini, and launch.sh merges the
# pak's [Video-Glide64mk2] defaults from video-glide64mk2.cfg.
@test "every platform dir gets the Glide64mk2 data and defaults" {
    run grep -qF 'cp $(SRC)/mupen64plus-video-glide64mk2/data/Glide64mk2.ini $(1)/' "$REPO_ROOT/Makefile"
    [ "$status" -eq 0 ]
    run grep -qF 'cp $(CONFIG)/shared/video-glide64mk2.cfg $(1)/' "$REPO_ROOT/Makefile"
    [ "$status" -eq 0 ]
    [ -f "$REPO_ROOT/config/shared/video-glide64mk2.cfg" ]
}

# Glide64mk2 links libpng like Rice, so it needs the same per-platform flags.
@test "Glide64mk2 builds with the same flags as Rice on every platform" {
    for platform in $(jq -r '.platforms[]' "$REPO_ROOT/pak.json"); do
        rice="$(make --no-print-directory -C "$REPO_ROOT" -n "rice-$platform" | grep 'make -j')"
        glide="$(make --no-print-directory -C "$REPO_ROOT" -n "glide64mk2-$platform" | grep 'make -j')"
        [ -n "$rice" ]
        [ "${glide//glide64mk2/rice}" = "$rice" ]
    done
}

@test "the pak metadata drives the artifact and install paths" {
    mk PAK_NAME
    [ "$output" = "PAK_NAME=N64" ]
    mk PAK_FOLDER
    [ "$output" = "PAK_FOLDER=Emus" ]
}
