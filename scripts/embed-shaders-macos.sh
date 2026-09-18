#!/bin/bash
# Compile the add-on's shader replacements and generate the embed headers that
# addon.cpp includes via <embed/shaders.h>.
#
# This mirrors what RenoDX's CMake build does for *.hlsl under the add-on folder:
#   <name>_0x<HASH>.<profile>.hlsl  ->  <HASH>.cso  ->  __0x<HASH> symbol
# It is a macOS-side stand-in for that step, run before scripts/build-macos.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ADDON="rdr2dx12"
SRC="$HERE/src/games/$ADDON"
EMBED="${EMBED_DIR:-$HERE/build/embed}"
TOOLS="$HERE/tools"
CX="${CROSSOVER_WINE:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine}"
BOTTLE="${CROSSOVER_BOTTLE:-win64}"

mkdir -p "$EMBED"

cx() { perl -e 'alarm 300; exec @ARGV' "$CX" --bottle "$BOTTLE" --no-gui --dll d3dcompiler_47=n,b "$@"; }

echo "==> scanning $SRC for shader replacements"
shaders_h=$'#pragma once\n'
entries=()
found=0

# Find <name>_0x<HASH>.<profile>.hlsl
while IFS= read -r file; do
  base="$(basename "$file")"
  stem="${base%.hlsl}"
  profile="${stem##*.}"
  name="${stem%.*}"
  hash="$(printf '%s' "$name" | grep -oE '0x[0-9A-Fa-f]{8}$' || true)"
  if [ -z "$hash" ]; then
    echo "    skipping (no hash in name): $base"
    continue
  fi

  cso="$EMBED/$hash.cso"
  header="$EMBED/$hash.h"
  flat="$EMBED/$hash.flat.hlsl"

  echo "    $base -> $hash.cso ($profile)"
  node "$TOOLS/flatten-hlsl.mjs" "$file" "$flat" >/dev/null
  cx "$TOOLS/hlsl-compile.exe" "$flat" "$cso" "$profile" main >/dev/null

  # Generate the embed header exactly as RenoDX's embed_file.cpp does.
  node -e '
    const fs = require("fs");
    const [cso, out] = process.argv.slice(1);
    const bytes = fs.readFileSync(cso);
    const sym = "__" + require("path").basename(cso, ".cso");
    let s = "#pragma once\n";
    s += "#ifndef " + sym + "_EMBED_FILE\n#define " + sym + "_EMBED_FILE\n";
    s += "#include <cstdint>\n#include <span>\n";
    s += "inline constexpr std::uint8_t " + sym + "_base[] = {\n";
    let n = 0;
    for (const b of bytes) {
      if (n === 0) s += "   ";
      s += " " + b + ",";
      if (++n === 8) { s += "\n"; n = 0; }
    }
    if (n !== 0) s += "\n";
    s += "};\n";
    s += "inline constexpr std::span<const std::uint8_t> " + sym + "{\n" + sym + "_base\n};\n";
    s += "#endif\n";
    fs.writeFileSync(out, s);
  ' "$cso" "$header"

  shaders_h+="#include \"./$hash.h\""$'\n'
  entries+=("  CustomShaderEntry($hash)")
  found=$((found + 1))
done < <(find "$SRC" -name "*.hlsl" | sort)

# Emit one entry list, not one macro per shader. __ALL_CUSTOM_SHADERS is
# expanded at its point of use, so a per-shader `#define
# __CUSTOM_SHADER_ENTRIES` would leave only the final definition visible and
# silently register just the last shader.
#
# Entries are comma-separated (the macro expands into a braced initialiser
# list) and each line but the last ends with a line continuation; a trailing
# backslash on the final entry would splice the following #define onto it.
shaders_h+=$'\n'$'#define __CUSTOM_SHADER_ENTRIES \\\n'
last=$((found - 1))
for ((i = 0; i < found; i++)); do
  if [ "$i" -lt "$last" ]; then
    shaders_h+="${entries[$i]}, \\"$'\n'
  else
    shaders_h+="${entries[$i]}"$'\n'
  fi
done
shaders_h+=$'\n'$'#define __ALL_CUSTOM_SHADERS \\\n'
shaders_h+="  __CUSTOM_SHADER_ENTRIES"$'\n'

printf '%s' "$shaders_h" > "$EMBED/shaders.h"
echo "==> $found shader(s); wrote $EMBED/shaders.h"
