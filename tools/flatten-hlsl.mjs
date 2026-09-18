// Flatten #include directives in an HLSL file into a single translation unit.
//
// The shader compile host (tools/hlsl-compile.c) cannot use a D3D include
// handler reliably under Wine, so includes are resolved here instead. This also
// makes it easy to inspect the exact source being compiled.
//
// Include-guard macros are left in place; files are included at most once, which
// matches their guard semantics. Paths are resolved relative to the including
// file. Output can be fed straight to hlsl-compile.exe.
//
// Usage: node tools/flatten-hlsl.mjs <in.hlsl> <out.hlsl>
import fs from 'node:fs';
import path from 'node:path';

const [, , inputPath, outputPath] = process.argv;
if (!inputPath || !outputPath) {
  throw new Error('Usage: node tools/flatten-hlsl.mjs <in.hlsl> <out.hlsl>');
}

const included = new Set();
const out = [];

function resolve(includingFile, target) {
  return path.normalize(path.join(path.dirname(includingFile), target));
}

function expand(file) {
  const resolved = path.resolve(file);
  if (included.has(resolved)) return;
  included.add(resolved);

  const lines = fs.readFileSync(resolved, 'utf8').split('\n');
  for (const line of lines) {
    const match = line.match(/^\s*#\s*include\s+"([^"]+)"/);
    if (match) {
      const target = resolve(resolved, match[1]);
      if (!fs.existsSync(target)) {
        throw new Error(`#include not found: ${match[1]} (from ${resolved})`);
      }
      out.push(`// ---- begin ${path.basename(target)} ----`);
      expand(target);
      out.push(`// ---- end ${path.basename(target)} ----`);
      continue;
    }
    out.push(line);
  }
}

expand(inputPath);
fs.writeFileSync(outputPath, out.join('\n'));
console.log(`Flattened ${included.size} file(s) -> ${outputPath}`);
