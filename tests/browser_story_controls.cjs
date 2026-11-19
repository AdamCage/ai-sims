const path = require('node:path');
const playwright = process.env.PW_CORE || 'playwright-core';
const {PNG} = require(path.join(path.dirname(require.resolve(playwright)), 'lib', 'utilsBundle.js'));

// These fixtures use a 1440 × 946 CSS viewport, including the 46-pixel web bar.
const ui = {
  tabs: {closed_block: 264, residence: 720, research_station: 1176},
  menu: [1398, 88], resume: [1142, 102], count: [405, 482],
  pause: [951, 879], step: [1038, 879], pace: [1100, 879], paceFast: [1100, 925],
  replay: [1291, 879], chapter: [399, 106], closeChapter: [1052, 212],
};

async function clickPrimary(page, label, placement = 'dialog') {
  const [left, right, center, top, bottom] = placement === 'hero'
    ? [58, 227, 143, 465, 810] : [420, 1005, 720, 480, 792];
  await page.mouse.move(90, 160);
  const deadline = Date.now() + 45000;
  while (Date.now() < deadline) {
    const shot = PNG.sync.read(await page.screenshot());
    let height = 0;
    for (let y = top; y < bottom; y++) {
      const amber = [left, right].every(x => {
        const i = (y * shot.width + x) * 4;
        return Math.abs(shot.data[i] - 228) < 10 && Math.abs(shot.data[i + 1] - 183) < 10 && Math.abs(shot.data[i + 2] - 117) < 10;
      });
      height = amber ? height + 1 : 0;
      if (height === 18) {
        await page.mouse.click(center, y - 5);
        return;
      }
    }
    await page.waitForTimeout(200);
  }
  throw new Error(`${label} action did not appear`);
}

async function chooseStory(page, id) {
  await page.mouse.click(ui.tabs[id], 885);
  await clickPrimary(page, 'Open story', 'hero');
}

const storyClock = page => page.screenshot({clip:{x:29,y:110,width:110,height:22}});

async function startReplay(page, liveClock = null) {
  const before = liveClock ?? await storyClock(page);
  for (let attempt = 0; attempt < 2; attempt++) {
    await page.mouse.click(...ui.replay);
    for (let sample = 0; sample < 8; sample++) {
      await page.waitForTimeout(200);
      const recorded = await storyClock(page);
      if (recorded.equals(before)) continue;
      const label = PNG.sync.read(await page.screenshot({clip:{x:1020,y:885,width:40,height:13}}));
      let gold = 0;
      for (let i = 0; i < label.data.length; i += 4) {
        const [r, g, b] = label.data.subarray(i, i + 3);
        if (r >= 145 && r <= 240 && r - g >= 22 && g - b >= 34 && b >= 50) gold++;
      }
      if (gold > 30) return recorded;
    }
  }
  throw new Error('Replay did not restore the recorded clock');
}

module.exports = {clickPrimary, chooseStory, storyClock, startReplay, ui};
