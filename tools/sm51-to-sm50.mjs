// Convert SM5.1 DXBC disassembly into the SM5.0-style text that 3Dmigoto's
// HLSL decompiler understands.
//
// SM5.1 splits binding into (descriptor index, register). 3Dmigoto was written
// for SM5.0, which has only one level, so it cannot parse:
//   * dcl_constantbuffer CB0[22:22][11], immediateIndexed, space=0
//   * dcl_sampler S0[2:2], space=0
//   * dcl_resource_texture2d (...) T1[32:32], space=0
//   * CB0[22][8]   (descriptor index 22, register 8)
//
// This rewrites the descriptor index into the register slot, which preserves
// uniqueness because descriptor indices are unique per resource class:
//   CB0[22][8]  -> cb22[8]      T1[32] -> t32      S1[5] -> s5
// The `, space=N` suffix is dropped (spaces are a SM5.1 concept; 3Dmigoto has no
// notion of them). No instruction semantics change - this is a rename only.
//
// Usage: node tools/sm51-to-sm50.mjs <in.asm> <out.asm>
import fs from 'node:fs';

const [, , inputPath, outputPath] = process.argv;
if (!inputPath || !outputPath) {
  throw new Error('Usage: node tools/sm51-to-sm50.mjs <in.asm> <out.asm>');
}

const lines = fs.readFileSync(inputPath, 'utf8').split('\n');
const out = [];

// Matches the two-level constant-buffer form: CB0[22][8] or CB0[22:22][11]
const cbTwoLevel = /CB(\d+)\[(\d+)(?::\d+)?\]\[(\d+)\]/g;
// Matches resource/sampler access with a descriptor index: T1[32] / S1[5]
const resIndexed = /\b([TSU])(\d+)\[(\d+)\](?::\d+)?/g;

for (const rawLine of lines) {
  let line = rawLine;

  // dcl_constantbuffer CB0[22:22][11], immediateIndexed, space=0
  //   -> dcl_constantbuffer cb22[11], immediateIndexed
  line = line.replace(
    /(dcl_constantbuffer\s+)CB(\d+)\[(\d+)(?::\d+)?\]\[(\d+)\](.*)$/i,
    (_m, kw, _desc, idx, count, rest) =>
      `${kw}cb${idx}[${count}]${rest.replace(/,\s*space=\d+/i, '')}`,
  );

  // dcl_sampler S0[2:2], mode_default, space=0  ->  dcl_sampler s2, mode_default
  line = line.replace(
    /(dcl_sampler\s+)S(\d+)\[(\d+)(?::\d+)?\](.*)$/i,
    (_m, kw, _desc, idx, rest) => `${kw}s${idx}${rest.replace(/,\s*space=\d+/i, '')}`,
  );

  // dcl_resource_* (...) T1[32:32], space=0  ->  dcl_resource_* (...) t32
  // dcl_resource_structured T0[0:0], 92, space=0 -> dcl_resource_structured t0, 92
  line = line.replace(
    /(dcl_resource_\w+\s+(?:\([^)]*\)\s+)?)T(\d+)\[(\d+)(?::\d+)?\](.*)$/i,
    (_m, kw, _desc, idx, rest) => `${kw}t${idx}${rest.replace(/,\s*space=\d+/i, '')}`,
  );

  // Remaining operand forms in instructions and declarations.
  line = line.replace(cbTwoLevel, (_m, _desc, idx, reg) => `cb${idx}[${reg}]`);
  line = line.replace(resIndexed, (_m, kind, _desc, idx) => `${kind.toLowerCase()}${idx}`);
  line = line.replace(/,\s*space=\d+/gi, '');

  out.push(line);
}

fs.writeFileSync(outputPath, out.join('\n'));
console.log(`Wrote ${outputPath} (${out.length} lines)`);
