#!/bin/bash
# Compile every shader replacement and check that it reads the same resource
# bindings as the original DX12 bytecode it replaces.
#
# Skips the compile if the original disassembly is missing, since there would be
# nothing to compare against.
#
# Usage: scripts/verify-shaders.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/src/games/rdr2dx12/shaders"
ASM="$HERE/captures/msasm"
TOOLS="$HERE/tools"
CX="${CROSSOVER_WINE:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine}"
BOTTLE="${CROSSOVER_BOTTLE:-win64}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cx() { "$CX" --bottle "$BOTTLE" --no-gui --dll d3dcompiler_47=n,b "$@"; }

pass=0
fail=0

for shader in "$SRC"/*.ps_5_1.hlsl; do
  base="$(basename "$shader")"
  name="${base%.ps_5_1.hlsl}"
  original="$ASM/$name.ps_5_1.asm"

  if [ ! -f "$original" ]; then
    echo "SKIP  $name  (no original disassembly)"
    continue
  fi

  flat="$TMP/$name.flat.hlsl"
  cso="$TMP/$name.cso"
  asm="$TMP/$name.asm"

  if ! node "$TOOLS/flatten-hlsl.mjs" "$shader" "$flat" >/dev/null 2>"$TMP/err"; then
    echo "FAIL  $name  (flatten: $(head -1 "$TMP/err"))"
    fail=$((fail + 1))
    continue
  fi

  # The Microsoft compiler warns heavily on RenoDX's maths helpers; only
  # failures matter here.
  if ! cx "$TOOLS/hlsl-compile.exe" "$flat" "$cso" ps_5_1 main >"$TMP/out" 2>&1; then
    echo "FAIL  $name  (compile)"
    grep -a "error" "$TMP/out" | head -3 | sed 's/^/         /'
    fail=$((fail + 1))
    continue
  fi

  if ! cx "$TOOLS/dxbc-disasm.exe" "$cso" "$asm" >/dev/null 2>&1; then
    echo "FAIL  $name  (disassemble)"
    fail=$((fail + 1))
    continue
  fi

  if node "$TOOLS/verify-bindings.mjs" "$original" "$asm" >"$TMP/bind" 2>&1; then
    echo "ok    $name  $(cat "$TMP/bind")"
    pass=$((pass + 1))
  else
    echo "FAIL  $name  (bindings)"
    sed 's/^/         /' "$TMP/bind"
    fail=$((fail + 1))
  fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
