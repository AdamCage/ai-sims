import {readFile,writeFile,rename,unlink,stat} from 'node:fs/promises';
import {join,basename} from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {fileURLToPath} from 'node:url';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
export function readPack(bytes) {
  if (bytes.readUInt32LE(0) !== 0x43504447) throw new Error('Invalid PCK');
  const version=bytes.readUInt32LE(4), flags=bytes.readUInt32LE(20);
  // Godot 4.7 emits PACK_REL_FILEBASE for standalone PCKs. Offsets are
  // relative to the pack start, which is zero in this standalone file.
  if (![2,3,4].includes(version) || (flags & ~2)!==0) throw new Error('Unsupported/encrypted PCK');
  const fileBase=Number(bytes.readBigUInt64LE(24)); let p=version>=3?Number(bytes.readBigUInt64LE(32)):96;
  const count=bytes.readUInt32LE(p); p+=4; const files=[];
  for(let i=0;i<count;i++) { const length=bytes.readUInt32LE(p);p+=4; if(length<1 || length>32768)throw new Error('Invalid PCK path'); const name=bytes.subarray(p,p+length).toString('utf8').replace(/\0+$/,'').replace(/^res:\/\//,'');p+=length; const offset=Number(bytes.readBigUInt64LE(p))+fileBase;p+=8;const size=Number(bytes.readBigUInt64LE(p));p+=8; const md5=bytes.subarray(p,p+16);p+=16;const flags=bytes.readUInt32LE(p);p+=4;
    if(flags || offset+size>bytes.length || name.includes('..') || name.startsWith('/') || name.includes('\\'))throw new Error('Unsafe PCK entry');
    if (/(^|\/)(\.env|\.git|tests|tools|docs|build|test-output)(\/|$)|credential_bridge|\.(key|pem|pfx|log)$/.test(name)) throw new Error(`Private/development entry: ${name}`);
    files.push({name,data:bytes.subarray(offset,offset+size),md5}); }
  return files;
}
export function makePack(files) {
  const entries=files.map(file=>({...file,path:Buffer.from(file.name+'\0')}));let size=100;
  for(const entry of entries){entry.padded=(entry.path.length+3)&~3;size+=40+entry.padded;}let offset=(size+31)&~31;
  for(const entry of entries){entry.offset=offset;offset=(offset+entry.data.length+31)&~31;}
  const bytes=Buffer.alloc(offset); bytes.writeUInt32LE(0x43504447,0);bytes.writeUInt32LE(2,4);bytes.writeUInt32LE(4,8);bytes.writeUInt32LE(7,12);bytes.writeUInt32LE(2,16);bytes.writeUInt32LE(entries.length,96);let p=100;
  for(const entry of entries){bytes.writeUInt32LE(entry.padded,p);p+=4;entry.path.copy(bytes,p);p+=entry.padded;bytes.writeBigUInt64LE(BigInt(entry.offset),p);p+=8;bytes.writeBigUInt64LE(BigInt(entry.data.length),p);p+=8;(entry.md5||createHash('md5').update(entry.data).digest()).copy(bytes,p);p+=16;bytes.writeUInt32LE(0,p);p+=4;entry.data.copy(bytes,entry.offset);}return bytes;
}
async function build(packPath,out,mapDirectory,version='0.3.0-alpha') {
  const files=readPack(await readFile(packPath)); const groups={core:[],shared:[],closed_block:[],residence:[],research_station:[]}; const mapped=new Map();
  for(const file of files){const match=file.name.match(/^assets\/alpha\/maps\/(closed_block|residence|research_station)\//);if(match && /\.(import|remap)$/.test(file.name))for(const found of file.data.toString('utf8').matchAll(/path(?:\.[\w]+)?="res:\/\/([^"\r\n]+)"/g))mapped.set(found[1],match[1]);}
  for(const file of files){let group=mapped.get(file.name);const match=file.name.match(/^assets\/alpha\/maps\/(closed_block|residence|research_station)\//);if(match)group=match[1];if(!group)group=/^(\.godot\/imported\/|assets\/release\/(characters|props|textures|audio)\/|assets\/alpha\/)/.test(file.name)?'shared':'core';groups[group].push(file);}
  const manifest={schema:1,version,engine:'4.7.2',threaded:false,maps:{},created_utc:new Date().toISOString()};
  for(const id of ['closed_block','residence','research_station'])groups[id].push({name:`web_maps/${id}.json`,data:await readFile(join(mapDirectory,id+'.json'))});
  for(const [id,entries] of Object.entries(groups)){
    const bytes=makePack(entries), packed=gzipSync(bytes,{level:9}), file=`${id}-${digest(packed).slice(0,16)}.pck.bin`;
    const descriptor={file,bytes:bytes.length,compressed_bytes:packed.length,encoding:'gzip',sha256:digest(bytes),entries:entries.length};
    if(packed.length>8*1024*1024){
      descriptor.parts=[];
      for(let start=0;start<packed.length;start+=8*1024*1024){
        const part=packed.subarray(start,start+8*1024*1024);
        const partFile=id+'-'+digest(part).slice(0,16)+'.part.bin';
        await writeFile(join(out,partFile),part);descriptor.parts.push(partFile);
      }
    }else await writeFile(join(out,file),packed);
    if(id==='core'||id==='shared')manifest[id]=descriptor;else manifest.maps[id]=descriptor;
  }
  const wasmPath=join(out,'index.wasm'),wasm=await readFile(wasmPath), packedWasm=gzipSync(wasm,{level:9});
  const loader=await readFile(join(out,'index.js'),'utf8');
  const original='preloader.loadPromise(`${loadPath}.wasm`, size, true)';
  if(!loader.includes(original))throw new Error('Unexpected Godot Web loader: review WASM loading before upgrading templates');
  // All hosts can serve these as ordinary binary files. Streaming decompression
  // in the browser also supports static CDNs with a 25 MiB per-file limit.
  const fsSyncGuard='if(GodotFS._syncing){GodotRuntime.error("Already syncing!");return Promise.resolve()}GodotFS._syncing=true;return new Promise(';
  const fsExports='Module["initFS"]=GodotFS.init;';
  if(!loader.includes(fsSyncGuard) || !loader.includes(fsExports))throw new Error('Unexpected Godot IDBFS implementation: review durable save synchronization');
  const presentFrame='GL.blitOffscreenFramebuffer(GL.currentContext);return 0';
  if(loader.split(presentFrame).length!==2)throw new Error('Review WebGL frame presentation for this export template');
  const webkitFrame='const presenter=GL.currentContext.GLctx.canvas.presentGodotFrame;if(!presenter||!presenter(GL.currentContext)){GL.blitOffscreenFramebuffer(GL.currentContext)}return 0';
  // Serialize native automatic syncs and the web slot transaction. A previous
  // pass may already have enumerated its files before the newest photo existed.
  const compressedLoader=loader
    .replace(presentFrame,webkitFrame)
    .replace(original,'preloader.loadPromise(`${loadPath}.wasm.bin`, size, true).then(response => new Response(response.body.pipeThrough(new DecompressionStream("gzip")), {headers:{"Content-Type":"application/wasm"}}))')
    .replace(fsSyncGuard,'if(GodotFS._syncing){return GodotFS._pending.then(error=>error||GodotFS.sync())}GodotFS._syncing=true;return GodotFS._pending=new Promise(')
    .replace(fsExports,fsExports+'Module["flushUserFiles"]=async function(){if(!GodotFS.is_persistent())throw new Error("Local media storage unavailable");const error=await GodotFS.sync();if(error)throw error;};');
  const engineName='engine-'+digest(Buffer.concat([packedWasm,Buffer.from(compressedLoader)])).slice(0,16);
  await writeFile(join(out,engineName+'.js'),compressedLoader);
  await writeFile(join(out,engineName+'.wasm.bin'),packedWasm);
  await unlink(wasmPath);await unlink(join(out,'index.js'));
  for(const suffix of ['.audio.worklet.js','.audio.position.worklet.js']){try{await rename(join(out,'index'+suffix),join(out,engineName+suffix));}catch(error){if(error.code!=='ENOENT')throw error;}}
  let html=await readFile(join(out,'index.html'),'utf8');html=html.replaceAll('index.js',engineName+'.js').replaceAll('"executable":"index"','"executable":"'+engineName+'"');
  await writeFile(join(out,'index.html'),html); await unlink(packPath);
  manifest.runtime={file:engineName+'.wasm.bin',bytes:wasm.length,compressed_bytes:packedWasm.length,encoding:'gzip',sha256:digest(wasm)};
  await writeFile(join(out,'content-manifest.json'),JSON.stringify(manifest,null,2));
  console.log(JSON.stringify({core:manifest.core.bytes,shared:manifest.shared.bytes,maps:Object.fromEntries(Object.entries(manifest.maps).map(([id,value])=>[id,value.bytes])),wasm:wasm.length}));
}
if(process.argv[1]===fileURLToPath(import.meta.url))await build(...process.argv.slice(2));
