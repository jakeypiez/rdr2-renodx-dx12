#!/bin/bash
# Build the rdr2dx12 RenoDX add-on (.addon64) on macOS, without Windows or Visual
# Studio, using clang-cl + the xwin MSVC CRT/Windows SDK + lld-link.
#
# Prerequisites (one-time):
#   brew install llvm lld xwin
#   xwin --accept-license --arch x86_64 splat --output "$HOME/xwin-sdk"
#
# Usage: scripts/build-macos.sh [path-to-renodx-checkout]
# Output: build/out/renodx-rdr2dx12.addon64
#
# This reproduces the two steps CMake would perform for this add-on:
#   1. compile src/games/rdr2dx12/addon.cpp
#   2. link it as an x64 DLL
# Shader embedding (src/embed_file.cpp + generated shaders.h) is handled
# separately, see scripts/embed-shaders.mjs.
set -euo pipefail

ADDON=rdr2dx12
HERE="$(cd "$(dirname "$0")/.." && pwd)"
RENODX_SRC="${1:-$HOME/renodx-src}"
SDK="${XWIN_SDK:-$HOME/xwin-sdk}"
CLANG_CL="${CLANG_CL:-/opt/homebrew/opt/llvm/bin/clang-cl}"
LLD_LINK="${LLD_LINK:-$(command -v lld-link)}"
OUT="$HERE/build/out"
OBJ="$HERE/build/obj"

for tool in "$CLANG_CL" "$LLD_LINK"; do
  if [ ! -x "$tool" ]; then
    echo "error: missing $tool (run: brew install llvm lld)" >&2
    exit 1
  fi
done
if [ ! -d "$SDK/crt/include" ]; then
  echo "error: MSVC SDK not found at $SDK" >&2
  echo "run: xwin --accept-license --arch x86_64 splat --output $SDK" >&2
  exit 1
fi
if [ ! -f "$RENODX_SRC/src/mods/shader.hpp" ]; then
  echo "error: RenoDX checkout not found at $RENODX_SRC" >&2
  echo "run: git clone --depth 1 --recurse-submodules https://github.com/clshortfuse/renodx.git $RENODX_SRC" >&2
  exit 1
fi

mkdir -p "$OUT" "$OBJ"

# The add-on must live inside the checkout so its relative includes resolve.
SYNC_DIR="$RENODX_SRC/src/games/$ADDON"
mkdir -p "$SYNC_DIR"
rsync -a --delete "$HERE/src/games/$ADDON/" "$SYNC_DIR/"

echo "==> compiling addon.cpp"
"$CLANG_CL" \
  --target=x86_64-pc-windows-msvc \
  /std:c++20 /EHsc /O2 /c \
  /Fo"$OBJ/addon.obj" \
  /DWIN32 /D_WINDOWS /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS \
  -imsvc "$SDK/crt/include" \
  -imsvc "$SDK/sdk/include/ucrt" \
  -imsvc "$SDK/sdk/include/shared" \
  -imsvc "$SDK/sdk/include/um" \
  -I "$RENODX_SRC" \
  -I "$RENODX_SRC/external/reshade" \
  -I "$RENODX_SRC/external/reshade/include" \
  -I "$RENODX_SRC/external/reshade/deps/imgui" \
  -I "$RENODX_SRC/external/reshade/deps/imgui/imgui" \
  -I "$RENODX_SRC/external/gtl/include" \
  -I "$RENODX_SRC/external/json/include" \
  -I "$RENODX_SRC/external/frozen/include" \
  -I "$RENODX_SRC/src" \
  -- "$SYNC_DIR/addon.cpp"

echo "==> linking renodx-$ADDON.addon64"
"$LLD_LINK" \
  /DLL /MACHINE:X64 /NOIMPLIB \
  /OUT:"$OUT/renodx-$ADDON.addon64" \
  "$OBJ/addon.obj" \
  /LIBPATH:"$SDK/crt/lib/x86_64" \
  /LIBPATH:"$SDK/sdk/lib/um/x86_64" \
  /LIBPATH:"$SDK/sdk/lib/ucrt/x86_64" \
  libcmt.lib libcpmt.lib libvcruntime.lib libucrt.lib \
  kernel32.lib user32.lib shell32.lib ole32.lib oleaut32.lib advapi32.lib gdi32.lib

echo
echo "Built: $OUT/renodx-$ADDON.addon64"
echo "Verify entry point / exports:"
echo "  x86_64-w64-mingw32-objdump -p \"$OUT/renodx-$ADDON.addon64\" | grep -i -E 'AddressOfEntryPoint|DLL Name'"
