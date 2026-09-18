# Shader reconstruction — method

How to turn a captured DX12 shader into a modifiable HLSL replacement.

## Why reconstruction, not decompilation

There is **no working automatic SM5.1 → HLSL decompiler** available:

- RenoDX's `decomp` (`src/decompiler/cli.cpp` → `shader_decompiler_dxc.hpp`) is an
  **LLVM IR → HLSL** decompiler. Its tokenizer expects `target datalayout`, `define`,
  `@global`, `!named_metadata` — that is SM6/DXIL. It rejects DXBC.
- For SM5.x, RenoDX uses **3Dmigoto's `cmd_Decompiler`** (see `scripts/setup-dev-env.ps1`,
  `RENODX_THREEDMIGOTO_MIN_VERSION`). Both 1.3.16 and 1.4.9 **fail on SM5.1** bytecode:
  they cannot parse `space=0` on `dcl_sampler`/`dcl_resource`, nor the
  `cb0[22][8]` (descriptor-index + register) operand form.
- DXC cannot read DXBC at all (`-dumpbin` and the API both want DXIL).

So each shader is reconstructed by hand from its disassembly. This is tractable because
RDR2's DX12 shaders are compiled from HLSL and are fairly compact (the output shader is
~57 instructions).

## Workflow

1. **Disassemble** the capture with the Microsoft disassembler (Wine's built-in
   `d3dcompiler_47.dll` emits a different, unusable format):

   ```bash
   wine --bottle win64 tools/dxbc-disasm.exe captures/renodx-dev/dump/0x<HASH>.ps_5_1.cso out.asm
   ```

   This prints the `Input signature` / `Output signature` tables plus declarations and
   instructions with byte offsets.

2. **Read the declarations** to recover the exact interface. Map each `dcl_*` to HLSL:

   | Disassembly | HLSL |
   | --- | --- |
   | `dcl_constantbuffer CB0[22:22][11], space=0` | `cbuffer cb0 : register(b22, space0)` with `float4[11]` |
   | `dcl_sampler S1[5:5], space=0` | `SamplerState s1 : register(s5, space0)` |
   | `dcl_resource_texture2d ... T1[32:32], space=0` | `Texture2D<float4> t1 : register(t32, space0)` |
   | `dcl_resource_structured T0[0:0], 92, space=0` | `StructuredBuffer<...> t0 : register(t0, space0)` (92-byte stride) |

   The register in `CBx[reg:reg]` is the bind point; the first `[n:n]` is the descriptor
   index range. Do not assume the Vulkan mod's layout.

3. **Transcribe the instructions.** `ld_structured`/`ld` become struct member reads,
   `movc` becomes a ternary, `sincos` becomes `cos`, `log`+`mul`+`exp` becomes `pow`.
   Keep the original constants verbatim — the PQ constants (e.g. `0.159302`, `78.84375`,
   `0.835938`, `18.851563`, `18.6875`) and the BT.709→BT.2020 rows must match exactly.

4. **Verify by recompiling and diffing.** This is the important step — it catches
   transcription mistakes:

   ```bash
   wine --bottle win64 tools/hlsl-compile.exe reconstructed/0x<HASH>.ps_5_1.hlsl /tmp/recon.cso ps_5_1 main
   wine --bottle win64 tools/dxbc-disasm.exe /tmp/recon.cso /tmp/recon.asm
   diff <(grep -a dcl_ /tmp/recon.asm) <(grep -a dcl_ out.asm)
   ```

   Expected and benign differences:
   - constant-buffer declared range may shrink to what is actually used
     (e.g. `CB1[23:23][5]` → `CB1[23:23][4]`)
   - `dcl_temps` count changes
   - register allocation differs; the compiler may vectorize channels the original
     handled one at a time

   Anything else — especially a differing resource register, sampler, or constant
   value — is a bug in the reconstruction.

5. **Apply the mod.** Only once the reconstruction is faithful, insert the ported
   helpers from `src/games/rdr2dx12/` at the equivalent operations (for example
   `ApplyGradingAndDisplayMap` where the game's tone map runs, `PQEncodeUI` where the
   PQ encode runs).

## Worked example

`reconstructed/0x1096351C.ps_5_1.hlsl` is the DX12 HDR output / PQ encode pass — the
counterpart of the Vulkan mod's `0x14BF23D4`. Verified results:

- All resource, sampler, input and output bindings match the capture exactly.
- Instruction stream is semantically equivalent (sample → `mad` → optional 3D LUT →
  BT.709→BT.2020 + PQ → premultiply toggle → calibration → vignette → `saturate`).
- The only differences are the benign ones listed above.

Note this shader is **not** a line-by-line port of the Vulkan version: the Vulkan
shader samples a separate alpha texture (`texture(sampler2D(_20, _9), _5).x`) that this
DX12 shader does not. That is exactly why reconstruction must start from the DX12
bytecode rather than translating Vulkan source.

## Injection binding is still unverified

`shared.h` proposes the injection at `register(b13, space50)`. No captured root signature
has been inspected yet, so this is a guess. Confirm it against a real root signature
(RenderDoc or the framework's own logging) before trusting it, and remember the
injected constants consume root-signature DWORDs — 21 floats is 21 DWORDs out of a
64-DWORD budget, so it must fit alongside the game's existing parameters.
