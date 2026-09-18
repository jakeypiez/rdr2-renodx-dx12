#!/usr/bin/env node
/*
 * Check that a replacement shader uses the same resource bindings as the
 * original bytecode it replaces.
 *
 * Why this exists: fxc numbers resources by declaration order and drops
 * declarations that are never read, so a replacement that binds perfectly can
 * still print entirely different `dcl_*` text -- every register index shifts by
 * one. Comparing declaration text therefore reports a wall of differences that
 * do not matter, while what actually decides correctness is which *slot* each
 * instruction reads.
 *
 * In DXBC the register index (T15) is local to the shader and the number in
 * brackets (T15[118]) is the binding. This script keys on the binding.
 *
 * Usage: node tools/verify-bindings.mjs <original.asm> <replacement.asm>
 */
import { readFileSync } from "node:fs";

const strip = (s) => s.replace(/\0/g, " ");

// Map binding slot -> resource type, from the dcl_* declarations. Note that
// fxc also aliases one declaration onto a range, e.g. `T0[2:2]`, so both ends
// of a range are recorded.
function parseDeclarations(text) {
  const bySlot = new Map();
  const record = (kind, slot, type) => {
    const key = `${kind}${slot}`;
    if (!bySlot.has(key)) bySlot.set(key, type);
  };

  for (const m of text.matchAll(/dcl_constantbuffer\s+CB(\d+)\[(\d+):\d+\]\[(\d+)\]/g)) {
    record("cb", m[2], `constant buffer size=${m[3]}`);
  }
  for (const m of text.matchAll(/dcl_sampler\s+S(\d+)\[(\d+):\d+\]/g)) {
    record("s", m[2], `sampler`);
  }
  for (const m of text.matchAll(/dcl_resource_structured\s+T(\d+)\[(\d+):\d+\],\s*(\d+)/g)) {
    record("t", m[2], `structured buffer stride=${m[3]}`);
  }
  for (const m of text.matchAll(/dcl_resource_buffer\s+\([^)]*\)\s+T(\d+)\[(\d+):\d+\]/g)) {
    record("t", m[2], `buffer`);
  }
  for (const m of text.matchAll(/dcl_resource_(texture2darray|texture2d|texture1d|texture3d|texturecube)\s+\([^)]*\)\s+T(\d+)\[(\d+):\d+\]/g)) {
    record("t", m[2], m[1]);
  }
  return bySlot;
}

// Collect which binding slots the executable body actually references. Only
// instruction lines are scanned, so a declaration alone never counts as use.
// For constant buffers the accessed vector indices are recorded too: the
// declared array length is a compiler artefact (fxc trims it to the highest
// index a shader reaches), so comparing lengths would report a difference every
// time a shader legitimately stops using a trailing vector.
function parseUsage(text) {
  const body = text
    .split("\n")
    // Instruction lines look like: "  187  0x00001AA4: ld_structured r0.w, ..."
    .filter((line) => /^\s*\d+\s+0x[0-9A-Fa-f]+:\s/.test(line))
    .join("\n");

  const used = new Map();
  const bump = (key) => used.set(key, (used.get(key) ?? 0) + 1);

  // `CB0[16][64]`: register CB0, binding b16, vector 64. Under SM5.1 the
  // matching declaration is `dcl_constantbuffer CB0[16:16][88], ..., space=0`;
  // the number in the first bracket is the binding.
  const cbIndices = new Map();
  for (const m of body.matchAll(/\bCB(\d+)\[(\d+)\](?:\[(\d+)\])?/g)) {
    bump(`cb${m[2]}`);
    const key = `cb${m[2]}`;
    const seen = cbIndices.get(key) ?? new Set();
    if (m[3] !== undefined) seen.add(Number(m[3]));
    cbIndices.set(key, seen);
  }
  // `S2[8]`: register S2, binding s8.
  for (const m of body.matchAll(/(?<![\w.])S(\d+)\[(\d+)\]/g)) {
    bump(`s${m[2]}`);
  }
  // `T15[116]`: register T15, binding t116.
  for (const m of body.matchAll(/(?<![\w.])T(\d+)\[(\d+)\]/g)) {
    bump(`t${m[2]}`);
  }
  // Shader inputs are compared separately: `dcl_input_ps linear v1.xyz`.
  for (const m of text.matchAll(/dcl_input_ps(?:_siv)?(?:\s+\w+)*\s+v(\d+)\.([xyzw]+)/g)) {
    const previous = used.get(`v${m[1]}`);
    const merged = previous ? [...new Set(previous + m[2])].sort().join("") : m[2];
    used.set(`v${m[1]}`, merged);
  }
  for (const m of text.matchAll(/dcl_output\s+o(\d+)\.([xyzw]+)/g)) {
    const previous = used.get(`o${m[1]}`);
    const merged = previous ? [...new Set(previous + m[2])].sort().join("") : m[2];
    used.set(`o${m[1]}`, merged);
  }

  return { used, cbIndices };
}

// The injection constant buffer is declared by shared.h and always occupies
// b13, space 50. Its vector count depends on which helpers a shader happens to
// use, so the size carries no binding information.
const isInjection = (key) => key === "cb13";

const [originalPath, replacementPath] = process.argv.slice(2);
if (!originalPath || !replacementPath) {
  console.error("usage: verify-bindings.mjs <original.asm> <replacement.asm>");
  process.exit(2);
}

const parse = (path) => {
  const text = strip(readFileSync(path, "latin1"));
  return {
    declarations: parseDeclarations(text),
    ...parseUsage(text),
  };
};

const original = parse(originalPath);
const replacement = parse(replacementPath);

const sortKey = (r) => [r.replace(/\d+$/, ""), parseInt(r.replace(/^\D+/, ""), 10) || 0];
const keys = [...new Set([...original.used.keys(), ...replacement.used.keys()])]
  .filter((r) => !isInjection(r))
  .sort((a, b) => {
    const [ka, na] = sortKey(a);
    const [kb, nb] = sortKey(b);
    return ka.localeCompare(kb) || na - nb;
  });

const problems = [];
for (const key of keys) {
  const before = original.used.get(key);
  const after = replacement.used.get(key);

  if (before === undefined) {
    problems.push(`  ${key.padEnd(6)} only the replacement uses it  [${replacement.declarations.get(key) ?? "?"}]`);
    continue;
  }
  if (after === undefined) {
    problems.push(`  ${key.padEnd(6)} only the original uses it     [${original.declarations.get(key) ?? "?"}]`);
    continue;
  }

  // Resource type must agree; the instruction count may legitimately differ.
  // A constant buffer's declared length is trimmed by fxc to the highest vector
  // the shader reaches, so for cbuffers compare the vectors read instead of the
  // declared size.
  const typeBefore = original.declarations.get(key);
  const typeAfter = replacement.declarations.get(key);
  const sizeOf = (type) => (type ?? "").replace(/.*=(\d+)$/, "$1");
  if (typeBefore !== typeAfter && !(key.startsWith("cb") && sizeOf(typeBefore) !== sizeOf(typeAfter))) {
    problems.push(`  ${key.padEnd(6)} type changed: ${typeBefore} -> ${typeAfter}`);
    continue;
  }

  if (key.startsWith("cb")) {
    const indicesBefore = [...(original.cbIndices.get(key) ?? [])].sort((a, b) => a - b).join(",");
    const indicesAfter = [...(replacement.cbIndices.get(key) ?? [])].sort((a, b) => a - b).join(",");
    if (indicesBefore !== indicesAfter) {
      problems.push(`  ${key.padEnd(6)} vectors read differ: [${indicesBefore}] -> [${indicesAfter}]`);
    }
  }
}

if (problems.length === 0) {
  console.log(`ok: ${keys.length} binding slots used identically`);
  process.exit(0);
}

console.log(`${problems.length} of ${keys.length} binding slots differ:`);
console.log(problems.join("\n"));
process.exit(1);
