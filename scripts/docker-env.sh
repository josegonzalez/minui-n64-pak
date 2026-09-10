#!/bin/bash
# Cross-compile environment for the toolchain containers, then exec the command.
#
# Referenced as $(DOCKER_SCRIPT) by every `docker run` in the Makefile. Lives in
# the repo (rather than being generated into src/) so it survives `make clean`
# and shows up in review.
set -e

# The toolchain images export their cross-compile env from ~/.bashrc. Tolerate its
# absence so the script stays runnable outside a container (see tests/makefile.bats).
[ -f ~/.bashrc ] && . ~/.bashrc

SYSROOT_DIR=/opt/aarch64-nextui-linux-gnu/aarch64-nextui-linux-gnu/libc
export PKG_CONFIG_PATH="$SYSROOT_DIR/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_DIR"

# The h700 toolchain ships a patched mali-fbdev SDL2 under $PREFIX_LOCAL, and
# that is the build NextUI installs on the device. Prefer it over the TrimUI SDK
# copy in the sysroot. Its .pc file records an absolute in-image prefix, so
# PKG_CONFIG_SYSROOT_DIR has to be cleared for that lookup or pkg-config would
# rewrite every path under the sysroot. Toolchains that leave $PREFIX_LOCAL
# empty (tg5040, tg5050, my355) fall through to the sysroot unchanged.
if [ -f "${PREFIX_LOCAL:-/nonexistent}/lib/pkgconfig/sdl2.pc" ]; then
    SDL_CFLAGS="$(PKG_CONFIG_SYSROOT_DIR= PKG_CONFIG_PATH="$PREFIX_LOCAL/lib/pkgconfig" pkg-config --cflags sdl2)"
    SDL_LDLIBS="$(PKG_CONFIG_SYSROOT_DIR= PKG_CONFIG_PATH="$PREFIX_LOCAL/lib/pkgconfig" pkg-config --libs sdl2)"
    echo "docker-env: SDL2 from PREFIX_LOCAL ($PREFIX_LOCAL)" >&2
elif [ "$UNION_PLATFORM" = "h700" ]; then
    # h700 binaries must link the patched SDL2, because that is the one NextUI
    # installs on the device. Silently falling back to the TrimUI SDK copy would
    # still build, so fail loudly instead.
    echo "docker-env: error: h700 toolchain is missing the patched SDL2 at ${PREFIX_LOCAL:-<unset>}/lib/pkgconfig/sdl2.pc" >&2
    exit 1
else
    SDL_CFLAGS="$(pkg-config --cflags sdl2)"
    SDL_LDLIBS="$(pkg-config --libs sdl2)"
    echo "docker-env: SDL2 from sysroot ($SYSROOT_DIR)" >&2
fi
export SDL_CFLAGS SDL_LDLIBS

exec "$@"
