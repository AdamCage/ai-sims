// Lossless RGBA8 PNG encoder. No canvas, colour conversion or premultiplication.
const table = new Uint32Array(256);
for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? 0xedb88320 ^ (c >>> 1) : c >>> 1; table[n] = c >>> 0; }
export function crc32(bytes) { let c = 0xffffffff; for (const b of bytes) c = table[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
function chunk(type, data) { const out = new Uint8Array(12 + data.length); const view = new DataView(out.buffer); view.setUint32(0, data.length); out.set(new TextEncoder().encode(type), 4); out.set(data, 8); view.setUint32(out.length - 4, crc32(out.subarray(4, out.length - 4))); return out; }
function storedDeflate(raw) { // Standards compliant fallback if CompressionStream is absent.
  const blocks = Math.ceil(raw.length / 65535); const out = new Uint8Array(raw.length + blocks * 5 + 6); out.set([0x78, 0x01]); let p = 2, a = 1, b = 0;
  for (let offset = 0; offset < raw.length; offset += 65535) { const count = Math.min(65535, raw.length - offset); out[p++] = offset + count === raw.length ? 1 : 0; out[p++] = count & 255; out[p++] = count >>> 8; out[p++] = (~count) & 255; out[p++] = ((~count) >>> 8) & 255; out.set(raw.subarray(offset, offset + count), p); p += count; }
  for (const value of raw) { a = (a + value) % 65521; b = (b + a) % 65521; } new DataView(out.buffer).setUint32(p, ((b << 16) | a) >>> 0); return out;
}
export async function encodePNG(rgba, width, height, {compress = true} = {}) {
  if (!(rgba instanceof Uint8Array) || !Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 || width > 4096 || height > 4096 || rgba.length !== width * height * 4) throw new Error('Invalid RGBA8 dimensions');
  const raw = new Uint8Array(height * (width * 4 + 1));
  for (let y = 0; y < height; y++) raw.set(rgba.subarray(y * width * 4, (y + 1) * width * 4), y * (width * 4 + 1) + 1);
  let compressed;
  if (compress && typeof CompressionStream === 'function') compressed = new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new CompressionStream('deflate'))).arrayBuffer());
  else compressed = storedDeflate(raw);
  const header = new Uint8Array(13); const hv = new DataView(header.buffer); hv.setUint32(0, width); hv.setUint32(4, height); header.set([8, 6, 0, 0, 0], 8);
  const parts = [new Uint8Array([137,80,78,71,13,10,26,10]), chunk('IHDR', header), chunk('IDAT', compressed), chunk('IEND', new Uint8Array())];
  const png = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0)); let offset = 0; for (const part of parts) { png.set(part, offset); offset += part.length; } return png;
}
