// Serve a Web export locally, then run this file with node. PW_CORE can point to
// playwright-core. The default run plays all twelve game hours in real time.
// STORY_RESUME can point to the 18:00 .aisims copy from a previous full run.
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const {chromium} = require(process.env.PW_CORE || 'playwright-core');

const url = process.env.BETA_URL || 'http://127.0.0.1:8732/';
const dir = process.env.BETA_REPORT || 'test-output/beta-story-soak-run';
const resumeFile = process.env.STORY_RESUME;
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

async function inspectDownload(file) {
  const bytes = await fs.readFile(file);
  assert.equal(bytes.subarray(0, 4).toString(), 'AIS2');
  let offset = 8 + bytes.readUInt32BE(4);
  const manifest = JSON.parse(bytes.subarray(8, offset).toString());
  const raw = manifest.slots['slot_3.json'];
  const wrapper = JSON.parse(raw);
  assert.equal(sha256(wrapper.payload), wrapper.sha256);
  for (const image of manifest.media) {
    const next = offset + image.size;
    assert.equal(sha256(bytes.subarray(offset, next)), image.hash);
    offset = next;
  }
  assert.equal(offset, bytes.length);
  const data = JSON.parse(wrapper.payload).data;
  const world = data.world.world;
  const episode = world.scenario_state || world.completed_episode;
  return {
    bytes: bytes.length, slot_bytes: Buffer.byteLength(raw), photos: manifest.media.length,
    media_hashes: manifest.media.map(image => image.hash).sort(),
    minute: world.elapsed_minutes, tick: world.tick, run: world.run_id,
    scenario: world.scenario, complete: episode.completed, outcome: episode.outcome.id,
    replay_frames: data.replay.sequence
  };
}

async function run() {
  await fs.mkdir(dir, {recursive: true});
  const browser = await chromium.launch({
    channel: process.env.BROWSER || 'chrome', headless: true,
    args: ['--enable-unsafe-swiftshader', '--disable-renderer-backgrounding', '--disable-background-timer-throttling']
  });
  const context = await browser.newContext({viewport: {width: 1440, height: 946}, acceptDownloads: true});
  const page = await context.newPage();
  const result = {browser: browser.version(), run: resumeFile ? 'resume_from_18_00' : 'full_day', checkpoints: [], errors: []};
  page.on('pageerror', e => result.errors.push(e.message));
  page.on('console', m => { if (m.type() === 'error') result.errors.push(m.text()); });
  page.on('response', r => { if (r.status() >= 400) result.errors.push('HTTP ' + r.status() + ' ' + new URL(r.url()).pathname); });

  const booted = () => page.waitForFunction(() => document.querySelector('#boot').hidden, null, {timeout: 120000});
  const shot = name => page.screenshot({path: path.join(dir, name + '.png')});
  const clip = (x, y, width, height) => page.screenshot({clip: {x, y, width, height}});
  const click = async (x, y) => { await page.mouse.click(x, y); await page.waitForTimeout(230); };
  const status = () => page.evaluate(() => JSON.parse(window.AISimsWeb.getStatus()));
  const slot = () => page.evaluate(() => {
    const raw = window.AISimsWeb.getSlot('slot_3.json');
    if (!raw) return null;
    const data = JSON.parse(JSON.parse(raw).payload).data;
    const world = data.world.world, episode = world.scenario_state || world.completed_episode;
    return {
      minute: world.elapsed_minutes, phase: episode.phase, complete: episode.completed,
      scenario: world.scenario, map: world.map_id, actors: Object.keys(world.agents).length,
      speed: data.settings.speed, tick: world.tick, run: world.run_id,
      interventions: episode.interventions.filter(x => x.used).map(x => x.id),
      events: world.event_cursor, replay_frames: data.replay.sequence,
      slot_bytes: new TextEncoder().encode(raw).length
    };
  });
  const checkpoint = async (condition, label, timeout = 600000) => {
    const until = Date.now() + timeout;
    let revision = -1, latest;
    while (Date.now() < until) {
      const storage = await status();
      assert.equal(storage.storage_error, '');
      assert.equal(storage.connected, false);
      if (revision !== storage.save_revision) {
        revision = storage.save_revision;
        latest = await slot();
      }
      if (latest && condition(latest) && storage.save_persisted >= revision) {
        result.checkpoints.push({label, ...latest});
        console.log(label, latest.minute, 'minutes,', latest.replay_frames, 'frames');
        return latest;
      }
      await page.waitForTimeout(200);
    }
    throw new Error(label + ' missing from committed slot 3. Last state ' + JSON.stringify(latest));
  };
  const backup = async name => {
    const download = page.waitForEvent('download', {timeout: 120000});
    await page.locator('#backup').click();
    const file = path.join(dir, name + '.aisims');
    await (await download).saveAs(file);
    return inspectDownload(file);
  };
  try {
    const boot = Date.now();
    await page.goto(url);
    await booted();
    result.cold_boot_ms = Date.now() - boot;
    result.core = await page.evaluate(() => performance.getEntriesByType('resource')
      .map(r => new URL(r.name).pathname).find(p => /\/core-.*\.pck/.test(p)));
    if (resumeFile) {
      await page.locator('#import-file').setInputFiles(resumeFile);
      await page.waitForFunction(() => document.querySelector('#storage-status').textContent.includes('Выберите слот'), null, {timeout: 120000});
      const origin = await slot();
      assert.equal(origin.map, 'residence');
      assert.equal(origin.actors, 8);
      assert.ok(origin.minute >= 600 && origin.minute < 660 && !origin.complete);
      await page.reload();
      await booted();
      await click(1090, 103);
    } else {
      await click(720, 850);
      await page.mouse.dblclick(397, 524);
      await page.keyboard.press('Control+a');
      await page.keyboard.type('8');
      await page.keyboard.press('Enter');
      await click(720, 611);
    }
    await page.waitForTimeout(1600);
    await shot(resumeFile ? 'resumed-chapter3' : 'chapter1');
    // The same solid panel background is present in all three chapters and in
    // the debrief. Compare its rendered pixels to catch a missing final save
    // without clicking anything that could save or dismiss the result.
    const panelPatch = () => clip(364, 225, 4, 4);
    const popup = await panelPatch();
    const expectPopup = async () => {
      const until = Date.now() + 3000;
      while (!(await panelPatch()).equals(popup)) {
        assert.ok(Date.now() < until, 'Expected chapter or debrief panel');
        await page.waitForTimeout(100);
      }
    };
    const ensurePopup = async () => {
      if (!(await panelPatch()).equals(popup)) await click(68, 135);
      await expectPopup();
    };
    // Set and verify the pace while paused. A PopupMenu suppresses rapid
    // follow-up clicks on some browsers, especially just after loading a save.
    await click(1048, 212);
    await click(271, 815);
    await page.waitForTimeout(800);
    await shot('pace-menu');
    await click(271, 918);
    await shot('pace-selected');
    await backup('pace');
    assert.equal((await slot()).speed, 2, 'The speed control selected 2x');
    await ensurePopup();
    const started = Date.now();
    await page.evaluate(() => {
      const samples = [];
      let start = performance.now(), previous = start, frames = 0, longest = 0;
      let handle;
      function sample(now) {
        frames++;
        longest = Math.max(longest, now - previous);
        previous = now;
        if (now - start >= 10000) {
          samples.push({fps: Math.round(1000 * frames / (now - start)),
            engine: window.AISimsWeb.renderingFps(), longest_ms: Math.round(longest)});
          start = now;
          frames = 0;
          longest = 0;
        }
        handle = requestAnimationFrame(sample);
      }
      handle = requestAnimationFrame(sample);
      window.finishStoryFpsSample = () => { cancelAnimationFrame(handle); return samples; };
    });
    await click(720, resumeFile ? 598 : 699);
    // Starting a restored Web session can present its current chapter again
    // after the Run command. Close that card while the world continues.
    if ((await panelPatch()).equals(popup)) await click(1048, 212);
    assert.ok(!(await panelPatch()).equals(popup), 'Observation has begun');
    if (!resumeFile) {
      const chapter2 = await checkpoint(s => s.phase === 2, 'chapter_2');
      assert.equal(chapter2.actors, 8);
      assert.equal(chapter2.speed, 2);
      assert.equal(chapter2.map, 'residence');
      await expectPopup();
      await shot('chapter2');
      await click(720, 698);
      await checkpoint(s => s.minute >= 240, 'noon');
      await click(85, 815);
      await ensurePopup();
      await click(715, 592); // Release the relief fund.
      await ensurePopup();
      await click(715, 592); // Freeze prices. The used fund button is gone.
      await shot('noon');
      await click(85, 815);
      const chapter3 = await checkpoint(s => s.phase === 3, 'chapter_3');
      assert.deepEqual(chapter3.interventions.sort(), ['policy', 'reserve']);
      await expectPopup();
      await shot('chapter3');
      await click(720, 598);
      await checkpoint(s => s.minute >= 600, '18_00');
      result.evening = await backup('hour10');
    }
    const lastHour = await checkpoint(s => s.minute >= 660 && !s.complete, 'last_hour');
    assert.equal(lastHour.speed, 2);
    const until = Date.now() + 300000;
    while (!(await panelPatch()).equals(popup)) {
      assert.ok(Date.now() < until, 'Debrief did not appear');
      await page.waitForTimeout(400);
    }
    result.play_to_debrief_ms = Date.now() - started;
    result.ten_second_frame_samples = await page.evaluate(() => window.finishStoryFpsSample());
    await shot('ending');
    // Check both automatic transitions BEFORE the toolbar creates a manual save.
    await checkpoint(s => s.complete && s.minute >= 720, 'ending_autosave', 8000);
    const storyFile = page.waitForEvent('download', {timeout: 30000});
    await click(720, 500);
    const reportPath = path.join(dir, 'story.json');
    await (await storyFile).saveAs(reportPath);
    const story = JSON.parse(await fs.readFile(reportPath, 'utf8'));
    const economic = story.events.filter(e => e.type === 'intervention' && e.details.command === 'episode_intervention');
    assert.deepEqual(economic.map(e => e.details.args.id), ['reserve', 'policy']);
    assert.ok(economic.every(e => Math.floor(e.minute) === 240), 'Interventions occurred at 12:00');
    result.ending = await backup('ending');
    await ensurePopup();
    await click(720, 552);
    await checkpoint(s => s.scenario === 'sandbox' && s.complete, 'sandbox_autosave', 8000);
    await page.waitForTimeout(4000);
    await click(85, 815);
    await shot('sandbox');
    result.sandbox = await backup('sandbox');
    assert.ok(result.sandbox.tick > result.ending.tick);
    await page.reload();
    await booted();
    const reloaded = await slot();
    assert.equal(reloaded.tick, result.sandbox.tick);
    assert.equal(reloaded.scenario, 'sandbox');
    await click(1090, 103);
    await page.waitForTimeout(1500);
    result.restored = await backup('restored');
    assert.equal(result.restored.scenario, 'sandbox');
    assert.equal(result.restored.tick, result.sandbox.tick);
    assert.equal(result.restored.outcome, result.ending.outcome);
    assert.ok(result.restored.run > result.sandbox.run);
    assert.deepEqual(result.restored.media_hashes, result.sandbox.media_hashes);
    const endClock = await clip(1180, 80, 50, 28);
    await click(1265, 815);
    await page.waitForTimeout(800);
    const firstClock = await clip(1180, 80, 50, 28);
    assert.ok(!firstClock.equals(endClock), 'Replay returns to the morning clock');
    await shot('replay-start');
    await page.waitForTimeout(8500);
    assert.ok(!(await clip(1180, 80, 50, 28)).equals(firstClock), 'Recorded clock advances');
    await shot('replay-progress');
    assert.deepEqual(result.errors, []);
    result.passed = true;
  } catch (error) {
    result.failure = error.message;
    await shot('failure').catch(() => {});
    throw error;
  } finally {
    await fs.writeFile(path.join(dir, 'result.json'), JSON.stringify(result, null, 2));
    await browser.close();
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
