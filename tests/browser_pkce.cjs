// Exercises the deployed PKCE redirect in a disposable desktop browser.
// All provider traffic is fulfilled locally, including the Godot HTTPRequest
// path for a real PNG observation, quote, completion and its billed receipt.
const assert = require('node:assert/strict');
const {createHash, randomUUID} = require('node:crypto');
const {chromium} = require(process.env.PW_CORE || 'playwright-core');

async function run() {
  const base = process.env.BETA_URL || 'http://127.0.0.1:8732/';
  const browser = await chromium.launch({channel:'chrome', headless:true});
  try {
    const page = await browser.newPage({viewport:{width:1440,height:946}});
    let challenge, callback, exchanged=0, quotes=0, completions=0, receipts=0, imageBytes=0;
    let durableBeforeSend=true;
    const disposableToken = 'sk-' + randomUUID();
    await page.route('https://routerai.ru/**', async route => {
      const url = new URL(route.request().url());
      if (url.pathname === '/auth') {
        assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
        assert.equal(url.searchParams.get('limit_period'), 'day');
        assert.ok(Number(url.searchParams.get('limit')) > 0);
        challenge = url.searchParams.get('code_challenge');
        callback = new URL(url.searchParams.get('callback_url'));
        assert.ok(url.searchParams.get('state').length >= 24);
        callback.searchParams.set('state', url.searchParams.get('state'));
        callback.searchParams.set('code', 'local-fixture');
        // An HTML navigation re-enters the application through its normal URL.
        return route.fulfill({contentType:'text/html', body:'<script>location.replace('+JSON.stringify(callback.href)+')</script>'});
      }
      if (url.pathname === '/api/v1/auth/keys') {
        const data = route.request().postDataJSON();
        assert.equal(data.code, 'local-fixture');
        assert.equal(createHash('sha256').update(data.code_verifier).digest('base64url'), challenge);
        assert.equal(data.callback_url, base);
        exchanged++;
        return route.fulfill({json:{key:disposableToken}});
      }
      if (url.pathname.endsWith('/endpoints')) {
        quotes++;
        return route.fulfill({json:{data:{architecture:{input_modalities:['text','image'],output_modalities:['text']},endpoints:[{tag:'byteplus',status:0,context_length:65536,max_completion_tokens:4096,supported_parameters:['max_tokens','temperature'],pricing:{prompt:.00001,completion:.00002},pricing_units:{prompt:'token',completion:'token'}}]}}});
      }
      if (url.pathname==='/api/v1/chat/completions') {
        const hasReserve=await page.evaluate(async()=>{
          const persisted=await new Promise((resolve,reject)=>{
            const open=indexedDB.open('ai-sims-alpha',1);
            open.onerror=reject;
            open.onsuccess=()=>{
              const db=open.result;
              const get=db.transaction('local').objectStore('local').get('ledger');
              get.onsuccess=()=>{db.close();resolve(get.result);};get.onerror=reject;
            };
          });
          return Object.values(JSON.parse(persisted).entries).some(entry=>entry.state==='reserved');
        });
        durableBeforeSend &&= hasReserve;
        assert.equal(route.request().headers().authorization,'Bearer '+disposableToken);
        const packet = route.request().postDataJSON();
        const content = packet.messages.flatMap(m=>Array.isArray(m.content)?m.content:[]);
        const image=content.find(c=>c.type==='image_url');
        assert.ok(image?.image_url?.url?.startsWith('data:image/png;base64,'));
        const bytes=Buffer.from(image.image_url.url.split(',')[1],'base64');
        assert.equal(bytes.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
        assert.ok(bytes.readUInt32BE(16)>100 && bytes.readUInt32BE(20)>100);
        imageBytes=bytes.length;completions++;
        return route.fulfill({json:{id:'gen-localfixture'+completions,model:packet.model,provider:'byteplus',choices:[{index:0,finish_reason:'stop',message:{role:'assistant',content:'{"type":"look"}'}}],usage:{prompt_tokens:99,completion_tokens:8}}});
      }
      if (url.pathname==='/api/v1/generation') {
        receipts++;
        return route.fulfill({json:{data:{id:url.searchParams.get('id'),currency:'RUB',total_cost:.0008}}});
      }
      return route.fulfill({status:404,json:{error:'unknown local fixture route'}});
    });
    await page.goto(base);
    await page.waitForFunction(()=>document.querySelector('#boot').hidden, null, {timeout:120000});
    await page.locator('#connect').click();
    await page.waitForFunction(()=>document.querySelector('#connect').textContent.includes('подключён'), null, {timeout:120000});
    assert.equal(exchanged, 1);
    assert.equal(new URL(page.url()).search, '');
    assert.equal(await page.evaluate(()=>sessionStorage.getItem('aisims-pkce')), null);
    assert.equal(await page.evaluate(()=>JSON.parse(AISimsWeb.getStatus()).connected), true);
    await page.mouse.click(720,850);await page.waitForTimeout(500);await page.mouse.click(720,611);
    await page.waitForTimeout(1600);
    await page.mouse.click(196,815); // A single scheduler step, using the actual transport.
    await page.waitForFunction(()=>{
      const ledger=JSON.parse(AISimsWeb.getLedger());
      const entries=Object.values(ledger.entries || {});
      return entries.length>=8 && entries.every(entry=>entry.state==='settled' && entry.actual===800);
    },null,{timeout:60000});
    assert.ok(quotes>0 && completions===8 && receipts===8 && durableBeforeSend);
    await page.reload();
    await page.waitForFunction(()=>document.querySelector('#boot').hidden, null, {timeout:120000});
    assert.equal(await page.evaluate(()=>JSON.parse(AISimsWeb.getStatus()).connected), false);
    console.log('PASS: S256, state, one-time exchange, URL cleanup, credential loss on reload, all provider traffic intercepted');
    console.log(JSON.stringify({quotes,completions,receipts,imageBytes,durableBeforeSend,real_paid_calls:0}));
  } finally { await browser.close(); }
}
run().catch(error=>{console.error(error);process.exitCode=1;});
