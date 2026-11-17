import {DurableQueue, readArchive, makeArchive, referencedImages, base64ToBytes, bytesToBase64, sha256, base64url} from './alpha-core.mjs';

import {installPlaytest} from './playtest.mjs';

const $ = id => document.getElementById(id);
const commands = [], pngJobs = new Map(), pngResults = new Map(), packJobs = new Map();
const commandWaiters = new Map(); let commandId = 0;
let key = '', lease = false, ready = false, db, engine, manifest, pngWorker, pngId = 0, imported = null;
let resolveScene;
let mediaExport = null, mediaRestore = null;
let storageWarning = '';
let renderingFps = 0;
const sceneReady = new Promise(resolve => { resolveScene = resolve; });
let ledgerText = '', slots = {}, storageError = '', authError = '', releaseLock;
let durableSlots = {};
const report = text => { $('boot-message').textContent = text; };
const badge = text => { $('storage-status').textContent = text; };

function openDB() {
  return new Promise((resolve, reject) => { const request = indexedDB.open('ai-sims-alpha', 1); request.onupgradeneeded = () => request.result.createObjectStore('local'); request.onerror = () => reject(new Error('Browser storage unavailable')); request.onsuccess = () => { db = request.result; db.onversionchange = () => { db.close(); storageError = 'Storage changed in another window'; }; resolve(db); }; });
}
function read(name) { return new Promise((resolve, reject) => { const transaction = db.transaction('local', 'readonly'); const request = transaction.objectStore('local').get(name); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(new Error('Storage read failed')); }); }
function write(name, value) { return new Promise((resolve, reject) => { const transaction = db.transaction('local', 'readwrite'); transaction.objectStore('local').put(value, name); transaction.oncomplete = () => resolve(); transaction.onerror = transaction.onabort = () => reject(new Error('Storage write failed')); }); }
const ledgerQueue = new DurableQueue(value => write('ledger', value));
const saveQueue = new DurableQueue(async value => { await write('slots', value); durableSlots = value; });

async function reconcileReceipts() {
  if (!key || !ledgerText) return;
  const ledger = JSON.parse(ledgerText);
  let changed = false;
  const outstanding = Object.values(ledger.entries || {}).filter(entry => ['unknown','reserved'].includes(entry.state));
  // An unavailable provider must never hold local play hostage. Share a
  // deadline between receipt lookups, then keep every unresolved reservation.
  const deadline = AbortSignal.timeout(3000);
  await Promise.all(outstanding.map(async entry => {
    const ref = entry.metadata?.generation_ref || await read('receipt:'+entry.id);
    if (typeof ref !== 'string' || !/^[a-zA-Z0-9_.:-]{3,256}$/.test(ref))return;
    try {
      const url = new URL('https://routerai.ru/api/v1/generation');
      url.searchParams.set('id',ref);
      const response=await fetch(url,{headers:{Authorization:'Bearer '+key},credentials:'omit',signal:deadline});
      if (!response.ok)return;
      const raw=await response.json(), receipt=raw.data || raw, cost=receipt.total_cost;
      if (!['RUB','RUR','₽'].includes(String(receipt.currency || 'RUB').toUpperCase()) || typeof cost!=='number' || !Number.isFinite(cost) || cost<0 || cost>1000000)return;
      entry.state='settled';entry.actual=Math.ceil(cost*1000000);
      entry.metadata={...entry.metadata,generation_ref:ref,cost_source:'RouterAI_generation_receipt'};
      changed=true;
    } catch { /* Missing or expired receipts retain their conservative reserve. */ }
  }));
  if (changed) { const next=JSON.stringify(ledger);await write('ledger',next);ledgerText=next; }
}

async function connectRouter() {
  if (!lease) return;
  commands.push({type: 'pause',autosave:false});
	if (ready) await requestSnapshot();
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32))), state = base64url(crypto.getRandomValues(new Uint8Array(24)));
  sessionStorage.setItem('aisims-pkce', JSON.stringify({verifier, state, created: Date.now(), callback: location.origin + location.pathname}));
  const challenge = base64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
  const url = new URL('https://routerai.ru/auth');
  for (const [name, value] of Object.entries({callback_url: location.origin + location.pathname, code_challenge: challenge, code_challenge_method: 'S256', state, app_name: 'AI Sims', key_label: 'AI Sims browser', limit: '100', limit_period: 'day'})) url.searchParams.set(name, value);
  // Allow autosave / ledger transactions to commit before leaving the page.
  await Promise.all([ledgerQueue.tail, saveQueue.tail]);
  location.assign(url.href);
}
function gameCommand(type, fields={}) {
  const id = ++commandId;
  return new Promise((resolve,reject) => { const timer = setTimeout(() => { commandWaiters.delete(id); reject(new Error('Game command timed out')); }, 30000); commandWaiters.set(id, ok => { clearTimeout(timer); commandWaiters.delete(id); ok ? resolve() : reject(new Error('Game command failed')); }); commands.push({type,id,...fields}); });
}
const requestSnapshot = () => gameCommand('backup');
async function finishRouterLogin() {
  const url = new URL(location.href), code = url.searchParams.get('code'), denied = url.searchParams.get('error');
  if (!code && !denied) return;
  const state = url.searchParams.get('state');
  const stored = sessionStorage.getItem('aisims-pkce'); sessionStorage.removeItem('aisims-pkce');
  for (const name of ['code','state','iss','error','error_description']) url.searchParams.delete(name);
  history.replaceState(null, '', url.pathname + url.search + url.hash);
  if (denied) { authError = 'RouterAI connection was declined'; return; }
  let pending; try { pending = JSON.parse(stored); } catch { /* handled below */ }
  if (!pending || pending.state !== state || Date.now() - pending.created > 300000 || pending.callback !== location.origin + location.pathname) { authError = 'RouterAI sign-in expired. Connect again.'; return; }
  try {
    const response = await fetch('https://routerai.ru/api/v1/auth/keys', {method: 'POST', credentials: 'omit', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({code, code_verifier: pending.verifier, code_challenge_method: 'S256', callback_url: pending.callback}), signal: AbortSignal.timeout(15000)});
    const data = await response.json(); if (!response.ok || typeof data.key !== 'string' || !data.key.startsWith('sk-')) throw new Error(); key = data.key;
  } catch { authError = 'RouterAI connection failed. No model request was sent.'; }
}
function pngStatus() { return pngWorker ? '' : 'PNG worker unavailable'; }
function startPNG(rgbaBase64, width, height) {
  if (!pngWorker || pngJobs.size >= 4 || width * height * 4 > 64 * 1024 * 1024) return -1;
  const id = ++pngId;
  try { const bytes = base64ToBytes(rgbaBase64); pngJobs.set(id, Date.now()); pngWorker.postMessage({id, width, height, rgba: bytes.buffer}, [bytes.buffer]); return id; }
  catch { pngJobs.delete(id); return -1; }
}
function takePNG(id) { if (!pngResults.has(id)) return ''; const result = pngResults.get(id); pngResults.delete(id); return result; }
async function verifiedAsset(asset) {
  if (!asset || !/^[a-f0-9]{64}$/.test(asset.sha256) || typeof asset.file !== 'string' || asset.file.includes('..') || /^\w+:/.test(asset.file)) throw new Error('Invalid content manifest');
  const parts = asset.parts || [asset.file];
  if (!Array.isArray(parts) || !parts.length || !parts.every(path => /^[\w.-]+$/.test(path))) throw new Error('Invalid content path');
  const responses = await Promise.all(parts.map(path => fetch(new URL(path,location.href),{cache:'force-cache'})));
  if (responses.some(part => !part.ok)) throw new Error('Content download failed');
  const response=responses.length===1 ? responses[0] : new Response(new Blob(await Promise.all(responses.map(part=>part.blob()))));
  const content = asset.encoding === 'gzip' ? new Response(response.body.pipeThrough(new DecompressionStream('gzip'))) : response;
  const bytes = await content.arrayBuffer(); if (bytes.byteLength !== asset.bytes || await sha256(bytes) !== asset.sha256) throw new Error('Content checksum failed'); return bytes;
}
async function loadPack(asset, path) { const bytes = await verifiedAsset(asset); engine.copyToFS(path, bytes); return path; }
function startMapPack(mapId) {
  if (packJobs.has(mapId)) return;
  const job = {done: false, error: '', path: ''}; packJobs.set(mapId, job);
  const asset = manifest.maps?.[mapId];
  if (!asset) { job.done = true; return; } // A build may contain all content in the shared pack.
  loadPack(asset, `/packs/${mapId}.pck`).then(path => { job.path = path; job.done = true; }).catch(() => { job.error = 'Map content download failed'; job.done = true; });
}
function packStatus(mapId) { const job = packJobs.get(mapId); return JSON.stringify(job || {done:false,error:'',path:''}); }

window.AISimsWeb = Object.freeze({
  playtestContext: installPlaytest($('feedback'), () => commands.push({type:'pause', autosave:false})),
  isReady: () => ready, hasLease: () => lease, gameReady: () => resolveScene(),
  frameSample: value => { renderingFps = Number(value); },
  renderingFps: () => renderingFps,
  protectedImages: (name, value) => {
    // Include both earlier committed slots and the in-flight generation. A
    // failed save must leave every image from the durable version readable.
    try {
      if (!lease || mediaRestore || mediaExport || storageError || saveQueue.error || !Object.keys(durableSlots).length) return 'null';
      const keep = [...referencedImages(durableSlots), ...referencedImages(slots), ...referencedImages({[name]:value})];
      return JSON.stringify(Object.fromEntries(keep.map(hash => [hash,true])));
    } catch { return 'null'; }
  },
  mediaLimitReached: () => {
    storageWarning = 'Фотоархив достиг 512 МБ. Скачайте копию для переноса в новый профиль.';
    badge(storageWarning);
  },
  getKey: () => key, setKey: value => { if (lease) key = String(value).trim(); return lease; }, clearKey: () => { key = ''; return true; }, connectRouter: () => { $('connect').click(); },
  getStatus: () => JSON.stringify({ready, lease, storage_error: storageError || ledgerQueue.error || saveQueue.error, auth_error: authError, connected: Boolean(key), png_error: pngStatus(), ledger_revision: ledgerQueue.revision, ledger_persisted: ledgerQueue.persisted, save_revision: saveQueue.revision, save_persisted: saveQueue.persisted}),
  pollCommand: () => { resolveScene(); return commands.length ? JSON.stringify(commands.shift()) : ''; },
  completeCommand: (id, ok) => { commandWaiters.get(id)?.(Boolean(ok)); },
  getLedger: () => ledgerText,
  persistLedger: value => { if (!lease || storageError) return -1; ledgerText = String(value); return ledgerQueue.write(ledgerText); },
  getSlot: name => slots[name] || '',
  persistSlot: (name, value) => { if (!lease || !/^slot_[123]\.json$/.test(name)) return -1; slots = {...slots, [name]: String(value)}; return saveQueue.write({...slots}); },
  takeImport: () => { const result = imported; imported = null; return result ? JSON.stringify(result) : ''; },
  acceptImage: (hash,codec) => { if (mediaExport) mediaExport.set(hash,base64ToBytes(codec)); },
  restoreImage: () => mediaRestore && JSON.stringify(mediaRestore),
  requestBackup: () => $('backup').click(),
  requestImport: () => $('import').click(),
  commitImport: text => {
    if (!lease || storageError || saveQueue.error) return false;
    const next = {...slots,...JSON.parse(text)};
    const revision = saveQueue.write(next);
    const previous = slots;
    slots = next;
    saveQueue.tail.then(() => {
      if (saveQueue.persisted >= revision) badge('Сохранения восстановлены');
      else { slots = previous; badge('Не удалось записать копию. Прежние сохранения сохранены'); }
    });
    return true;
  },
  noteReceipt: (reservation, generation) => {
    if (lease && db) write('receipt:'+reservation, generation).catch(() => badge('Не удалось сохранить идентификатор квитанции'));
  },
  startPNG, takePNG, cancelPNG: id => { pngJobs.delete(id); pngResults.delete(id); },
  startMapPack, packStatus,
});

async function boot() {
  if (!window.isSecureContext || !window.WebAssembly || !window.indexedDB || !navigator.locks) throw new Error('Use a current desktop browser over HTTPS. WebAssembly, IndexedDB and Web Locks are required.');
  if (window.Engine.getMissingFeatures({threads:false}).length) throw new Error('WebGL 2 is unavailable. Enable hardware acceleration or use another browser.');
  // Hold this lock for the entire engine lifetime. Never steal a live lease.
  let lockDecision;
  const acquired = new Promise(resolve => { lockDecision = resolve; });
  void navigator.locks.request('ai-sims-alpha-single-writer', {ifAvailable:true}, async lock => { if (!lock) { lockDecision(false); return; } lease = true; lockDecision(true); await new Promise(resolve => { releaseLock = resolve; }); lease = false; });
  if (!await acquired) throw new Error('AI Sims is already open in another tab. Return to that tab or close it before continuing.');
  const channel = typeof BroadcastChannel === 'function' ? new BroadcastChannel('ai-sims-alpha') : null;
  if (channel) channel.onmessage = ({data}) => { if (data === 'focus') window.focus(); };
  report('Проверяем локальные сохранения…');
  await openDB();
  ledgerText = await read('ledger') || ''; slots = await read('slots') || {}; durableSlots = slots;
  // A committed probe verifies that IndexedDB is actually writable, not just present.
  await write('probe', Date.now());
  if (navigator.storage?.persist) void navigator.storage.persist().catch(() => false);
  if (navigator.storage?.estimate) navigator.storage.estimate().then(value => { if ((value.quota || 0) - (value.usage || 0) < 32 * 1024 * 1024) { storageWarning='Мало места · сделайте копию'; badge(storageWarning); } }).catch(() => {});
  await finishRouterLogin();
  await reconcileReceipts();
  pngWorker = new Worker(new URL('./png-worker.mjs', import.meta.url), {type:'module'});
  pngWorker.onmessage = ({data}) => { if (!pngJobs.has(data.id)) return; pngJobs.delete(data.id); pngResults.set(data.id, data.error ? JSON.stringify({error:'PNG encoding failed'}) : JSON.stringify({png:bytesToBase64(new Uint8Array(data.png))})); };
  pngWorker.onerror = () => { for (const id of pngJobs.keys()) pngResults.set(id, JSON.stringify({error:'PNG worker failed'})); pngJobs.clear(); pngWorker = null; };
  manifest = await (await fetch(new URL('./content-manifest.json', location.href), {cache:'no-cache'})).json();
  if (manifest.schema !== 1 || !manifest.core) throw new Error('Unsupported content manifest');
  engine = new window.Engine({...window.AI_SIMS_ENGINE_CONFIG, canvas:$('canvas'), focusCanvas:true, onProgress:(loaded,total) => { if (total) { $('boot-progress').value = loaded / total; report(`Загружаем мир… ${Math.round(loaded / total * 100)}%`); } }, onPrint:message => console.info(String(message)), onPrintError:message => { console.error(String(message)); if (/indexeddb|quota|persist.*fail|fs.*sync.*fail/i.test(String(message))) storageError = 'Local storage failed. Export a backup before closing.'; }});
  const canvas = $('canvas');
  const resize = () => {
    const box = canvas.parentElement.getBoundingClientRect();
    canvas.width = Math.max(1,Math.round(box.width));
    canvas.height = Math.max(1,Math.round(box.height));
  };
  resize();
  new ResizeObserver(resize).observe(canvas.parentElement);
  report('Загружаем движок…');
  await engine.init(window.AI_SIMS_ENGINE_CONFIG.executable);
  await loadPack(manifest.core, '/packs/core.pck');
  if (manifest.shared) { report('Загружаем персонажей и материалы…'); await loadPack(manifest.shared, '/packs/shared.pck'); }
  ready = true;
  await engine.start({args:['--main-pack','/packs/core.pck'], canvas:$('canvas')});
  report('Открываем первую историю…');
  await Promise.race([sceneReady, new Promise((_, reject) => setTimeout(() => reject(new Error('Не удалось открыть игровой мир. Попробуйте перезапустить игру.')), 120000))]);
  $('boot').hidden = true; $('toolbar').hidden = false;
  $('connect').textContent = key ? 'RouterAI подключён' : 'Подключить RouterAI';
  badge(authError || storageWarning || 'Сохранения на этом устройстве');
  setInterval(() => { const error = storageError || ledgerQueue.error || saveQueue.error; if (error) badge('Ошибка сохранения · сделайте копию'); }, 1000);
}

$('connect').onclick = () => { void connectRouter().catch(() => badge('Не удалось сохранить игру перед подключением')); };
$('backup').onclick = async () => {
  $('backup').disabled = true;
  try {
    await requestSnapshot(); await saveQueue.tail;
    if (saveQueue.error) throw new Error();
    mediaExport = new Map();
    const snapshot={...slots};
    for(const hash of referencedImages(snapshot))await gameCommand('export_image',{hash});
    const archive = makeArchive(snapshot,mediaExport), link = document.createElement('a');
    link.href = URL.createObjectURL(archive); link.download = 'AI-Sims.aisims'; link.click();
    setTimeout(() => URL.revokeObjectURL(link.href),10000);
    badge('Сохранения и фотографии скачаны');
  } catch { badge('Не удалось создать полную копию. Проверьте свободное место и повторите'); }
  finally { mediaExport = null; $('backup').disabled = false; }
};
$('import').onclick = () => { commands.push({type:'pause',autosave:false}); $('import-file').click(); };
$('import-file').onchange = async event => {
  try {
    const file=event.target.files[0]; if (!file)return;
    const archive=await readArchive(file);
    for (const [hash,part] of archive.images) {
      const bytes=new Uint8Array(await part.arrayBuffer());
      if(await sha256(bytes)!==hash)throw new Error('Image checksum mismatch');
      mediaRestore={hash,data:bytesToBase64(bytes)};
      await gameCommand('import_image');
    }
    mediaRestore=null;imported=archive.slots;
    await gameCommand('import');await saveQueue.tail;
    if(saveQueue.error)throw new Error();
    badge(archive.missingImages.length ? 'Выберите слот. В старой копии отсутствуют фотографии.' : 'Копия восстановлена. Выберите слот');
  } catch { badge('Не удалось восстановить копию. Проверьте файл'); }
  finally { mediaRestore=null;event.target.value=''; }
};
$('fullscreen').onclick = () => { if (document.fullscreenElement) void document.exitFullscreen(); else void document.documentElement.requestFullscreen?.(); };
document.addEventListener('visibilitychange', () => { if (document.hidden && ready) commands.push({type:'pause'}); });
window.addEventListener('pagehide', () => { key = ''; commands.push({type:'pause'}); });
boot().catch(error => { report(error.message || 'Не удалось запустить игру'); $('boot-retry').hidden = false; badge('Игра не запущена'); });
$('boot-retry').onclick = () => location.reload();
