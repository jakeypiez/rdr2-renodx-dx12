// Print DXBC input/output signatures (ISGN/OSGN) so shader replacement ports can
// reproduce the exact register/semantic interface. Read-only.
import fs from 'node:fs';
import path from 'node:path';

const directory = process.argv[2];
if (!directory) throw new Error('Usage: node dump-signatures.mjs <file-or-dir>');
const files = fs.statSync(directory).isDirectory()
  ? fs.readdirSync(directory).filter(n => n.endsWith('.cso')).map(n => path.join(directory, n))
  : [directory];

const COMPONENT = { 0: 'unknown', 1: 'uint32', 2: 'sint32', 3: 'float32' };
const SYSTEM = {
  0: '(none)', 1: 'SV_Position', 2: 'SV_ClipDistance', 3: 'SV_CullDistance',
  4: 'SV_RenderTargetArrayIndex', 5: 'SV_ViewportArrayIndex', 6: 'SV_VertexID',
  7: 'SV_PrimitiveID', 8: 'SV_InstanceID', 9: 'SV_IsFrontFace', 10: 'SV_SampleIndex',
};

function parseSignature(chunk) {
  // Header: DWORD elementCount, DWORD elementArrayOffset (normally 8).
  const count = chunk.readUInt32LE(0);
  const elementsBase = chunk.readUInt32LE(4);
  if (count > 64) throw new Error(`implausible parameter count ${count}`);
  if (elementsBase !== 8) throw new Error(`unexpected element array offset ${elementsBase}`);
  if (elementsBase + count * 24 > chunk.length) throw new Error('element array exceeds chunk');
  const channels = ['x', 'y', 'z', 'w'];
  const maskOf = m => channels.filter((_, i) => (m >> i) & 1).join('');
  const entries = [];
  for (let i = 0; i < count; i++) {
    const base = elementsBase + i * 24;
    // SemanticName offset is absolute from the start of the chunk.
    const nameOffset = chunk.readUInt32LE(base);
    if (nameOffset >= chunk.length) throw new Error(`name offset ${nameOffset} out of range`);
    let end = nameOffset;
    while (end < chunk.length && chunk[end] !== 0) end++;
    entries.push({
      name: chunk.toString('ascii', nameOffset, end),
      index: chunk.readUInt32LE(base + 4),
      system: SYSTEM[chunk.readUInt32LE(base + 8)] ?? `sys${chunk.readUInt32LE(base + 8)}`,
      type: COMPONENT[chunk.readUInt32LE(base + 12)] ?? chunk.readUInt32LE(base + 12),
      register: chunk.readUInt32LE(base + 16),
      mask: maskOf(chunk[base + 20]),
      rwMask: maskOf(chunk[base + 21]),
    });
  }
  return entries;
}

for (const file of files.sort()) {
  const b = fs.readFileSync(file);
  if (b.toString('ascii', 0, 4) !== 'DXBC') { console.log(`${path.basename(file)}: not DXBC`); continue; }
  const count = b.readUInt32LE(28);
  const out = { file: path.basename(file) };
  for (let i = 0; i < count; i++) {
    const o = b.readUInt32LE(32 + 4 * i);
    const tag = b.toString('ascii', o, o + 4);
    const len = b.readUInt32LE(o + 4);
    if (tag === 'ISGN') out.input = parseSignature(b.subarray(o + 8, o + 8 + len));
    if (tag === 'OSGN') out.output = parseSignature(b.subarray(o + 8, o + 8 + len));
  }
  console.log(JSON.stringify(out, null, 1));
}