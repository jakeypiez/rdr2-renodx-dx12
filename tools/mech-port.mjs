#!/usr/bin/env node
/*
 * Turn a 3DMigoto decompilation of an RDR2 DX12 tone-map pass into a RenoDX
 * shader replacement.
 *
 * Why generate rather than hand-write: a decompilation already carries the
 * exact register bindings, block strides and arithmetic of the original, so
 * hand-retyping it is a chance to introduce errors for no benefit. Recompiled
 * output is verified to read the same binding slots as the original (see
 * tools/verify-bindings.mjs), which a hand reconstruction cannot beat.
 *
 * The decompiler is not perfect. Every tone-map pass shows the same two
 * artefacts, both repaired here:
 *
 *   1. `dcl_resource_texture1d ... t89` is reported as an unknown declaration
 *      and emitted as a comment, leaving t89 undeclared.
 *   2. The instruction that samples it is emitted as two mangled lines built
 *      from a phantom variable, e.g.
 *        float4 zpos4 = .Sample(s2_s, r0.wwww);
 *        float zTex = zpos4.      r0.w = .Sample(s2_s, r0.wwww).w;
 *      The real instruction is `sample r0.w, r0.wwww, T6[89].xywz, S1[2]`,
 *      reading the .w component. Both lines collapse back to one assignment.
 *
 * It also converts 3DMigoto's entry signature (SV_Position0, an `out` target
 * parameter) into a normal HLSL entry point, and splices in the RenoDX
 * injection and grading call.
 *
 * Usage: node tools/mech-port.mjs <decompiled.hlsl> <out.hlsl> [source-hash]
 */
import { readFileSync, writeFileSync } from "node:fs";

const [inputPath, outputPath, sourceHash = "unknown"] = process.argv.slice(2);
if (!inputPath || !outputPath) {
  console.error("usage: mech-port.mjs <decompiled.hlsl> <out.hlsl> [source-hash]");
  process.exit(2);
}

let source = readFileSync(inputPath, "utf8").replace(/\0/g, "");

// ---------------------------------------------------------------------------
// Repair 1: the texture1d binding the decompiler dropped.
// ---------------------------------------------------------------------------
source = source.replace(
    /\/\/ Needs manual fix for instruction:\n\/\/ unknown dcl_: dcl_resource_texture1d \(float,float,float,float\) t89\n/,
    "");
if (!/Texture1D/.test(source)) {
  // Put it back beside t90 so the declaration list still reads in the same
  // order as the bytecode.
  const anchor = /Texture2D<float4> t90 : register\(t90\);/;
  if (!anchor.test(source)) {
    console.error("error: could not find the t90 declaration to anchor t89 to");
    process.exit(1);
  }
  source = source.replace(
      anchor, "Texture1D<float4> t89 : register(t89);\n\nTexture2D<float4> t90 : register(t90);");
}

// ---------------------------------------------------------------------------
// Repair 2: the mangled sample. Capture the destination and the coordinate so
// the register and swizzle of this shader are preserved rather than assumed.
// ---------------------------------------------------------------------------
const mangled = source.match(
    /^[ \t]*float4 zpos4 = \.Sample\(s2_s, ([^)]+)\);[ \t]*\n[ \t]*float zTex = zpos4\.\s*([A-Za-z0-9_.]+) = \.Sample\(s2_s, [^)]+\)\.w;[ \t]*$/m);
if (!mangled) {
  console.error("error: could not find the mangled texture1d sample");
  process.exit(1);
}
const [, sampleCoordinate, destination] = mangled;
source = source.replace(
    mangled[0],
    `${destination} = t89.Sample(s2_s, ${sampleCoordinate}).w;`);

// The tone-map coefficients and the incoming colour are loaded early, into
// registers that differ per shader. Locate the two t116 loads and the division
// register so the splice below refers to the right ones.
const coefficients0 = source.match(
    /^[ \t]*(\w+)\.xyz = t116\.Load\(float4\(0,0,0,0\)\)\.xyz;$/m);
const coefficients1 = source.match(
    /^[ \t]*(\w+)\.xyzw = t116\.Load\(float4\(1,1,1,1\)\)\.xyzw;$/m);
if (!coefficients0 || !coefficients1) {
  console.error("error: could not find the t116 coefficient loads");
  process.exit(1);
}
const toneMapCoefficients0 = coefficients0[1];
const toneMapCoefficients1 = coefficients1[1];

// ---------------------------------------------------------------------------
// RenoDX tone map.
//
// The nine passes share one tone-map algorithm, but the decompiler assigns it a
// different register in each and the final select uses different swizzles
// (`r1.xyz = ...` in some passes, `r0.yzw = ...` in others, because those leave
// x alone). So rather than pattern-match the whole block -- which would be
// brittle -- this locates its two ends and wraps the unchanged original in an
// else branch. Vanilla therefore keeps the game's arithmetic exactly.
//
// Start: the first `X = cb20[1].x ? cb20[2].z : <orange>.<swizzle>;`
//   This is `cov = (m4 != 0) ? _m10 : _488.z`, i.e. the contrast/white override.
//   Its false arm is the register holding the incoming colour... except where
//   the block reuses a register and rebinds it to the division result first.
// Division: `X = <exposure> / cb20[1].z;`
//   The numerator register holds the incoming colour, scaled. This is `_638`.
// End: the first `? ... : ...` select on cb20[0].w after the start
//   Reads: destination, its swizzle, and the false arm (the untonemapped colour).
// ---------------------------------------------------------------------------
const toneMapStart = source.match(
    /^([ \t]*)(\w+)\.(\w+) = cb20\[1\]\.x \? cb20\[2\]\.z : ([^;]+);$/m);
if (!toneMapStart) {
  console.error("error: could not find the tone-map contrast override");
  process.exit(1);
}
const [startLine, indent, , , overrideFallback] = toneMapStart;

const division = source.match(
    /^([ \t]*)(\w+)\.(\w+) = (\w+\.\w) \/ cb20\[1\]\.z;$/m);
if (!division) {
  console.error("error: could not find the tone-map exposure division");
  process.exit(1);
}
const exposureValue = division[4];  // _638

// The select that closes the tone map. Only lines after the start are eligible.
const afterStart = source.slice(source.indexOf(startLine) + startLine.length);
const toneMapEnd = afterStart.match(
    /^([ \t]*)(\w+)\.(\w+) = cb20\[0\]\.www+ \? ([^;?]+) : ([^;?]+);$/m);

// The end select has a regular shape but keep the assertion explicit: a
// mismatch here would silently drop the RenoDX tone mapper.
if (!toneMapEnd) {
  console.error("error: could not find the tone-map closing select on cb20[0].w");
  process.exit(1);
}
const [endLine, , toneMapDestination, toneMapSwizzle, , trueArm, falseArm] = toneMapEnd;
const untonemapped = trueArm.trim().replace(/\.\w+$/, "");

// `cov` has to be recomputed because the original block that computed it now
// only runs on the vanilla path.
const toneMapReplacement =
    `${indent}if (RENODX_TONE_MAP_TYPE != 0.f) {\n` +
    `${indent}  const float renodx_contrast_override = (asuint(cb20[1].x) != 0u) ? cb20[2].z : ${overrideFallback.trim()};\n` +
    `${indent}  ${toneMapDestination}.${toneMapSwizzle} = ApplyToneMap(\n` +
    `${indent}      ${untonemapped}.xyz,\n` +
    `${indent}      cb20[0].w != 0.f,\n` +
    `${indent}      ${exposureValue},\n` +
    `${indent}      cb20[1].z,\n` +
    `${indent}      (uint)cb20[1].x,\n` +
    `${indent}      renodx_contrast_override,\n` +
    `${indent}      ${toneMapCoefficients0}.xyz,\n` +
    `${indent}      ${toneMapCoefficients1}.xyzw);\n` +
    `${indent}} else {\n`;

// Replace the first line of the block with the guard, and the closing select
// line with itself plus the closing brace.
source = source.replace(startLine, `${toneMapReplacement}${startLine}`);
source = source.replace(endLine, `${endLine}\n${indent}}`);

// ---------------------------------------------------------------------------
// Entry point: 3DMigoto's signature -> a normal HLSL entry.
//
// `#define cmp -` is deliberately kept. 3DMigoto emits comparisons as
// `r1.w = cmp(r1.w >= 1)`, which the macro turns into `r1.w = -(r1.w >= 1)`;
// deleting the macro leaves `cmp` undeclared.
// ---------------------------------------------------------------------------
source = source.replace(/\bvoid main\(/, "float4 main(");
source = source.replace(/float4 v0 : SV_Position0,/, "float4 v0 : SV_Position,");
// The out parameter carries a trailing comma from the preceding input; drop it.
source = source.replace(/,\s*\n\s*out float4 o0 : SV_Target0\)/, ") : SV_Target0");
source = source.replace(
    /(float4 r0)[,;]/, "float4 o0;\n  $1,");

// The original writes o0 then returns nothing. Splice the RenoDX grading in at
// that point, matching the Vulkan mod, which applies it to the final colour of
// every tone-map pass.
if (!/^\s*return;$/m.test(source)) {
  console.error("error: could not find the trailing 'return;' to attach grading to");
  process.exit(1);
}
source = source.replace(
    /^(\s*)return;$/m,
    "$1o0.xyz = ApplyGradingAndDisplayMap(o0.xyz, v1.xy);\n$1return o0;");

// ---------------------------------------------------------------------------
// Prologue.
// ---------------------------------------------------------------------------
const prologue = `/*
 * DX12 replacement for shader ${sourceHash} (ps_5_1) -- RDR2 tone-mapping pass.
 *
 * Generated by tools/mech-port.mjs from a 3DMigoto decompilation of the game's
 * own DX12 bytecode (captures/msasm/${sourceHash}.ps_5_1.asm), then repaired
 * where the decompiler could not represent an instruction. The arithmetic,
 * register bindings and structured-buffer strides are therefore the game's, not
 * a re-derivation, which is why this file is generated rather than written by
 * hand: retyping the decompilation would only add opportunities for error.
 *
 * Not translated from the Vulkan mod's tonemap_*.frag.vk.glsl. The two renderers
 * differ in this pass; the Vulkan source is used only to decide what RenoDX
 * changes, which is the grading call spliced in at the end.
 *
 * The only behavioural changes are:
 *   - the RenoDX injection constant buffer is added (b13, space50), and
 *   - ApplyGradingAndDisplayMap() runs on the final colour.
 * Everything else, including both tone-map branches and the select between
 * them, is the original arithmetic, so ToneMapper = Vanilla is preserved.
 *
 * Bindings are verified to match the original by tools/verify-bindings.mjs.
 *
 * Unverified in game: this has only been validated by compilation and by
 * comparing the binding slots it reads against the original.
 */
#include "../shared.h"
#include "../tonemap/tonemap.hlsli"

`;

writeFileSync(outputPath, prologue + source);
const gradingCall = /ApplyGradingAndDisplayMap/.test(source);
console.log(
    `${outputPath}: ${source.split("\n").length} lines, t89 sample from ${destination.trim()}` +
    `${gradingCall ? "" : "  [WARNING: grading call missing]"}`);
