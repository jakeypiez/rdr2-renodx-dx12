# RenoDX for Red Dead Redemption 2 — DirectX 12

An unofficial DX12 port of [Musa Haji's Vulkan HDR mod](https://github.com/clshortfuse/renodx/tree/main/src/games/rdr2vk)
for [RenoDX](https://github.com/clshortfuse/renodx). RDR2 ships both a Vulkan and a DX12 renderer;
upstream RenoDX only supports Vulkan, so this project targets DX12.

> **Status: work in progress.** The add-on builds, loads, and replaces the HDR output pass and all
> nine tone-map passes — but **nothing has been tested in game**. See [Status](#status) for exactly
> what is verified.

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
| Tone-map pass replacement | **All 9 built and embedded** — bindings verified |
| In-game result | **Not tested** |

All 10 replaced shaders preserve every original resource binding and add the RenoDX injection
constant buffer at `cb13, space50`:

```
dcl_constantbuffer CB2[13:13][1], space=50   // RenoDXInjection
```

`scripts/verify-shaders.sh` checks that mechanically: it compiles every replacement and runs
`tools/verify-bindings.mjs`, which fails if a replacement does not read the same binding slots as
the original. It keys on the slot in brackets (`T15[116]` is register 15, *binding* 116), because
fxc renumbers register indices by declaration order and drops unused declarations, so comparing
declaration text reports a wall of differences that do not matter.

```
ok    0x1096351C  ok: 9 binding slots used identically
ok    0x1D1EEAC6  ok: 32 binding slots used identically
...
10 passed, 0 failed
```

**This has not been run in the game.** It compiles, embeds, and loads; whether it behaves
correctly on screen is unknown. The single biggest unverified assumption is the injection binding:
if a real RDR2 root signature does not expose `b13, space50`, ReShade will not create the cloned
pipeline layout and the replacements simply will not take effect — you would see the stock game
rather than a broken image.

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

### Tone-map pass structure

All nine tone-map passes end with the same post-processing tail, which is why one reconstruction
can be adapted to the others. In `0x20270B14` the stages are:

| # | Stage | Bytecode evidence |
| --- | --- | --- |
| 1 | Exposure and optional alpha composite | `t110` → `t90`, `t44`, `t116`; `if CB0[16][64].x` |
| 2 | Exposure curve and radial falloff | `CB0[16][73..75]`, `CB0[16][53..56]` |
| 3 | Time-of-day colour curve | `CB0[16][57..60]`, driven by `v1.y` |
| 4 | **Tone map** | `CB1[20][0..3]` (both branches evaluated, selected on `cb20[0].w`) |
| 5 | Vignette gradient | `Texture1D t89`, `CB0[16][49..52]` |
| 6 | LUT input encoding | `CB1[20][2..3]` |
| 7 | BT.2020 lift and look mask | literals `0.5149/0.3244/0.1607…`, `CB0[16][83..84]` |
| 8 | Aberration sample | `t111`, `CB0[16][86..87]` |
| 9 | LUT atlas lookups, look presets, decode | `t106/t100/t101` atlas, `t107` attribution, `t78` depth, `t118` presets |
| 10 | Luma and display curve | `CB0[16][39..42]` |
| 11 | Dither | `Texture2DArray t25` + `t3` |
| 12 | RenoDX grading | added, mirrors the Vulkan mod |

Stages 1–8 are the input-varying part that distinguishes the nine passes; stages 9–12 are shared.

### How the tone-map passes are ported

The nine passes were **not** hand-written. `tools/mech-port.mjs` generates each one from the
3DMigoto decompilation of the game's own bytecode, so the arithmetic, register bindings and
structured-buffer strides are the game's rather than a re-derivation — hand-retyping a decompilation
only adds chances to introduce errors.

Inspection showed the post-tone-map tail is **instruction-identical across all nine passes** modulo
register numbering and swizzle lanes, and the tone-map algorithm itself is shared, differing only in
which register it uses and in the final select's swizzle (`r1.xyz = ...` in some passes,
`r0.yzw = ...` in others, where the pass leaves x alone). So the generator locates the block's two
boundaries — the `cb20[1].x ? cb20[2].z` contrast override and the closing `cb20[0].w` select — and
wraps the unchanged original in an `else`, putting `ApplyToneMap()` on the RenoDX path.

That structure is what makes `ToneMapper = Vanilla` exact: the vanilla branch is the game's own
arithmetic, untouched. The generator fails loudly if either boundary or the coefficient loads cannot
be found, rather than silently emitting a pass that skips the RenoDX tone mapper.

The decompiler has two reproducible gaps in this pass, both repaired and documented in the
generator: it cannot represent `dcl_resource_texture1d`, and it emits the instruction sampling that
texture as two mangled lines built from a phantom variable.

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
| `tools/mech-port.mjs` | Turn a decompiled tone-map pass into a RenoDX replacement |
| `tools/verify-bindings.mjs` | Fail if a replacement reads different binding slots |
| `scripts/verify-shaders.sh` | Compile and binding-check every replacement at once |

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
