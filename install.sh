#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build + install nvimx296camerasrc on a Jetson (JetPack 6).
#
#   ./install.sh [options]         (sudo is used only for the install step)
#
# Options:
#   --prefix PATH       CMAKE_INSTALL_PREFIX          (default: /usr/local)
#   --plugin-dir PATH   override the GStreamer plugin dir (default: autodetect)
#   --build-only        configure + compile, skip installation
#   --uninstall         remove a previous installation (uses the manifest)
#
# After install the element works system-wide with zero environment setup:
#   gst-launch-1.0 nvimx296camerasrc ! 'video/x-raw(memory:NVMM),...' ! nv3dsink
set -euo pipefail

PREFIX=/usr/local
PLUGIN_DIR=""
BUILD_ONLY=0
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX=$2; shift 2 ;;
        --plugin-dir) PLUGIN_DIR=$2; shift 2 ;;
        --build-only) BUILD_ONLY=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

say() { echo ">>> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo

cd "$(dirname "$0")"

if [ "$UNINSTALL" = 1 ]; then
    [ -f build/install_manifest.txt ] || die "no build/install_manifest.txt - nothing to uninstall"
    say "removing installed files"
    $SUDO xargs rm -v < build/install_manifest.txt
    exit 0
fi

# ---- dependency preflight ----------------------------------------------
say "checking build dependencies"
command -v cmake >/dev/null || die "cmake missing (sudo apt install cmake)"
[ -x /usr/local/cuda/bin/nvcc ] || command -v nvcc >/dev/null || \
    die "CUDA toolkit missing (nvcc not found - install JetPack CUDA)"
pkg-config --exists gstreamer-1.0 gstreamer-base-1.0 gstreamer-video-1.0 || \
    die "GStreamer dev headers missing (sudo apt install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev)"
[ -d /usr/src/jetson_multimedia_api/include ] || \
    die "/usr/src/jetson_multimedia_api missing (sudo apt install nvidia-l4t-jetson-multimedia-api)"
ls /usr/lib/aarch64-linux-gnu/nvidia/libnvbufsurface.so* >/dev/null 2>&1 || \
    die "libnvbufsurface missing (is this a Jetson with JetPack 6?)"

# ---- configure + build ---------------------------------------------------
CMAKE_ARGS=( -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" )
[ -n "$PLUGIN_DIR" ] && CMAKE_ARGS+=( -DGST_PLUGIN_INSTALL_DIR="$PLUGIN_DIR" )
say "configuring (prefix: $PREFIX${PLUGIN_DIR:+, plugin dir: $PLUGIN_DIR})"
cmake -B build "${CMAKE_ARGS[@]}"
say "building"
cmake --build build -j"$(nproc)"

if [ "$BUILD_ONLY" = 1 ]; then
    say "build complete (skipped install). Run from the build dir with:"
    say "  GST_PLUGIN_PATH=$PWD/build gst-launch-1.0 nvimx296camerasrc ..."
    exit 0
fi

# ---- install + verify ----------------------------------------------------
say "installing (needs sudo)"
$SUDO cmake --install build

say "verifying"
# force a plugin registry rescan so the check is honest
rm -f "$HOME/.cache/gstreamer-1.0/registry."*.bin 2>/dev/null || true
if gst-inspect-1.0 nvimx296camerasrc >/dev/null 2>&1; then
    FOUND=$(gst-inspect-1.0 nvimx296camerasrc | awk '/Filename/{print $2}')
    say "OK: nvimx296camerasrc found system-wide ($FOUND)"
    say "try: gst-launch-1.0 nvimx296camerasrc ! 'video/x-raw(memory:NVMM),width=1456,height=1088,framerate=60/1' ! nv3dsink"
else
    die "gst-inspect cannot find nvimx296camerasrc after install - check the plugin dir with: pkg-config --variable=pluginsdir gstreamer-1.0"
fi
