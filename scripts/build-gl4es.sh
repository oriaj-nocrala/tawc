#!/bin/bash
# Cross-compile gl4es (desktop-GL-to-GLES2 translation library) for
# aarch64 Linux (glibc) on the host, for the LIBHYBRIS_GL4ES edge-case
# graphics backend. See notes/libhybris-gl4es.md.
#
# gl4es itself is plain CMake, no autotools/meson multi-driver
# complexity — this script is the CMake analogue of build-libhybris.sh's
# cross-toolchain setup (host Khronos headers via -idirafter, a stub
# libX11.so.6 to satisfy the link, real libX11/libEGL/libGLESv2 supplied
# by the rootfs at runtime). Only X11 needs stubbing: gl4es dlopens
# EGL/GLES by name at runtime (no link-time dependency), and libm/libc
# come from the aarch64-linux-gnu sysroot itself.
#
# Output:
#   build/gl4es-aarch64/install/usr/lib/gl4es/libGL.so.1
# matching the rootfs path Gl4esInstallProvider copies into.
#
# Usage:
#   scripts/build-gl4es.sh           # incremental
#   scripts/build-gl4es.sh --clean   # wipe build tree first

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/deps.sh
source "$SCRIPT_DIR/lib/deps.sh"
GL4ES_DIR="$(dep_dir gl4es)"

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
    esac
done

# ── Toolchain ──
HOST_TRIPLE="aarch64-linux-gnu"
CC_BIN="${HOST_TRIPLE}-gcc"
command -v "$CC_BIN" >/dev/null || {
    echo "ERROR: $CC_BIN not on PATH." >&2
    echo "       Install the aarch64 glibc cross-toolchain:" >&2
    echo "         Arch:   pacman -S aarch64-linux-gnu-{gcc,binutils,glibc,linux-api-headers}" >&2
    echo "         Debian: apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu" >&2
    echo "       See notes/building.md for the full list." >&2
    exit 1
}
command -v cmake >/dev/null || {
    echo "ERROR: cmake not on PATH. See notes/building.md." >&2
    exit 1
}

dep_ensure gl4es

# ── Build tree ──
OUT_DIR="$REPO_DIR/build/gl4es-aarch64"
PREFIX="$OUT_DIR/install"
LIB_DIR="$PREFIX/usr/lib/gl4es"
# Reuse the stub .so directory build-libhybris.sh already generates
# (libX11.so.6 + friends) rather than duplicating stub generation here.
# If libhybris hasn't been built yet on this checkout, build it first —
# both backends need aarch64 libhybris/libEGL/libGLESv2 at runtime
# regardless, and the stub dir is a cheap side effect of that build.
STUB_DIR="$REPO_DIR/build/libhybris-aarch64/stubs"
if [ ! -f "$STUB_DIR/libX11.so.6" ]; then
    echo "==> stub dir missing, running build-libhybris.sh first"
    "$SCRIPT_DIR/build-libhybris.sh"
fi

if [ "$CLEAN" = "1" ]; then
    rm -rf "$OUT_DIR"
fi
mkdir -p "$PREFIX"

BUILD_LOG="$OUT_DIR/build.log"
run_logged() {
    if "$@" >"$BUILD_LOG" 2>&1; then
        tail -n 5 "$BUILD_LOG"
    else
        echo "ERROR: command failed: $*" >&2
        echo "       full log ($BUILD_LOG) follows:" >&2
        cat "$BUILD_LOG" >&2
        exit 1
    fi
}

# ── configure ──
# No PANDORA/BCMHOST/ODROID/CHIP/ANDROID/HYBRIS/AMIGAOS4 platform flag:
# those all imply NOX11 and/or a vendor-specific context-creation path.
# We want the plain generic-Linux path (NOX11 off, NOEGL off) so gl4es
# builds real glX* entry points and creates its EGL context itself via
# libhybris's `x11` EGL platform — notes/libhybris-gl4es.md documents
# why the `HYBRIS` cmake option (Ubuntu Touch's
# eglGetPlatformDisplay(EGL_PLATFORM_ANDROID_KHR) route) segfaults here
# instead. DEFAULT_ES=2 picks the GLES2 backend (GLES1.1 is the
# cmake default). NO_GBM is forced on by CMakeLists.txt whenever -DGBM
# isn't passed, so we don't need libdrm/gbm/egl pkg-config for the
# cross sysroot.
CONFIGURE_STAMP="$OUT_DIR/.tawc-configure-stamp"
FINGERPRINT="cc=$("$CC_BIN" --version | head -1)"
if [ "$CLEAN" = "1" ] || [ ! -f "$OUT_DIR/CMakeCache.txt" ] || \
   [ "$(cat "$CONFIGURE_STAMP" 2>/dev/null)" != "$FINGERPRINT" ]; then
    echo "==> cmake configure"
    rm -rf "$OUT_DIR/CMakeCache.txt" "$OUT_DIR/CMakeFiles"
    run_logged cmake -B "$OUT_DIR" -S "$GL4ES_DIR" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER="$CC_BIN" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_C_FLAGS="-idirafter /usr/include" \
        -DCMAKE_SHARED_LINKER_FLAGS="-L${STUB_DIR}" \
        -DDEFAULT_ES=2
    printf '%s\n' "$FINGERPRINT" >"$CONFIGURE_STAMP"
fi

# ── build ──
echo "==> build"
run_logged cmake --build "$OUT_DIR" --target GL -j"$(nproc)"

# ── install ──
mkdir -p "$LIB_DIR"
"${HOST_TRIPLE}-strip" --strip-unneeded -o "$LIB_DIR/libGL.so.1" "$GL4ES_DIR/lib/libGL.so.1"

# ── verify ──
echo "==> verify"
[ -f "$LIB_DIR/libGL.so.1" ] || { echo "ERROR: libGL.so.1 not built" >&2; exit 1; }
elf_class=$(file "$LIB_DIR/libGL.so.1")
case "$elf_class" in
    *"aarch64"*) ;;
    *) echo "ERROR: libGL.so.1 is not aarch64: $elf_class" >&2; exit 1 ;;
esac
if ! "${HOST_TRIPLE}-readelf" -d "$LIB_DIR/libGL.so.1" | grep -q 'SONAME.*libGL\.so\.1'; then
    echo "ERROR: libGL.so.1 doesn't carry SONAME libGL.so.1" >&2
    exit 1
fi
# awk with an END-gated exit, not `grep -q`: readelf's full symbol dump
# is large enough that grep -q's early exit on match sends readelf
# SIGPIPE, which `pipefail` reports as a pipeline failure even though
# the symbol was found (same trap build-libhybris.sh's
# check_glx_export avoids the same way).
if ! "${HOST_TRIPLE}-readelf" -Ws "$LIB_DIR/libGL.so.1" | awk '
    $4 == "FUNC" && $5 == "GLOBAL" && $8 == "glXCreateContext" { found = 1 }
    END { exit found ? 0 : 1 }
'; then
    echo "ERROR: libGL.so.1 doesn't export glXCreateContext" >&2
    exit 1
fi

# ── tar ──
# CompositorService.ensureGl4esExtracted extracts this as a tar (same
# shape as libhybris/mesa-zink) even though it's a single file, so the
# extractor code doesn't need a single-file special case.
GL4ES_TAR="$PREFIX/usr/lib/gl4es.tar"
tar -C "$LIB_DIR" --format=ustar -cf "$GL4ES_TAR" libGL.so.1

echo "==> done. Output in $LIB_DIR ($GL4ES_TAR)"
