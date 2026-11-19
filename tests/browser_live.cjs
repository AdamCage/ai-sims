const {chromium}=require(process.env.PW_CORE || 'playwright-core');
const {execFileSync}=require('node:child_process');
const {randomUUID}=require('node:crypto');
const {mkdir,writeFile}=require('node:fs/promises');
const path=require('node:path');
const assert=require('node:assert/strict');
const {clickPrimary, chooseStory}=require('./browser_story_controls.cjs');

async function main(){
  if(!process.argv.includes('--allow-paid')) throw new Error('Explicit --allow-paid is required');
  const root=path.resolve(__dirname,'..');
  const godot=process.env.GODOT_BIN || path.join(process.env.USERPROFILE,'.codex/tools/godot-4.7.2/Godot_v4.7.2-stable_win64_console.exe');
  const ledgerId='browser-test-'+randomUUID();
  function ledger(command,amount){
    const output=execFileSync(godot,['--headless','--path',root,'--script','res://tests/browser_live_ledger.gd','--','--allow-paid',command,ledgerId,String(amount)],{encoding:'utf8',windowsHide:true});
    assert.ok(output.includes('BROWSER TEST LEDGER OK'));
  }
  const readKey=()=>{
    const raw=execFileSync(path.join(root,'assets/release/bin/credential_bridge.exe'),['get'],{encoding:'utf8',windowsHide:true}).trim();
    if(!raw.startsWith('OK:')) throw new Error('Credential store unavailable');
    const value=Buffer.from(raw.slice(3),'base64').toString('utf8');
    if(!value.startsWith('sk-')) throw new Error('Missing local RouterAI credential');
    return value;
  };
  const browser=await chromium.launch({channel:'chrome',headless:true});
  const page=await browser.newPage({viewport:{width:1440,height:946},acceptDownloads:true});
  let claimed=false,reserved=false,settled=false,entryId='',receiptAmount=-1;
  const report={browser:browser.version(),map:'closed_block',requests_sent:0,with_personal_png:false,provider_status:0,applied:false};
  const out=path.join(root,'test-output','live','browser');
  await mkdir(out,{recursive:true});
  try{
    // Seed the in-memory connection from the same local vault as native QA.
    // The callback never stores the credential on disk or in a URL.
    await page.route('**/*.wasm.bin',async route=>{
      const connected=await page.evaluate(value=>AISimsWeb.setKey(value),readKey());
      assert.equal(connected,true);
      await route.continue();
    });
    await page.route('https://routerai.ru/api/v1/chat/completions',async route=>{
      if(claimed){await route.abort();return;}
      claimed=true;
      const request=route.request();
      const payload=request.postDataJSON();
      const state=await page.evaluate(()=>JSON.parse(AISimsWeb.getLedger()));
      const active=Object.values(state.entries).filter(e=>e.state==='reserved' && e.role==='action');
      assert.ok(active.length);
      const entry=active[0], estimate=entry.estimate/1000000;
      // No route is forwarded without its shared native reservation.
      ledger('reserve',estimate);
      reserved=true;entryId=entry.id;
      report.reserved_rub=estimate;
      report.with_personal_png=payload.messages.some(m=>Array.isArray(m.content)&&m.content.some(c=>c.type==='image_url'&&c.image_url.url.startsWith('data:image/png;base64,')));
      assert.ok(report.with_personal_png);
      report.requests_sent=1;
      await route.continue();
    });
    page.on('response',async res=>{
      if(res.url()!=='https://routerai.ru/api/v1/chat/completions')return;
      report.provider_status=res.status();
      try {
        const provider=await res.json();
        const decision=JSON.parse(provider.choices[0].message.content);
        report.proposed_actions=(decision.steps || [decision]).map(a=>a.type).filter(t=>typeof t==='string'&&/^[a-z_]+$/.test(t));
      } catch { /* A rejected provider payload is still recorded in the ledger. */ }
    });
    await page.goto('http://127.0.0.1:8732/');
    await page.waitForFunction(()=>document.querySelector('#boot').hidden,null,{timeout:120000});
    assert.equal(await page.evaluate(()=>JSON.parse(AISimsWeb.getStatus()).connected),true);
    await chooseStory(page,'closed_block');
    await clickPrimary(page,'Begin story');
    // The chapter control starts observation. The route cap applies both to
    // decisions and to any memory jobs for the lifetime of this context.
    await clickPrimary(page,'Start observing');
    await page.waitForFunction(()=>Object.values(JSON.parse(AISimsWeb.getLedger()||'{"entries":{}}').entries).some(e=>e.state==='settled'),null,{timeout:120000});
    const entry=await page.evaluate(id=>JSON.parse(AISimsWeb.getLedger()).entries[id],entryId);
    const actor=entryId.split('/')[0];
    if(entry?.state==='settled')receiptAmount=entry.actual/1000000;
    if(receiptAmount>=0){ledger('settle',receiptAmount);settled=true;}
    // Inspect the actual committed world through its ordinary backup action.
    for(let attempt=0;attempt<4 && !report.applied;attempt++){
      await page.waitForTimeout(800);
      const download=page.waitForEvent('download',{timeout:45000});await page.locator('#backup').click();await download;
      const result=await page.evaluate(id=>{
        const saved=JSON.parse(JSON.parse(AISimsWeb.getSlot('slot_3.json')).payload).data;
        const world=saved.world.world;
        return {action:saved.runtimes[id].last_action?.type,events:world.events.filter(e=>e.actor===id).map(e=>({type:e.type,ok:e.ok}))};
      },actor);
      report.applied=result.events.some(e=>e.ok && e.type!=='session_started');
      report.events=result.events;
    }
    assert.equal(report.provider_status,200);
    assert.ok(report.applied,'No accepted action reached the running browser world');
    report.passed=true;
  }finally{
    await browser.close();
    if(reserved&&!settled)ledger('settle',-1);
    report.confirmed_rub=receiptAmount>=0?receiptAmount:null;
    await writeFile(path.join(out,ledgerId+'.json'),JSON.stringify(report,null,2));
    await writeFile(path.join(out,'result.json'),JSON.stringify(report,null,2));
    console.log(JSON.stringify(report));
  }
}
main().catch(e=>{console.error('Browser acceptance failed:',e.name,String(e.message).replace(/sk-[\w-]+/g,'[redacted]').slice(0,230));process.exitCode=1;});
