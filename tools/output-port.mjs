#!/usr/bin/env node
/*
 * Turn a 3DMigoto decompilation of an RDR2 DX12 output/PQ-encode pass into a
 * RenoDX shader replacement.
 *
 * RDR2 emits many variants of this pass: some sample a colour texture, some take
 * the colour from an interpolator, some multiply by a second texture's alpha,
 * one discards below an alpha threshold, one applies a colour-space LUT first.
 * What they share is the tail that matters -- BT.709 -> BT.2020 followed by PQ
 * encoding -- so this patches that tail and leaves each variant's own input
 * stage alone.
 *
 * Two changes, both matching the Vulkan mod's output shaders:
 *
 *   1. GammaSafe() on the linear colour, before the BT.2020 conversion. All ten
 *      of the Vulkan mod's output shaders do this; it is identity unless SDR
 *      EOTF emulation is enabled.
 *
 *   2. PQEncodeUI() replaces the game's own brightness scaling and PQ curve when
 *      a RenoDX tone mapper is active, so the encoder tracks
 *      RENODX_GRAPHICS_WHITE_NITS rather than the game's factors. The original
 *      arithmetic stays in the else branch, so ToneMapper = Vanilla is exact.
 *
 * Usage: node tools/output-port.mjs <decompiled.hlsl> <out.hlsl> <hash>
 */
import { readFileSync, writeFileSync } from "node:fs";

const [inputPath, outputPath, sourceHash = "unknown"] = process.argv.slice(2);
if (!inputPath || !outputPath) {
  console.error("usage: output-port.mjs <decompiled.hlsl> <out.hlsl> <hash>");
  process.exit(2);
}

const source = readFileSync(inputPath, "utf8").replace(/\0/g, "");
const fail = (message) => {
  console.error(`error [${sourceHash}]: ${message}`);
  process.exit(1);
};

// ---------------------------------------------------------------------------
// Locate the encoder.
// ---------------------------------------------------------------------------
// The region to guard runs from the end of the BT.2020 conversion to the end of
// the encoder. Its end is found by line scan rather than by brace matching,
// because some variants put the conversion inside `if (cbXX[n].y != 0) { ... }`
// and others run it unguarded at function level:
//
//   variant A:  if (cb22[9].y != 0) { <conversion> ... <PQ curve> }
//               -> end is the closing brace, which is at a lower indent
//   variant B:  <conversion> ... <PQ curve>
//               if (cb17[2].x != 0) { <dither> }
//               -> end is the next `if` at the same indent
//
// So the end is the first subsequent line that either falls below the
// conversion's indent or starts an `if` at the same indent.

// The BT.2020 conversion reads the linear colour; that register is what
// GammaSafe() must be applied to, before these dots run.
const conversion = [...source.matchAll(
    /^([ \t]*)(\w+)\.\w+ = dot\(float3\(0\.(?:627403975|0690969974|0163915996)[^)]*\),\s*(\w+)\.xyz\);$/gm)];
if (conversion.length !== 3) {
  fail(`expected 3 BT.2020 dot products, found ${conversion.length}`);
}
// Each element of `conversion` is a match array: [full, indent, lhs, rhs].
const conversionIndent = conversion[0][1];
const colorRegister = conversion[0][3];
const lastConversion = conversion[conversion.length - 1];
const guardStart = lastConversion.index + lastConversion[0].length;

const conversionIndentWidth = conversionIndent.length;
// Scan whole lines only: slicing right after the `;` leaves a partial line which
// would look like an unindented one and end the region immediately.
const scanStart = source.indexOf("\n", guardStart) + 1;
const lines = source.slice(scanStart).split("\n");
let guardEnd = null;
let cursor = scanStart;
for (const line of lines) {
  const indentWidth = line.match(/^[ \t]*/)[0].length;
  const isIf = /^[ \t]*if \(/.test(line);
  if (indentWidth < conversionIndentWidth || (isIf && indentWidth <= conversionIndentWidth)) {
    guardEnd = cursor;
    break;
  }
  cursor += line.length + 1;
}
if (guardEnd === null) fail("could not find the end of the encoder region");

const encoderRegion = source.slice(guardStart, guardEnd);

// The PQ curve's results, one component at a time; the last one names the
// register the block leaves the encoded colour in.
const exp2Writes = [...encoderRegion.matchAll(/^[ \t]*(\w+)\.\w+ = exp2\(/gm)];
if (exp2Writes.length === 0) fail("could not find a PQ curve result in the encoder region");
const encodedRegister = exp2Writes[exp2Writes.length - 1][1];

// The converted colour, which is what PQEncodeUI must receive. It is the
// register the game's own brightness scaling multiplies. Finding it here -- in
// the region before the curve can overwrite anything -- matters: the game scales
// it in place, so reading it later would encode an already-scaled colour.
const scaling = encoderRegion.match(/^[ \t]*(\w+)\.\w+ = .*?cb\d+\[\d+\]\.x+.*?\*.*?;$/m);
if (!scaling) fail("could not find the game's cb*[0].x brightness scaling");
const convertedRegister = scaling[1];

// The converted register may legitimately equal the linear one: 0x307A8225
// writes the BT.2020 result back over the linear colour component by component
// (`r1.w = dot(...); r1.x = dot(...)`), so by the time the scaling runs the
// register holds the converted value. Because the guard below is inserted
// *before* the scaling, PQEncodeUI receives that converted value either way,
// which is what matters.

// ---------------------------------------------------------------------------
// Splice.
// ---------------------------------------------------------------------------

// GammaSafe ahead of the conversion: the dots overwrite the linear register, so
// patching after them would apply it to the wrong value.
// GammaSafe must run before the *first* dot: they overwrite the linear register
// component by component, so inserting it later would apply it to a colour that
// is already partly converted.
const firstConversion = conversion[0];
const gammaLine = `${conversionIndent}${colorRegister}.xyz = GammaSafe(${colorRegister}.xyz);\n`;
let out = source.replace(firstConversion[0], `${gammaLine}${firstConversion[0]}`);
const growth = gammaLine.length;

const guard =
    `\n${conversionIndent}if (RENODX_TONE_MAP_TYPE != 0.f) {\n` +
    `${conversionIndent}  ${encodedRegister}.xyz = PQEncodeUI(${convertedRegister}.xyz);\n` +
    `${conversionIndent}} else {`;

// Everything after the first dot has shifted by the GammaSafe insertion, so both
// the guard position and the region end move with it.
const guardIndex = guardStart + growth;
out = out.slice(0, guardIndex) + guard + out.slice(guardIndex);
const closeAt = guardEnd + growth + guard.length;
out = out.slice(0, closeAt) + `${conversionIndent}}\n` + out.slice(closeAt);

const prologue = `/*
 * DX12 replacement for shader ${sourceHash} (ps_5_1) -- RDR2 HDR output / PQ encode pass.
 *
 * Generated by tools/output-port.mjs from a 3DMigoto decompilation of the game's
 * own DX12 bytecode (captures/msasm/${sourceHash}.ps_5_1.asm), so the resource
 * bindings and everything outside the patched encoder are the game's.
 *
 * RDR2 emits many variants of this pass -- some sample a colour texture, some
 * take the colour from an interpolator, some multiply by a second texture's
 * alpha, one discards below an alpha threshold, one applies a colour-space LUT
 * first. Only the shared tail is patched: the BT.709 -> BT.2020 conversion and
 * the PQ encoder. Each variant's own input stage is left exactly as it was.
 *
 * The only behavioural changes, matching the Vulkan mod's output shaders:
 *   - GammaSafe() runs on the linear colour before the BT.2020 conversion, and
 *   - PQEncodeUI() drives the encoder when a RenoDX tone mapper is active,
 *     instead of the game's own brightness factors.
 * The original encoder arithmetic is kept in the else branch, so ToneMapper =
 * Vanilla is exact.
 *
 * Bindings are verified against the original by tools/verify-bindings.mjs.
 *
 * Unverified in game: validated only by compilation and by comparing the binding
 * slots it reads against the original.
 */
#include "../shared.h"
#include "../output/output.hlsli"

`;

writeFileSync(outputPath, prologue + out, "utf8");
console.log(
    `${outputPath}: ${out.split("\n").length} lines, linear=${colorRegister}, ` +
    `converted=${convertedRegister}, encoded=${encodedRegister}`);
