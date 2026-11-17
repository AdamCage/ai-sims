export const BACKUP_SCHEMA = 'ai-sims-local-backup-v1';
// Three individually bounded 32 MiB slot envelopes plus JSON quoting.
export const MAX_BACKUP_BYTES = 128 * 1024 * 1024;
export function parseBackup(text) {
  if (typeof text !== 'string' || new TextEncoder().encode(text).length > MAX_BACKUP_BYTES) throw new Error('Backup is too large');
  const raw = JSON.parse(text);
  if (!raw || raw.schema !== BACKUP_SCHEMA || !raw.slots || Array.isArray(raw.slots) || typeof raw.slots !== 'object') throw new Error('Unsupported save format');
  const slots = {};
  for (const [name, content] of Object.entries(raw.slots)) {
    if (!/^slot_[123]\.json$/.test(name) || typeof content !== 'string' || content.length>32*1024*1024) throw new Error('Invalid save slot');
    const wrapper = JSON.parse(content); if (!wrapper || typeof wrapper.payload !== 'string' || !/^[a-f0-9]{64}$/.test(wrapper.sha256)) throw new Error('Invalid save envelope');
    const envelope = JSON.parse(wrapper.payload); if (envelope.schema !== 2 || !envelope.data || typeof envelope.data !== 'object') throw new Error('Invalid save data');
    if (/sk-[A-Za-z0-9_-]{12,}/.test(content)) throw new Error('Backup contains a credential');
    slots[name] = content;
  }
  return slots;
}
export function makeBackup(slots) { return JSON.stringify({schema: BACKUP_SCHEMA, created_utc: new Date().toISOString(), slots}, null, 2); }

export function referencedImages(slots) {
  const ids = new Set();
  function visit(value) {
    if (!value || typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) {
      if (typeof child === 'string' && (key === 'image_ref' || key === 'hash') && /^[a-f0-9]{64}$/.test(child)) ids.add(child);
      else visit(child);
    }
  }
  for (const wrapped of Object.values(slots)) visit(JSON.parse(JSON.parse(wrapped).payload).data);
  return [...ids];
}

// A length-prefixed manifest followed by exact PNG byte ranges. Blob slices
// let the importer validate and restore one image at a time on modest laptops.
export function makeArchive(slots, images) {
  const media = [...images].map(([hash, bytes]) => ({hash, size:bytes.byteLength}));
  const expected = new Set(referencedImages(slots));
  if (media.some(item => !expected.delete(item.hash)) || expected.size) throw new Error('Missing photographs');
  const manifest = new TextEncoder().encode(JSON.stringify({schema:'ai-sims-backup-v2', slots, media}));
  if (manifest.length > MAX_BACKUP_BYTES) throw new Error('Save manifest is too large');
  const header = new Uint8Array(8);
  header.set([65,73,83,50]); new DataView(header.buffer).setUint32(4,manifest.length);
  return new Blob([header,manifest,...images.values()],{type:'application/octet-stream'});
}

export async function readArchive(file) {
  const prefix = new Uint8Array(await file.slice(0,8).arrayBuffer());
  let slots, images = new Map(), missingImages = [];
  if (prefix.length < 8 || String.fromCharCode(...prefix.slice(0,4)) !== 'AIS2') {
    if (file.size > MAX_BACKUP_BYTES) throw new Error('Invalid legacy save size');
    slots = parseBackup(await file.text());
    missingImages = referencedImages(slots);
  } else {
    const size = new DataView(prefix.buffer).getUint32(4);
    if (size > MAX_BACKUP_BYTES || size+8 > file.size) throw new Error('Invalid archive header');
    const manifest = JSON.parse(await file.slice(8,8+size).text());
    if (manifest.schema !== 'ai-sims-backup-v2' || !Array.isArray(manifest.media)) throw new Error('Invalid archive');
    slots = parseBackup(makeBackup(manifest.slots));
    let offset = 8+size;
    const expected = new Set(referencedImages(slots));
    for (const item of manifest.media) {
      if (!expected.delete(item.hash) || !Number.isSafeInteger(item.size) || item.size <= 0 || item.size > 8388608 || offset+item.size>file.size) throw new Error('Invalid image index');
      images.set(item.hash,file.slice(offset,offset+item.size));offset+=item.size;
    }
    if (expected.size || offset!==file.size) throw new Error('Incomplete archive');
  }
  for (const wrapped of Object.values(slots)) {
    const {payload,sha256:hash}=JSON.parse(wrapped);
    if (await sha256(new TextEncoder().encode(payload))!==hash) throw new Error('Invalid save checksum');
  }
  return {slots, images, missingImages};
}
export function base64ToBytes(value) { return Uint8Array.from(atob(value), c => c.charCodeAt(0)); }
export function bytesToBase64(bytes) { let result = ''; for (let offset = 0; offset < bytes.length; offset += 32768) result += String.fromCharCode(...bytes.subarray(offset, offset + 32768)); return btoa(result); }
export async function sha256(bytes) { return [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(value => value.toString(16).padStart(2, '0')).join(''); }
export function base64url(bytes) { return bytesToBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
export class DurableQueue {
  constructor(writer) { this.writer = writer; this.revision = 0; this.persisted = 0; this.error = ''; this.tail = Promise.resolve(); }
  write(value) { const revision = ++this.revision; this.tail = this.tail.then(async () => { if (this.error) return; try { await this.writer(value); this.persisted = revision; } catch { this.error = 'Browser storage write failed. Paid requests are stopped.'; } }); return revision; }
}
