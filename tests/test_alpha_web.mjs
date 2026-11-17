import assert from 'node:assert/strict';
import {inflateSync} from 'node:zlib';
import {createHash,webcrypto} from 'node:crypto';
import {Worker} from 'node:worker_threads';
import {encodePNG,crc32} from '../web/png-codec.mjs';
import {DurableQueue,makeBackup,parseBackup,makeArchive,readArchive,sha256,base64ToBytes,bytesToBase64} from '../web/alpha-core.mjs';
import {makePack,readPack} from '../tools/build_web_pack.mjs';

let checks=0;
function check(value,label){assert.ok(value,label);checks++;console.log('PASS WEB: '+label);}
function decode(png){assert.deepEqual([...png.subarray(0,8)],[137,80,78,71,13,10,26,10]);const source=Buffer.from(png);let p=8,width,height,compressed=[];while(p<source.length){const size=source.readUInt32BE(p),type=source.subarray(p+4,p+8).toString();check(source.readUInt32BE(p+8+size)===crc32(source.subarray(p+4,p+8+size)),'PNG CRC '+type);if(type==='IHDR'){width=source.readUInt32BE(p+8);height=source.readUInt32BE(p+12);}if(type==='IDAT')compressed.push(source.subarray(p+8,p+8+size));p+=size+12;}const raw=inflateSync(Buffer.concat(compressed)),rgba=Buffer.alloc(width*height*4);for(let y=0;y<height;y++){assert.equal(raw[y*(width*4+1)],0);raw.copy(rgba,y*width*4,y*(width*4+1)+1,(y+1)*(width*4+1));}return{width,height,rgba};}
const pixels=new Uint8Array([255,0,0,255, 0,255,0,127, 0,0,255,1, 42,13,99,0, 255,255,255,255, 0,0,0,255]);
for(const compress of [true,false]){const png=await encodePNG(pixels,3,2,{compress});const decoded=decode(png);check(decoded.width===3&&decoded.height===2,'asymmetric dimensions preserved');check(Buffer.from(pixels).equals(decoded.rgba),'all RGBA bytes including transparent colour preserved without flip');}
await assert.rejects(()=>encodePNG(new Uint8Array(8),2,2));checks++;
const original=new Uint8Array(640*360*4);for(let i=0;i<original.length;i++)original[i]=(i*131+(i>>>12))&255;
const workerURL=new URL('../web/png-worker.mjs',import.meta.url).href;
const worker=new Worker(`const {parentPort}=require('node:worker_threads');global.self={postMessage:(value,transfer)=>parentPort.postMessage(value,transfer)};import(${JSON.stringify(workerURL)}).then(()=>parentPort.on('message',data=>self.onmessage({data})));`,{eval:true});
const copy=original.slice();const workerResult=new Promise((resolve,reject)=>{worker.once('message',resolve);worker.once('error',reject);});worker.postMessage({id:1,width:640,height:360,rgba:copy.buffer},[copy.buffer]);original.fill(7);const result=await workerResult;check(result.id===1&&!result.error,'real worker returns PNG result');const decoded=decode(new Uint8Array(result.png));check(decoded.rgba[0]===0&&decoded.rgba[100]===((100*131)&255),'worker owns private snapshot despite caller mutation');await worker.terminate();
check(Buffer.from(base64ToBytes(bytesToBase64(pixels))).equals(Buffer.from(pixels)),'bulk browser bridge base64 keeps exact RGBA bytes');
let allowCommit;const store=[];const queue=new DurableQueue(async value=>{await new Promise(resolve=>{allowCommit=resolve;});store.push(value);});
const revision=queue.write('reserved-before-network');await Promise.resolve();check(queue.persisted<revision,'pending IndexedDB reservation cannot dispatch paid request');allowCommit();await queue.tail;check(queue.persisted===revision&&store[0]==='reserved-before-network','dispatch becomes eligible only after durable commit');
let writes=0;const broken=new DurableQueue(async()=>{writes++;throw new Error('quota');});broken.write('first');broken.write('second');await broken.tail;check(Boolean(broken.error)&&broken.persisted===0&&writes===1,'storage failure fails closed and blocks subsequent commits');
const payload=JSON.stringify({schema:2,data:{world:{tick:55}}});const wrapper=JSON.stringify({payload,sha256:createHash('sha256').update(payload).digest('hex')});const backup=makeBackup({'slot_1.json':wrapper});check(parseBackup(backup)['slot_1.json']===wrapper,'portable save backup roundtrips');assert.throws(()=>parseBackup(makeBackup({'ledger.json':'money'})));checks++;assert.throws(()=>parseBackup(backup.replace('tick','sk-secret_credential_12345')));checks++;
const entries=[{name:'project.binary',data:Buffer.from('core')},{name:'web_maps/residence.json',data:Buffer.from('{"geometry":{}}')}];const pack=makePack(entries);const restored=readPack(pack);check(restored.length===2&&restored[1].data.equals(entries[1].data),'generated split PCK directory and bytes roundtrip');assert.throws(()=>readPack(makePack([{name:'.env',data:Buffer.from('private')}])));checks++;
const photo=await encodePNG(pixels,3,2),photoHash=await sha256(photo);
const story=JSON.stringify({schema:2,data:{memory:{image_ref:photoHash}}});
const save={'slot_3.json':JSON.stringify({payload:story,sha256:await sha256(new TextEncoder().encode(story))})};
const archive=makeArchive(save,new Map([[photoHash,photo]])),read=await readArchive(archive);
check(read.slots['slot_3.json']===save['slot_3.json'] && await sha256(await read.images.get(photoHash).arrayBuffer())===photoHash,'binary copy restores the exact immutable photograph and its save');
assert.throws(()=>makeArchive(save,new Map()));checks++;
await assert.rejects(()=>readArchive(archive.slice(0,-1)));checks++;
const older=await readArchive(new Blob([makeBackup(save)]));
check(older.missingImages.includes(photoHash),'legacy saves identify unavailable images to the player');
const alternate=Buffer.from(pack);alternate.writeUInt32LE(2,20);
check(readPack(alternate).length===2,'official relative filebase flag does not break a standalone Web export');
console.log(`ALPHA WEB RESULT: ${checks} checks; 0 failures`);
