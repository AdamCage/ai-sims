const assert = require('node:assert/strict');
const {mkdir, writeFile} = require('node:fs/promises');
const path = require('node:path');
const playwright = process.env.PW_CORE || 'playwright-core';
const {chromium} = require(playwright);
const {PNG} = require(path.join(path.dirname(require.resolve(playwright)), 'lib', 'utilsBundle.js'));

const base = process.env.BETA_URL || 'http://127.0.0.1:8732/';
const output = process.env.BETA_REPORT || 'test-output/browser-graphics';
const browserChannel = process.env.BROWSER || 'chrome';
const map = process.env.GRAPHICS_MAP || 'closed_block';
const agents = Number(process.env.GRAPHICS_AGENTS || 20);
const scenario = process.env.GRAPHICS_SCENARIO || 'sandbox';
const strict = process.env.GRAPHICS_REQUIRE_60 === '1';
const benchmark = process.env.GRAPHICS_BENCHMARK === '1';
const warmup = Number(process.env.GRAPHICS_WARMUP_MS ?? (benchmark ? 10000 : 2500));
const sampleMs = benchmark ? 60000 : 8000;
const trials = benchmark ? 3 : 1;
const toolbarHeight = 46;
const initial = {width: 1920, height: 1080, dpr: 1, pixels: [1920, 1080]};
const allOutputs = [initial,
  {width: 2560, height: 1440, dpr: 1, pixels: [2560, 1440]},
  {width: 1920, height: 1080, dpr: 2, pixels: [3840, 2160]},
];
const outputs = process.env.GRAPHICS_RESOLUTION ?
  allOutputs.filter(row => row.pixels.join('x') === process.env.GRAPHICS_RESOLUTION) : allOutputs;

function instrumentPage(launchArguments) {
  // The boot layer can close before a separately loaded map is ready.
  Object.defineProperty(window, 'AISimsWeb', {configurable: true, set(bridge) {
    const observed = {...bridge, playtestContext(...args) {
      window.aiSimsGraphicsMap = args[1];
      return bridge.playtestContext(...args);
    }};
    Object.defineProperty(window, 'AISimsWeb', {configurable: true, value: Object.freeze(observed)});
  }});
  // Exercise the shipped Godot startup CLI without changing the export or
  // relying on click coordinates to choose a map and resident count.
  Object.defineProperty(window, 'Engine', {
    configurable: true,
    set(Engine) {
      const InstrumentedEngine = new Proxy(Engine, {
        construct(target, args) {
          const engine = new target(...args);
          const start = engine.start.bind(engine);
          engine.start = options => start({...options, args: [...options.args, '--', ...launchArguments]});
          return engine;
        },
      });
      Object.defineProperty(window, 'Engine', {configurable: true, value: InstrumentedEngine});
    },
  });

  let timings = [];
  let animationFrames = [];
  let engineCallbacks = [];
  let animationHandle;
  let sampling = false;
  let gl;
  const nativeAnimationFrame = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = callback => nativeAnimationFrame(timestamp => {
    if (!sampling) return callback(timestamp);
    const before = timings.length;
    const started = performance.now();
    try {
      return callback(timestamp);
    } finally {
      if (timings.length > before) engineCallbacks.push(performance.now() - started);
    }
  });
  const sampleAnimation = timestamp => {
    animationFrames.push(timestamp);
    animationHandle = requestAnimationFrame(sampleAnimation);
  };
  // The shipped loader calls this hook immediately before its native blit.
  // Returning false preserves the production blit and counts only drawn frames.
  Object.defineProperty(HTMLCanvasElement.prototype, 'presentGodotFrame', {
    configurable: true,
    writable: true,
    value(context) {
      if (context.GLctx.canvas.id === 'canvas') {
        gl = context.GLctx;
        if (sampling) timings.push(performance.now());
      }
      return false;
    },
  });

  window.aiSimsGraphicsQA = {
    bufferSize: () => gl ? [gl.drawingBufferWidth, gl.drawingBufferHeight] : null,
    adapter() {
      if (!gl) return '';
      const renderer = gl.getExtension('WEBGL_debug_renderer_info');
      return gl.getParameter(renderer ? renderer.UNMASKED_RENDERER_WEBGL : gl.RENDERER);
    },
    start() {
      timings = [];
      animationFrames = [];
      engineCallbacks = [];
      sampling = true;
      animationHandle = requestAnimationFrame(sampleAnimation);
    },
    stop() {
      sampling = false;
      cancelAnimationFrame(animationHandle);
      return {drawn: timings, animation: animationFrames, engine_callbacks: engineCallbacks};
    },
  };
}

async function setOutput(page, session, output) {
  await session.send('Emulation.setDeviceMetricsOverride', {
    width: output.width,
    height: output.height + toolbarHeight,
    deviceScaleFactor: output.dpr,
    mobile: false,
  });
  await page.waitForFunction(({width, height, dpr, pixels}) => {
    const canvas = document.getElementById('canvas');
    const box = canvas.getBoundingClientRect();
    const buffer = window.aiSimsGraphicsQA.bufferSize();
    return box.width === width && box.height === height && window.devicePixelRatio === dpr &&
      canvas.width === pixels[0] && canvas.height === pixels[1] && buffer?.[0] === pixels[0] && buffer?.[1] === pixels[1];
  }, output, {timeout: 30000});
}

function checkPixels(pngBuffer, expected) {
  const screenshot = PNG.sync.read(pngBuffer);
  assert.deepEqual([screenshot.width, screenshot.height], expected);
  const colors = new Set();
  for (let y = 20; y < screenshot.height - 20; y += 57) {
    for (let x = 20; x < screenshot.width - 20; x += 53) {
      const start = (y * screenshot.width + x) * 4;
      colors.add(screenshot.data.readUInt32BE(start));
    }
  }
  assert.ok(colors.size >= 20, 'screenshot contains visible game content');
}

function frameStats(timestamps) {
  const times = timestamps.slice(1).map((now, index) => now - timestamps[index]).sort((a, b) => a - b);
  assert.ok(times.length > 1, 'observed actual rendered frames');
  const seconds = (timestamps.at(-1) - timestamps[0]) / 1000;
  const percentile = ratio => times[Math.ceil(ratio * times.length) - 1];
  return {
    drawn_frames: times.length,
    seconds,
    fps: times.length / seconds,
    p50_ms: percentile(0.5),
    p95_ms: percentile(0.95),
    p99_ms: percentile(0.99),
    over_16_67_percent: 100 * times.filter(time => time > 1000 / 60).length / times.length,
  };
}

function callbackP95(durations) {
  durations.sort((a, b) => a - b);
  return durations.length ? durations[Math.ceil(0.95 * durations.length) - 1] : null;
}

async function run() {
  assert.ok(outputs.length > 0, 'GRAPHICS_RESOLUTION must be 1920x1080, 2560x1440 or 3840x2160');
  await mkdir(output, {recursive: true});
  assert.ok(Number.isInteger(agents) && agents >= 3 && agents <= 20, 'Select 3–20 residents');
  const launch = ['--test-profile', '--auto-run', `--agents=${agents}`, '--seed=83', `--scenario=${scenario}`, `--map=${map}`];
  const report = {kind: 'exported_browser_rendering', browser: browserChannel, map, agents, scenario, seed: 83,
    warmup_ms: warmup, sample_ms: sampleMs, headless: process.env.GRAPHICS_HEADED !== '1', trials: []};
  const browser = await chromium.launch({channel: browserChannel, headless: report.headless});
  try {
    for (let trial = 1; trial <= trials; trial++) {
      const context = await browser.newContext({viewport: {width: initial.width, height: initial.height + toolbarHeight}, acceptDownloads: true});
      try {
        await context.addInitScript(instrumentPage, launch);
        const page = await context.newPage();
        await page.goto(base);
        await page.waitForFunction(() => document.getElementById('boot').hidden, null, {timeout: 120000});
        await page.waitForFunction(expected => window.aiSimsGraphicsMap === expected, map, {timeout: 120000});
        const session = await context.newCDPSession(page);
        report.adapter = await page.evaluate(() => window.aiSimsGraphicsQA.adapter());
        if (strict) assert.ok(report.adapter && !/swiftshader|llvmpipe|software/i.test(report.adapter), 'hardware WebGL');
        for (const viewport of outputs) {
          // Recreate 1080p CSS before the DPR-only transition to 4K.
          if (viewport.dpr === 2) await setOutput(page, session, initial);
          await setOutput(page, session, viewport);
          await page.waitForTimeout(warmup);
          await page.evaluate(() => window.aiSimsGraphicsQA.start());
          await page.waitForTimeout(sampleMs);
          const timestamps = await page.evaluate(() => window.aiSimsGraphicsQA.stop());
          const stats = frameStats(timestamps.drawn);
          const animation = frameStats(timestamps.animation);
          const label = viewport.pixels.join('x');
          const row = {trial, drawable: viewport.pixels, css_pixels: [viewport.width, viewport.height], dpr: viewport.dpr,
            ...stats, raf_fps: animation.fps, raf_p95_ms: animation.p95_ms,
            engine_callback_p95_ms: callbackP95(timestamps.engine_callbacks)};
          report.trials.push(row);
          console.log('BROWSER GRAPHICS', JSON.stringify(row));
          if (trial === 1) {
            const box = await page.locator('#canvas').boundingBox();
            const {data} = await session.send('Page.captureScreenshot', {format: 'png', fromSurface: true, clip: {...box, scale: 1}});
            const screenshot = Buffer.from(data, 'base64');
            checkPixels(screenshot, viewport.pixels);
            await writeFile(path.join(output, `${browserChannel}-${label}.png`), screenshot);
          }
        }
        await setOutput(page, session, initial);
        const saveReady = page.waitForEvent('download', {timeout: 120000});
        await page.locator('#backup').click();
        await saveReady;
        const sessionState = await page.evaluate(() => {
          const data = JSON.parse(JSON.parse(window.AISimsWeb.getSlot('slot_3.json')).payload).data;
          const world = data.world.world;
          return {map: world.map_id, people: Object.keys(world.agents).length, tick: world.tick,
            events: world.event_cursor, render_scale: data.settings.render_scale, quality: data.settings.quality,
            hasKey: Boolean(window.AISimsWeb.getKey())};
        });
        assert.equal(sessionState.map, map);
        assert.equal(sessionState.people, agents);
        assert.equal(sessionState.hasKey, false);
        assert.ok(sessionState.tick > 0 && sessionState.events > 1, 'benchmark advanced the offline world');
        report.session_state = sessionState;
      } finally {
        await context.close();
      }
    }
    if (strict) {
      for (const row of report.trials) {
        assert.ok(row.fps >= 59 && row.p95_ms <= 17.5 && row.p99_ms <= 33.34,
          `60 FPS target missed at ${row.drawable.join('×')}: ${JSON.stringify(row)}`);
      }
    }
  } catch (error) {
    report.failure = error.message;
    throw error;
  } finally {
    await writeFile(path.join(output, `${browserChannel}.json`), JSON.stringify(report, null, 2));
    await browser.close();
  }
}

run().catch(error => { console.error(error); process.exitCode = 1; });
