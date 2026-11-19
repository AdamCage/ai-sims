// Run against an exported, locally served release with a clean browser context.
// PW_CORE may point to an existing Playwright Core installation.
const {chromium,firefox}=require(process.env.PW_CORE || 'playwright-core');
const {readFile,writeFile,mkdir}=require('node:fs/promises');
const {createHash}=require('node:crypto');
const assert=require('node:assert/strict');
const path=require('node:path');
const {clickPrimary, chooseStory, startReplay, ui}=require('./browser_story_controls.cjs');
const name=process.env.BROWSER || 'chrome';
const base=process.env.BETA_URL || 'http://127.0.0.1:8732/';
const dir=process.env.BETA_REPORT || 'test-output/beta-browser';

async function run(){
  await mkdir(dir,{recursive:true});
  const browser=name==='firefox'?await firefox.launch({headless:true}):await chromium.launch({channel:name,headless:true,args:['--enable-unsafe-swiftshader']});
  const report={browser:name,version:browser.version(),scenarios:[],errors:[],url:base};
  function collectErrors(page){
    page.on('console',message=>{if(message.type()==='error')report.errors.push(message.text().slice(0,240));});
    page.on('pageerror',error=>report.errors.push(error.message));
    page.on('response',response=>{
      if(response.status()>=400)report.errors.push('HTTP '+response.status()+' '+new URL(response.url()).pathname);
    });
  }
  const options={viewport:{width:1440,height:946},acceptDownloads:true};
  const context=await browser.newContext(options);
  try {
    const page=await context.newPage();
    collectErrors(page);
    const start=Date.now();
    await page.goto(base);
    await page.waitForFunction(()=>document.querySelector('#boot').hidden,null,{timeout:120000});
    report.cold_start_ms=Date.now()-start;
    report.renderer=await page.evaluate(()=>{
      const gl=document.querySelector('canvas').getContext('webgl2');
      return gl.getParameter(gl.getExtension('WEBGL_debug_renderer_info').UNMASKED_RENDERER_WEBGL);
    });
    console.log('boot',name,report.cold_start_ms,report.renderer);
    const second=await context.newPage();await second.goto(base);
    await second.waitForFunction(()=>!document.querySelector('#boot-retry').hidden);
    assert.match(await second.locator('#boot-message').innerText(),/already open|вкладке/i);
    assert.equal(await second.evaluate(()=>window.AISimsWeb.hasLease()),false);
    await second.close();await page.bringToFront();report.second_tab_blocked=true;
    let latest;
    const ids=(process.env.BETA_MAPS || 'closed_block,residence,research_station').split(',');
    for(const [index,id] of ids.entries()){
      if(index>0){await page.mouse.click(...ui.menu);await page.waitForTimeout(500);}
      await chooseStory(page,id);
      await page.waitForTimeout(500);
      if (process.env.BETA_COUNT) {
        await page.mouse.dblclick(...ui.count);await page.keyboard.press('Control+a');await page.keyboard.type(process.env.BETA_COUNT);await page.keyboard.press('Enter');
      }
      await clickPrimary(page, 'Begin story');
      await page.waitForTimeout(550);
      await clickPrimary(page, 'Start observing');
      if(process.env.BETA_FULL_HD)await page.setViewportSize({width:1920,height:1126});
      await page.waitForTimeout(Number(process.env.BETA_WARMUP_MS || 0));
      const metrics=await page.evaluate(async duration=>{
        const deltas=[],engine=[];const start=performance.now();let previous=start,nextSample=start;
        await new Promise(resolve=>requestAnimationFrame(function sample(now){
          deltas.push(now-previous);previous=now;
          if(now>=nextSample && window.AISimsWeb.renderingFps){engine.push(window.AISimsWeb.renderingFps());nextSample=now+1000;}
          if(now-start<duration)requestAnimationFrame(sample);else resolve();
        }));
        const canvas=document.querySelector('canvas');
        return {canvas:[canvas.width,canvas.height],animation_fps:Math.round(deltas.length*1000/(previous-start)),duration_ms:Math.round(previous-start),engine_fps:engine};
      },Number(process.env.BETA_SAMPLE_MS || 8000));
      if(process.env.BETA_FULL_HD){await page.setViewportSize(options.viewport);await page.waitForTimeout(250);}
      await page.mouse.click(...ui.pause);
      await page.screenshot({path:path.join(dir,name+'-'+id+'.png')});
      const downloaded=page.waitForEvent('download',{timeout:120000});
      await page.locator('#backup').click();
      const file=await downloaded;latest=path.join(dir,name+'-copy.aisims');await file.saveAs(latest);
      const bytes=await readFile(latest);assert.equal(bytes.subarray(0,4).toString(),'AIS2');
      const manifest=JSON.parse(bytes.subarray(8,8+bytes.readUInt32BE(4)).toString());
      const envelope=JSON.parse(JSON.parse(manifest.slots['slot_3.json']).payload);
      const world=envelope.data.world.world;
      assert.equal(world.map_id,id);assert.ok(world.elapsed_minutes>0,'Simulation clock advanced by clicking Continue');
      if(process.env.BETA_COUNT)assert.equal(Object.keys(world.agents).length,Number(process.env.BETA_COUNT));
      const summary={map:id,actors:Object.keys(world.agents).length,elapsed_game_minutes:world.elapsed_minutes,...metrics,events:world.events.length,backup_bytes:bytes.length,images:manifest.media.length};
      report.scenarios.push(summary);console.log('episode',summary);
    }
    await page.reload();await page.waitForFunction(()=>document.querySelector('#boot').hidden,null,{timeout:120000});
    assert.equal(await page.evaluate(()=>JSON.parse(JSON.parse(window.AISimsWeb.getSlot('slot_3.json')).payload).data.world.world.map_id),ids.at(-1));
    report.reload_preserved=true;
    await context.close();
    const clean=await browser.newContext(options);const target=await clean.newPage();collectErrors(target);
    await target.goto(base);await target.waitForFunction(()=>document.querySelector('#boot').hidden,null,{timeout:120000});
    assert.equal(await target.evaluate(()=>window.AISimsWeb.getSlot('slot_3.json')),'');
    await target.locator('#import-file').setInputFiles(latest);
    await target.waitForFunction(()=>document.querySelector('#storage-status').textContent.includes('Выберите слот'),null,{timeout:120000});
    assert.equal(await target.evaluate(()=>JSON.parse(JSON.parse(window.AISimsWeb.getSlot('slot_3.json')).payload).data.world.world.map_id),ids.at(-1));
    report.fresh_profile_import=true;
    const before=await target.evaluate(()=>window.AISimsWeb.getSlot('slot_3.json'));
    const corrupt=JSON.stringify({schema:2,data:{world:{},runtimes:{}}});
    const rejected=JSON.stringify({schema:'ai-sims-local-backup-v1',slots:{'slot_1.json':before,'slot_3.json':JSON.stringify({payload:corrupt,sha256:createHash('sha256').update(corrupt).digest('hex')})}});
    await target.locator('#import-file').setInputFiles({name:'invalid-world.json',mimeType:'application/json',buffer:Buffer.from(rejected)});
    await target.waitForFunction(()=>document.querySelector('#storage-status').textContent.includes('Не удалось восстановить'));
    assert.equal(await target.evaluate(()=>window.AISimsWeb.getSlot('slot_1.json')),'');
    await target.locator('#import-file').setInputFiles({name:'bad.aisims',mimeType:'application/octet-stream',buffer:Buffer.from('broken')});
    await target.waitForFunction(()=>document.querySelector('#storage-status').textContent.includes('Не удалось восстановить'));
    assert.equal(await target.evaluate(()=>window.AISimsWeb.getSlot('slot_3.json')),before);
    report.invalid_import_preserved=true;
    const expected=JSON.parse(JSON.parse(before).payload).data;
    await target.reload();await target.waitForFunction(()=>document.querySelector('#boot').hidden,null,{timeout:120000});
    await target.mouse.click(...ui.resume);
    await target.waitForTimeout(1800);
    const recopy=Promise.race([
      target.waitForEvent('download',{timeout:60000}),
      target.waitForFunction(()=>document.querySelector('#storage-status').textContent.includes('Не удалось создать'),null,{timeout:60000}).then(()=>{throw new Error('Game could not read durable photographs after reload');})
    ]);
    await target.locator('#backup').click();
    const restoredPath=path.join(dir,name+'-restored.aisims');
    await (await recopy).saveAs(restoredPath);
    const copied=await readFile(restoredPath);
    const restored=JSON.parse(copied.subarray(8,8+copied.readUInt32BE(4)).toString());
    const actual=JSON.parse(JSON.parse(restored.slots['slot_3.json']).payload).data;
    const original=await readFile(latest);
    const originalManifest=JSON.parse(original.subarray(8,8+original.readUInt32BE(4)).toString());
    assert.deepEqual(restored.media.map(image=>image.hash).sort(),originalManifest.media.map(image=>image.hash).sort());
    report.photos_survived_reload=true;
    assert.ok(actual.world.world.run_id>expected.world.world.run_id,'Loaded into live game with a new generation');
    assert.equal(actual.world.world.map_id,expected.world.world.map_id);
    assert.equal(actual.world.world.tick,expected.world.world.tick);
    assert.ok(actual.replay.sequence>=expected.replay.sequence);
    report.loaded_into_live_world=true;
    await target.mouse.click(...ui.closeChapter);
    await startReplay(target);
    report.replay_restored_clock=true;
    await target.waitForTimeout(650);
    await target.screenshot({path:path.join(dir,name+'-replay.png')});
    await target.evaluate(()=>{
      const put=IDBObjectStore.prototype.put;
      IDBObjectStore.prototype.put=function(value,key){
        if(key==='slots')throw new DOMException('Synthetic full disk','QuotaExceededError');
        return put.call(this,value,key);
      };
    });
    const rescued=target.waitForEvent('download',{timeout:60000});
    await target.locator('#backup').click();
    assert.equal((await rescued).suggestedFilename(),'AI-Sims.aisims');
    assert.ok(await target.evaluate(()=>JSON.parse(AISimsWeb.getStatus()).storage_error));
    report.full_storage_rescue_copy=true;
    await clean.close();assert.deepEqual(report.errors,[]);report.passed=true;
  } finally {
    await writeFile(path.join(dir,name+'.json'),JSON.stringify(report,null,2));
    await browser.close();
  }
}
run().catch(error=>{console.error(error);process.exitCode=1;});
