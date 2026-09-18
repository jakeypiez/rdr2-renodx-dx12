# RenoDX for Red Dead Redemption 2 — DirectX 12

An unofficial DX12 port of [Musa Haji's Vulkan HDR mod](https://github.com/clshortfuse/renodx/tree/main/src/games/rdr2vk)
for [RenoDX](https://github.com/clshortfuse/renodx). RDR2 ships both a Vulkan and a DX12 renderer;
upstream RenoDX only supports Vulkan, so this project targets DX12.

> **Status: work in progress.** The add-on builds, loads, replaces the HDR output pass, and
> identifies the correct DX12 shaders — but the **tone-map passes are not yet replaced**, and
> nothing has been tested in game. See [Status](#status) for exactly what is verified.

## Contents

| Path | What it is |
| --- | --- |
| `src/games/rdr2dx12/` | The RenoDX add-on (drop into a RenoDX checkout to build) |
| `src/games/rdr2dx12/shaders/` | DX12 shader replacements |
| `tools/` | macOS-side toolchain for inspecting and decompiling DX12 shaders |
| `scripts/` | macOS build and shader-embedding scripts |
| `docs/` | Method notes and workflow documentation |
| `tools/decompiler-patch/` | Patch adding SM5.1 support to 3DMigoto's decompiler |

## Status

| Area | State |
| --- | --- |
| macOS → Windows cross-build | **Verified** — produces a valid x64 `.addon64` |
| DLL loads on Windows | **Verified** — `DllMain` executes |
| HDR helper shaders (HLSL) | **Verified** — compile with real DXC |
| DX12 shader identification | **Verified** — hashes confirmed against the capture |
| Shader decompilation | **Verified** — all 19 candidates decompile to correct HLSL |
| HDR output pass replacement | **Built and embedded** — bindings verified against the original |
| Tone-map pass replacement | **Not done** |
| In-game result | **Not tested** |

The replaced output pass (`0x1096351C`) preserves every original resource binding and adds the
RenoDX injection constant buffer at `cb13, space50`:

```
dcl_constantbuffer CB2[13:13][1], space=50   // RenoDXInjection
```

**This has not been run in the game.** It compiles, embeds, and loads; whether the HDR path
behaves correctly on screen is unknown.

## Building

No Windows machine or Visual Studio is required. `clang-cl` plus the MSVC CRT/Windows SDK
(via [`xwin`](https://github.com/Jake-Shadle/xwin)) and `lld-link` produce the x64 DLL.

```bash
brew install llvm lld xwin mingw-w64
xwin --accept-license --arch x86_64 splat --output "$HOME/xwin-sdk"
git clone --depth 1 --recurse-submodules https://github.com/clshortfuse/renodx.git "$HOME/renodx-src"

./scripts/build-macos.sh            # -> build/out/renodx-rdr2dx12.addon64
```

`build-macos.sh` first runs `scripts/embed-shaders-macos.sh`, which compiles every
`shaders/<name>_0x<HASH>.<profile>.hlsl` to DXBC and generates the `<embed/shaders.h>` that
`addon.cpp` includes (mirroring what RenoDX's CMake does on Windows).

Copy `build/out/renodx-rdr2dx12.addon64` next to `RDR2.exe` on Windows, with
[ReShade](https://reshade.me/) 6.8.0 or newer installed, and select the DX12 renderer in game.

## Why DX12 needed its own port

RenoDX identifies shaders by the CRC32 of the original bytecode. DX12 bytecode differs from
Vulkan's, so every hash in the Vulkan mod is meaningless here. The DX12 equivalents were
identified by disassembling the captures and matching structural fingerprints:

| Role | DX12 hash | Evidence |
| --- | --- | --- |
| HDR output / PQ encode | `0x1096351C` | `SV_Position`+`TEXCOORD0.xy`; samples `t32`, `mad` with `cb22[7..8]`; `if cb22[9].y` gates BT.709→BT.2020 (`0.627404, 0.329282, 0.043314`); PQ encode via `cb23[0].x / cb23[3].w`; vignette `cos`; `saturate` |
| Tone map + LUT | `0x1D1EEAC6`, `0x20270B14`, `0x4FF4CC58`, `0x6F990851`, `0x8704771A`, `0x9CCF855F`, `0xBF7C33C4`, `0xF039556F`, `0xFC787CD2` | Contain the LUT atlas offsets (`0.001953125`, `0.03125`) and dithering `Texture2DArray` lookup |

## Tooling

All tools run on macOS; the Windows components run under CrossOver/Wine.

| Tool | Purpose |
| --- | --- |
| `scripts/build-macos.sh` | Cross-build the `.addon64` |
| `tools/dxbc-disasm.exe` | DXBC → text via `D3DDisassemble` |
| `tools/decomp-mac` | Standalone macOS build of RenoDX's DXBC→HLSL decompiler |
| `tools/convert-fxc-to-dxc.mjs` | Reformat `D3DDisassemble` output for the decompiler |
| `tools/sm51-to-sm50.mjs` | Reference converter for SM5.1 → SM5.0 binding syntax |
| `tools/dump-signatures.mjs` | Print ISGN/OSGN signatures from a `.cso` |
| `tools/inspect-dxbc.mjs` | CRC32 + constant-fingerprint inventory of a dump |
| `tools/hlsl-compile.exe` | HLSL → DXBC SM5.x via `D3DCompile` |
| `tools/loadtest.exe` | Confirm a `.addon64` loads and its entry point runs |

### Decompiling SM5.1 shaders

There is no off-the-shelf SM5.1 → HLSL decompiler. RenoDX's own decompiler handles SM6/DXIL
only, and 3DMigoto's `cmd_Decompiler` fails on SM5.1. This repo includes a patch that fixes it:

```bash
git clone https://github.com/bo3b/3Dmigoto.git
cd 3Dmigoto
git apply /path/to/tools/decompiler-patch/sm51-support.patch
# build cmd_Decompiler, then:
cmd_Decompiler.exe -D shader.ps_5_1.cso
```

The patch is GPL-licensed (as is 3DMigoto) and is kept separate from this MIT-licensed port.
It is also published as a branch on
[a fork of 3DMigoto](https://github.com/jakeypiez/3Dmigoto/tree/sm51-decompiler-support).

## Reproducing the game shader data

This repository does **not** contain any game-derived data. To work with real shaders you need
your own capture, which you can produce with a debug build of ReShade/RenoDX:

1. Build the add-on with `#define DEBUG_LEVEL_1` and run RDR2 with the DX12 renderer.
2. Collect the shader hashes and bytecode for the tone-map and HDR output passes.
3. Use `tools/` to disassemble, decompile, and verify as described in
   [`docs/reconstruction.md`](docs/reconstruction.md).

## Remaining work

1. Replace the nine tone-map shaders (see the hash table above), applying the helpers in
   `src/games/rdr2dx12/` at the equivalent operations.
2. Reproduce each shader's exact interface — DX12 constant-buffer layouts differ from Vulkan's.
3. Verify the injection fits the root signature (the `b13, space50` binding in `shared.h` is
   still unvalidated against a real root signature) and test in game.

## Credits and licensing

MIT. Portions copyright Musa Haji (RenoDX `rdr2vk`) and Carlos Lopez Jr. (RenoDX framework).
The decompiler patch under `tools/decompiler-patch/` applies to GPL-licensed 3DMigoto and is
distributed under the same terms.

Not affiliated with Rockstar Games, Take-Two Interactive, RenoDX, or 3DMigoto. Red Dead
Redemption 2 is a trademark of Take-Two Interactive. No game assets are distributed here.
