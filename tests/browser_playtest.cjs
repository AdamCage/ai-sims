// Exercise the release's local feedback download in a fresh, offline-demo browser.
const {chromium}=require(process.env.PW_CORE || 'playwright-core');
const assert=require('node:assert/strict');
const {readFile}=require('node:fs/promises');

async function run() {
  const browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-swiftshader']});
  try {
    const page=await browser.newPage({viewport:{width:1440,height:946},acceptDownloads:true});
    await page.goto(process.env.BETA_URL || 'http://127.0.0.1:8732/');
    await page.waitForFunction(()=>document.querySelector('#boot').hidden,null,{timeout:120000});
    const open=page.locator('#feedback');
    const form=page.locator('#playtest');
    const answer=form.locator('[name=cause]');
    const close=form.locator('[data-close]');
    const submit=form.locator('button[type=submit]');
    const openWithContext=(map,locale)=>page.evaluate(([map,locale])=>{
      window.AISimsWeb.playtestContext('test-build',map,'demo',locale);
      document.querySelector('#feedback').click();
      return document.querySelector('#playtest h2').textContent;
    },[map,locale]);
    async function download() {
      const file=page.waitForEvent('download');
      await submit.click();
      const result=await file;
      assert.equal(result.suggestedFilename(),'AI-Sims-playtest.json');
      return JSON.parse(await readFile(await result.path(),'utf8'));
    }
    await open.click();
    await submit.click();
    assert.match(await form.locator('[role=status]').innerText(),/хотя бы одно/);
    await answer.fill('Человек отдал соседу еду.');
    await close.click();
    await open.click();
    assert.equal(await answer.inputValue(),'Человек отдал соседу еду.');
    const first=await download();
    assert.equal(first.game.map,'closed_block');
    assert.deepEqual(Object.keys(first.game).sort(),['language','map','mode','version']);
    assert.deepEqual(Object.keys(first.answers).sort(),['cause','ending','problem','situation']);
    assert.equal(first.answers.cause,'Человек отдал соседу еду.');
    await close.click();
    // Use the same context boundary the engine calls when map/locale change.
    const englishTitle=await openWithContext('residence','en');
    assert.equal(await answer.inputValue(),'');
    assert.equal(englishTitle,'How did your story go?');
    await answer.fill('The resident followed a route.');
    await close.click();
    await openWithContext('research_station','ru');
    assert.equal(await answer.inputValue(),'The resident followed a route.');
    const second=await download();
    assert.equal(second.game.map,'residence');
    assert.equal(second.game.language,'en');
    assert.equal(second.game.mode,'demo');
    assert.equal(second.answers.cause,'The resident followed a route.');
    await answer.fill('An unfinished note.');
    await page.reload();
    await page.waitForFunction(()=>document.querySelector('#boot').hidden,null,{timeout:120000});
    await open.click();
    assert.equal(await answer.inputValue(),'');
    console.log('PASS feedback localization, draft lifetime, map binding, separate local JSON export and scoped metadata');
  } finally {
    await browser.close();
  }
}
run().catch(error=>{console.error(error.message);process.exitCode=1;});
