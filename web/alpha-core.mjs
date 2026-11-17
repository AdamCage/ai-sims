export const BACKUP_SCHEMA = 'ai-sims-local-backup-v1';
// Three individually bounded 32 MiB slot envelopes plus JSON quoting.
export const MAX_BACKUP_BYTES = 128 * 1024 * 1024;
function archiveFailure(code) {
  return Object.assign(new Error('Invalid or unreadable backup'), {archiveCode:code});
}

function readJSON(text, code) {
  try { return JSON.parse(text); }
  catch { throw archiveFailure(code); }
}

export function parseBackup(text) {
  if (typeof text !== 'string' || new TextEncoder().encode(text).length > MAX_BACKUP_BYTES) throw new Error('Backup is too large');
  const raw = readJSON(text,'legacy_json');
  if (!raw || raw.schema !== BACKUP_SCHEMA) throw new Error('Unsupported save format');
  return validateSlots(raw.slots);
}

function validateSlots(rawSlots) {
  if (!rawSlots || Array.isArray(rawSlots) || typeof rawSlots !== 'object') throw new Error('Unsupported save format');
  const slots = {};
  for (const [name, content] of Object.entries(rawSlots)) {
    if (!/^slot_[123]\.json$/.test(name) || typeof content !== 'string' || content.length>32*1024*1024) throw new Error('Invalid save slot');
    const wrapper = readJSON(content,'slot_wrapper_json'); if (!wrapper || typeof wrapper.payload !== 'string' || !/^[a-f0-9]{64}$/.test(wrapper.sha256)) throw new Error('Invalid save envelope');
    const envelope = readJSON(wrapper.payload,'slot_payload_json'); if (!envelope || envelope.schema !== 2 || !envelope.data || typeof envelope.data !== 'object') throw new Error('Invalid save data');
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

async function readBytes(blob, stage, preferReader = false) {
  const nativeReader = () => new Promise((resolve,reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.onabort = () => reject(new DOMException('Aborted','AbortError'));
    reader.readAsArrayBuffer(blob);
  });
  const methods = typeof FileReader === 'function'
    ? (preferReader ? [nativeReader, () => blob.arrayBuffer()] : [() => blob.arrayBuffer(), nativeReader])
    : [() => blob.arrayBuffer()];
  for (const read of methods) {
    try {
      const buffer = await read();
      if (buffer.byteLength !== blob.size) throw archiveFailure(stage+'_truncated');
      return new Uint8Array(buffer);
    } catch (error) {
      if (read === methods[methods.length-1]) {
        if (error.archiveCode) throw error;
        const family = {NotReadableError:'unreadable',NotFoundError:'missing',SecurityError:'access',AbortError:'aborted'};
        throw archiveFailure(stage+'_'+(family[error.name] || 'read'));
      }
    }
  }
}

async function readText(blob, stage) {
  const bytes = await readBytes(blob,stage);
  try { return new TextDecoder('utf-8',{fatal:true}).decode(bytes); }
  catch { throw archiveFailure(stage+'_encoding'); }
}

export async function readArchive(selected) {
  // Read an ordinary disk-backed selection directly while its file grant is
  // active. All later slices are immutable memory blobs, including photos
  // restored after the manifest. Large archives still use bounded ranges.
  const smallSelection = typeof File !== 'undefined' && selected instanceof File && selected.size <= 8*1024*1024;
  const file = smallSelection ? new Blob([await readBytes(selected,'selected_file',true)]) : selected;
  const prefix = await readBytes(file.slice(0,8),'header');
  let slots, images = new Map(), missingImages = [];
  if (prefix.length < 8 || String.fromCharCode(...prefix.slice(0,4)) !== 'AIS2') {
    if (file.size > MAX_BACKUP_BYTES) throw new Error('Invalid legacy save size');
    slots = parseBackup(await readText(file,'legacy'));
    missingImages = referencedImages(slots);
  } else {
    const size = new DataView(prefix.buffer).getUint32(4);
    if (size > MAX_BACKUP_BYTES || size+8 > file.size) throw new Error('Invalid archive header');
    const manifest = readJSON(await readText(file.slice(8,8+size),'manifest'),'manifest_json');
    if (!manifest || manifest.schema !== 'ai-sims-backup-v2' || !Array.isArray(manifest.media)) throw new Error('Invalid archive');
    slots = validateSlots(manifest.slots);
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
    let actual;
    try { actual = await sha256(new TextEncoder().encode(payload)); }
    catch { throw archiveFailure('slot_digest_unavailable'); }
    if (actual!==hash) throw new Error('Invalid save checksum');
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
