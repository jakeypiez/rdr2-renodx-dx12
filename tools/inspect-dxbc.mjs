// Read-only DXBC inventory and constant fingerprinting. No shader rewriting.
// Fingerprints are heuristics, NOT instruction decoding or pass identification.
import fs from 'node:fs';
import path from 'node:path';

const directory = process.argv[2];
if (!directory) throw new Error('Usage: node inspect-dxbc.mjs <dump-directory>');
const table = Array.from({length: 256}, (_, n) => {
  let c = n;
  for (let j = 0; j < 8; j++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
  return c >>> 0;
});
function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = table[(c ^ byte) & 255] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
if (crc32(Buffer.from('123456789')) !== 0xcbf43926) throw new Error('CRC32 self-test failed');
const hex = n => '0x' + n.toString(16).toUpperCase().padStart(8, '0');
const fingerprints = {
  pq: [0.1593017578125, 78.84375, 0.8359375, 18.8515625, 18.6875],
  bt2020: [0.627403974533081, 0.329281985759735, 0.0433136001229286, 0.0690969973802567, 0.919539988040924],
  lut: [0.001953125, 0.03125],
  halfClamp: [65504],
};
const bits = value => { const b = Buffer.alloc(4); b.writeFloatLE(value); return b.readUInt32LE(); };
const rows = [];
for (const file of fs.readdirSync(directory).filter(n => n.endsWith('.cso')).sort()) {
  const b = fs.readFileSync(path.join(directory, file));
  if (b.length < 32 || b.toString('ascii', 0, 4) !== 'DXBC') throw new Error(`${file}: missing DXBC header`);
  if (b.readUInt32LE(24) !== b.length) throw new Error(`${file}: size mismatch`);
  const count = b.readUInt32LE(28);
  if (count > (b.length - 32) / 4) throw new Error(`${file}: invalid chunk count`);
  const chunks = [], words = new Set();
  let profile;
  for (let i = 0; i < count; i++) {
    const offset = b.readUInt32LE(32 + 4 * i);
    if (offset + 8 > b.length) throw new Error(`${file}: invalid chunk offset`);
    const tag = b.toString('ascii', offset, offset + 4);
    const length = b.readUInt32LE(offset + 4);
    if (offset + 8 + length > b.length) throw new Error(`${file}: invalid chunk size`);
    chunks.push({tag, length});
    if (tag === 'SHEX' || tag === 'SHDR') {
      if (length < 8 || length % 4) throw new Error(`${file}: invalid shader payload`);
      const version = b.readUInt32LE(offset + 8);
      const stage = ['ps', 'vs', 'gs', 'hs', 'ds', 'cs'][version >>> 16] ?? 'unknown';
      profile = `${stage}_${(version >>> 4) & 15}_${version & 15}`;
      if (b.readUInt32LE(offset + 12) * 4 !== length) throw new Error(`${file}: invalid token count`);
      // All aligned token words, not decoded immediate operands: false positives possible.
      for (let p = offset + 16; p < offset + 8 + length; p += 4) words.add(b.readUInt32LE(p));
    }
  }
  const actualCRC = hex(crc32(b));
  const expectedCRC = file.split('.')[0].toUpperCase().replace('0X', '0x');
  const matches = Object.fromEntries(Object.entries(fingerprints).map(([key, values]) =>
    [key, values.filter(v => words.has(bits(v))).length]));
  rows.push({file, bytes:b.length, profile, actualCRC, filenameCRCMatches:actualCRC === expectedCRC,
    filenameProfileMatches:profile === file.split('.')[1], chunks, matches});
}
const profiles = {};
for (const r of rows) profiles[r.profile] = (profiles[r.profile] ?? 0) + 1;
console.log(JSON.stringify({
  caveat:'Constant matches search aligned shader token words, not decoded operands. Candidates are not verified passes.',
  total:rows.length, profiles,
  crcMismatches:rows.filter(r => !r.filenameCRCMatches).map(r => ({file:r.file, actualCRC:r.actualCRC})),
  profileMismatches:rows.filter(r => !r.filenameProfileMatches).map(r=>r.file),
  chunks:[...new Set(rows.flatMap(r=>r.chunks.map(c=>c.tag)))],
  pqCandidates:rows.filter(r => r.profile.startsWith('ps_') && r.matches.pq >= 4),
  lutClampCandidates:rows.filter(r => r.profile.startsWith('ps_') && r.matches.lut === 2 && r.matches.halfClamp === 1),
}, null, 2));
