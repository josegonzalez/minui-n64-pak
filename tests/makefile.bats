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
        for target in "$platform" "rice-$platform" "ini-$platform" \
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

# ── the pak ships the launcher and its profile helper ───────────────────────

@test "every dist target ships launch.sh and platform.sh at the pak root" {
    count_launch="$(grep -c 'cp $(CONFIG)/shared/launch.sh $(DIST)/launch.sh' "$REPO_ROOT/Makefile")"
    count_profile="$(grep -c 'cp $(CONFIG)/shared/platform.sh $(DIST)/platform.sh' "$REPO_ROOT/Makefile")"
    platforms="$(jq -r '.platforms | length' "$REPO_ROOT/pak.json")"
    [ "$count_launch" -eq "$platforms" ]
    [ "$count_profile" -eq "$platforms" ]
}

@test "the pak metadata drives the artifact and install paths" {
    mk PAK_NAME
    [ "$output" = "PAK_NAME=N64" ]
    mk PAK_FOLDER
    [ "$output" = "PAK_FOLDER=Emus" ]
}
