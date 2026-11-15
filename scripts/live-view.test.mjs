import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { Cadence, H264, HEADER, JPEG, LiveView, Meter, POINTER, parseUpdate } from '../Web/live-view.js';

function setup() {
  const outputs = [], chunks = [], drawn = [], shown = [], placed = [];
  let fallback = 0, closed = 0;
  globalThis.VideoDecoder = class {
    static async isConfigSupported() { return { supported: true }; }
    constructor(callbacks) { this.state = 'unconfigured'; outputs.push(callbacks); }
    configure() { this.state = 'configured'; }
    decode(chunk) { chunks.push(chunk); }
    close() { this.state = 'closed'; }
  };
  globalThis.EncodedVideoChunk = class { constructor(init) { Object.assign(this, init); } };
  // The display is half the size of the pictures (640 x 360), so a place in it is half the picture's pixels.
  const canvas = { clientWidth: 320, clientHeight: 180, getContext: () => ({ drawImage: (image) => drawn.push(image.timestamp) }) };
  const aim = { style: {} }, cursor = { style: {} }, picture = { style: {} };
  const player = new LiveView(canvas, { picture, aim, cursor }, {
    shown: (n) => shown.push(n), placed: (meta) => placed.push(meta), fallback: () => fallback++,
  });
  player.show(true);
  const output = (index, n) => outputs[index].output({
    timestamp: n, displayWidth: 640, displayHeight: 360, close: () => closed++,
  });
  return { player, chunks, drawn, shown, placed, outputs, output, canvas, aim, cursor, picture, get fallback() { return fallback; }, get closed() { return closed; } };
}

/** An update as the agent sends it (Sources/Remotey/Wire.swift), of a view that runs at 60 fps. */
function update(kind, picture, n, { q = 0, x = 0.5, y = 0.25, fx = x, fy = y, v = 0, text = false, width = 780 } = {}) {
  const buffer = new ArrayBuffer(HEADER + picture.length), head = new DataView(buffer);
  head.setUint8(0, kind); head.setUint8(1, 60); head.setUint8(2, +text);
  [x, y, fx, fy, width].forEach((value, i) => head.setFloat32(3 + 4 * i, value, true));
  [q, v, n].forEach((value, i) => head.setUint32(23 + 4 * i, value, true));
  new Uint8Array(buffer, HEADER).set(picture);
  return buffer;
}
const packet = (n, key = true, level = 31, fields = {}) => update(H264, [66, 192, level, +key, 0, 0, 0, 1, key ? 0x65 : 0x41], n, fields);
/** The pointer moved inside the view. */
const pointerOnly = (q, x, y, fields = {}) => update(POINTER, [], 0, { q, x, y, ...fields });

test('reads every field of the header the agent writes', () => {
  const meta = parseUpdate(update(JPEG, [0xff, 0xd8], 7, { q: 3, x: 0.5, y: 0.25, fx: 0.75, fy: 1.5, v: 9, text: true }));
  assert.deepEqual({ ...meta, picture: [...meta.picture] }, { kind: JPEG, fps: 60, followsText: true, x: 0.5, y: 0.25,
    fx: 0.75, fy: 1.5, width: 780, q: 3, v: 9, n: 7, picture: [0xff, 0xd8] });
});

test('submits both frames without waiting for output, but acknowledges only drawn frames', async () => {
  const s = setup();
  try {
    s.player.receive(packet(1)); s.player.receive(packet(2, false));
    await s.player.chain;
    assert.equal(s.chunks.length, 2);
    assert.deepEqual(s.shown, []);
    s.output(0, 1); s.output(0, 2);
    assert.deepEqual(s.drawn, [1, 2]);
    assert.deepEqual(s.shown, [1, 2]);
    assert.equal(s.closed, 2);
    assert.equal(s.canvas.width, 640);
  } finally { s.player.close(); }
});

test('unsupported H.264 configuration requests JPEG instead of stalling', async () => {
  const s = setup();
  VideoDecoder.isConfigSupported = async () => ({ supported: false });
  s.player.receive(packet(1));
  await s.player.chain;
  assert.equal(s.fallback, 1);
  assert.equal(s.player.codec, 'jpeg');
  s.player.close();
});

test('a fault in the page while placing a picture keeps H.264', async (t) => {
  const s = setup();
  t.mock.method(console, 'error', () => {});
  s.player.placed = () => { throw new Error('page'); };
  s.player.receive(packet(1)); await s.player.chain;
  s.output(0, 1);
  assert.equal(s.player.codec, 'h264');
  assert.equal(s.fallback, 0);
  assert.deepEqual(s.shown, [1]);
  s.player.close();
});

test('closing a connection invalidates delayed decoder outputs', async () => {
  const s = setup();
  s.player.receive(packet(1)); await s.player.chain;
  s.player.close();
  const before = s.shown.length;
  s.output(0, 1);
  assert.deepEqual(s.drawn, []);
  assert.equal(s.shown.length, before);
  assert.equal(s.closed, 1);
});

test('closing while support detection is pending never starts a decoder', async () => {
  const s = setup();
  let supported;
  VideoDecoder.isConfigSupported = () => new Promise((resolve) => { supported = resolve; });
  s.player.receive(packet(1));
  await Promise.resolve();
  s.player.close();
  supported({ supported: true });
  await s.player.chain;
  assert.equal(s.outputs.length, 0);
  assert.deepEqual(s.drawn, []);
});

test('a decoder that withholds output falls back instead of deadlocking the send window', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const s = setup();
  s.player.receive(packet(1)); s.player.receive(packet(2, false));
  await s.player.chain;
  t.mock.timers.tick(2000);
  assert.equal(s.fallback, 1);
  assert.equal(s.player.codec, 'jpeg');
  assert.deepEqual(s.shown, [1, 2]);
  s.player.close();
});

test('a decoder that keeps giving pictures back is no stall, however long some stay pending', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const s = setup();
  // Three seconds of a stream where the next picture always arrives before the last one is out.
  for (let n = 1; n <= 180; n++) {
    s.player.receive(packet(n, n === 1)); await s.player.chain;
    if (n > 1) s.output(0, n - 1);
    t.mock.timers.tick(1000 / 60);
  }
  assert.equal(s.fallback, 0);
  assert.equal(s.player.codec, 'h264');
  t.mock.timers.tick(2000); // then nothing comes out
  assert.equal(s.fallback, 1);
  s.player.close();
});

test('a codec change discards and acknowledges old pending frames', async () => {
  const s = setup();
  try {
    s.player.receive(packet(1)); await s.player.chain;
    s.player.receive(packet(2, true, 32)); await s.player.chain;
    assert.deepEqual(s.shown, [1]);
    s.output(1, 2);
    assert.deepEqual(s.shown, [1, 2]);
  } finally { s.player.close(); }
});

test('JPEG from a Mac without hardware H.264 switches the request to JPEG', async () => {
  const s = setup();
  const jpeg = update(JPEG, [0xff, 0xd8, 0xff], 1);
  s.player.receive(jpeg); await s.player.chain;
  assert.equal(s.fallback, 1);
  let closed = false;
  globalThis.createImageBitmap = async () => ({ width: 640, height: 360, close: () => { closed = true; } });
  s.player.receive(jpeg); await s.player.chain;
  assert.deepEqual(s.shown, [1]);
  assert.equal(closed, true);
  s.player.close();
});

test('matches the rendering cadence up to 120 fps', () => {
  for (const hz of [30, 60, 90, 120, 144]) {
    const callbacks = new Map();
    let id = 0, changes = 0;
    globalThis.requestAnimationFrame = (callback) => { callbacks.set(++id, callback); return id; };
    globalThis.cancelAnimationFrame = (id) => callbacks.delete(id);
    const cadence = new Cadence(() => changes++);
    cadence.measure();
    for (let i = 0; i < 25; i++) {
      const [key, callback] = callbacks.entries().next().value;
      callbacks.delete(key);
      callback(i * 1000 / hz);
    }
    assert.equal(cadence.framesPerSecond, Math.min(hz, 120));
    assert.equal(changes, hz !== 60 ? 1 : 0);
    assert.equal(callbacks.size, 0);
  }
});

test('a busy page or a display a little off its rate does not change the cadence', () => {
  const callbacks = new Map();
  let id = 0, time = 0;
  globalThis.requestAnimationFrame = (callback) => { callbacks.set(++id, callback); return id; };
  globalThis.cancelAnimationFrame = (id) => callbacks.delete(id);
  const cadence = new Cadence(() => {});
  cadence.measure();
  // Frame times wander around 59 Hz, and every fourth frame comes a frame late, as on a page that decodes meanwhile.
  for (let i = 0; i < 25; i++) {
    const [key, callback] = callbacks.entries().next().value;
    callbacks.delete(key);
    callback(time);
    time += (i % 4 === 3 ? 2 : 1) * 1000 / 59 + (i % 2 ? 0.3 : -0.3);
  }
  assert.equal(cadence.framesPerSecond, 60);
});

test('a stopped or restarted probe of the cadence leaves no frame callback behind', () => {
  const callbacks = new Map();
  let id = 0;
  globalThis.requestAnimationFrame = (callback) => { callbacks.set(++id, callback); return id; };
  globalThis.cancelAnimationFrame = (id) => callbacks.delete(id);
  const cadence = new Cadence(() => assert.fail('cancelled probe completed'));
  cadence.measure();
  cadence.measure();
  assert.equal(callbacks.size, 1);
  cadence.stop();
  assert.equal(callbacks.size, 0);
});

test('hiding the view takes the pointer away', async () => {
  const s = setup();
  try {
    s.player.receive(packet(1)); await s.player.chain;
    s.output(0, 1);
    assert.equal(s.aim.hidden, false);
    s.player.show(false);
    assert.equal(s.aim.hidden, true);
  } finally { s.player.close(); }
});

test('a hidden view draws nothing but still answers its pictures', async () => {
  const s = setup();
  try {
    s.player.show(false);
    s.player.receive(packet(1)); await s.player.chain;
    s.output(0, 1);
    assert.deepEqual(s.drawn, []);
    assert.deepEqual(s.placed, []);
    assert.deepEqual(s.shown, [1]);
  } finally { s.player.close(); }
});

test('a pointer move without a picture moves the marker at once and is not answered', async () => {
  const s = setup();
  try {
    s.player.receive(packet(1)); await s.player.chain;
    s.output(0, 1);
    s.player.receive(pointerOnly(7, 0.75, 0.5)); await s.player.chain;
    assert.equal(s.aim.style.transform, 'translate3d(240px,90px,0)');
    assert.deepEqual(s.drawn, [1]);
    assert.deepEqual(s.shown, [1]);
    assert.deepEqual(s.placed.map((meta) => meta.q), [0, 7]);
  } finally { s.player.close(); }
});

test('a pointer move waits for the picture it belongs to', async () => {
  const s = setup();
  try {
    s.player.receive(packet(1)); await s.player.chain;
    s.output(0, 1);
    s.player.receive(packet(2, false)); s.player.receive(pointerOnly(9, 1, 1)); await s.player.chain;
    // Picture 2 shows another part of the screen and is still being decoded: the place in it would be wrong in picture 1.
    assert.equal(s.aim.style.transform, 'translate3d(160px,45px,0)');
    s.output(0, 2);
    assert.equal(s.aim.style.transform, 'translate3d(320px,180px,0)');
    assert.deepEqual(s.placed.map((meta) => meta.q), [0, 9]);
  } finally { s.player.close(); }
});

test('the pointer picture is as large as in the view, but at least half its size on the Mac', async () => {
  const s = setup();
  try {
    s.player.setCursor({ png: 'AAAA', w: 28, h: 40, x: 5, y: 5 });
    assert.equal(s.cursor.src, 'data:image/png;base64,AAAA');
    assert.equal(s.cursor.style.width, undefined, 'no size before the first picture tells the scale');
    s.canvas.clientWidth = 390; s.canvas.clientHeight = 219.375;
    s.player.receive(packet(1)); await s.player.chain;
    s.output(0, 1); // 780 points on 390 pixels
    assert.deepEqual([s.cursor.style.width, s.cursor.style.height], ['14px', '20px']);
    assert.equal(s.cursor.style.transform, 'translate(-2.5px,-2.5px)');
    s.canvas.clientWidth = 195; s.canvas.clientHeight = 109.6875; // a quarter of the Mac's size would be too small to see
    s.player.layout();
    assert.equal(s.cursor.style.width, '14px');
    s.canvas.clientWidth = 1560; s.canvas.clientHeight = 877.5;
    s.player.layout();
    assert.deepEqual([s.cursor.style.width, s.cursor.style.transform], ['56px', 'translate(-10px,-10px)']);
  } finally { s.player.close(); }
});

test('while the display has another shape than the picture, the pointer stays on its place in the cropped picture', async () => {
  const s = setup();
  try {
    s.player.receive(packet(1, true, 31, { x: 0.5, y: 0.5 })); await s.player.chain;
    s.output(0, 1);
    assert.equal(s.aim.style.transform, 'translate3d(160px,90px,0)');
    // The keyboard opened: the display is 320 x 90 now and shows the middle strip of the 640 x 360 picture.
    s.canvas.clientHeight = 90;
    s.player.layout();
    assert.equal(s.aim.style.transform, 'translate3d(160px,45px,0)');
    s.player.receive(pointerOnly(2, 0, 0)); await s.player.chain;
    assert.equal(s.aim.style.transform, 'translate3d(0px,-45px,0)', 'cropped away, not squeezed in');
  } finally { s.player.close(); }
});

test('a zoom preview scales the picture at hand around the focus until a picture of that zoom arrives', async () => {
  const s = setup();
  try {
    // 780 Mac points on 320 CSS pixels: the picture's zoom is 320 / 780.
    s.player.receive(packet(1, true, 31, { x: 0.5, y: 0.5, fx: 0.25, fy: 0.5 })); await s.player.chain;
    s.output(0, 1);
    s.player.zoomTo(640 / 780);
    assert.equal(s.picture.style.transform, 'translate(80px,90px) scale(2) translate(-80px,-90px)');
    // A late picture of the old zoom keeps the preview; one of the new zoom (390 points wide) ends it.
    s.player.receive(packet(2, false)); await s.player.chain;
    s.output(0, 2);
    assert.match(s.picture.style.transform, /scale\(2\)/);
    s.player.receive(packet(3, false, 31, { width: 390 })); await s.player.chain;
    s.output(0, 3);
    assert.equal(s.picture.style.transform, '');
    // Two steps before any new picture: the preview is measured against the picture shown, not the last step.
    s.player.zoomTo(1.6); s.player.zoomTo(3.2);
    assert.match(s.picture.style.transform, /scale\(3\.9/);
    s.player.show(false);
    assert.equal(s.picture.style.transform, '', 'a hidden view has no preview');
  } finally { s.player.close(); }
});

test('the meter counts updates per second and times a move until it shows', () => {
  const meter = new Meter();
  assert.deepEqual(meter.read(0), { fps: 0, ms: null, level: 'idle' });
  // A second of steady movement at 60 Hz, each move shown 30 ms later.
  for (let i = 1; i <= 60; i++) { meter.moved(i, i * 16); meter.placed({ fps: 60, q: i }, i * 16 + 30); }
  assert.deepEqual(meter.read(1000), { fps: 60, ms: 30, level: 'ok' });
  // Updates that repeat a number show nothing new about the pointer and are not timed again.
  meter.placed({ fps: 60, q: 60 }, 1500);
  assert.equal(meter.read(1500).ms, 30);
  assert.deepEqual(meter.read(5000), { fps: 0, ms: 30, level: 'idle' });
});

test('the meter rates delay always, and the frame rate only while the pointer moves', () => {
  // `rate` is what the view runs at, as the agent names it in every update.
  const run = (shownEvery, delay, moving = true, rate = 60) => {
    const meter = new Meter();
    for (let i = 1; i <= 60; i++) {
      if (moving) meter.moved(i, i * 16);
      if (i % shownEvery === 0) meter.placed({ fps: rate, q: i }, i * 16 + (moving ? delay : 0));
    }
    return meter.read(1000 + (moving ? delay : 0)).level;
  };
  assert.equal(run(1, 30), 'ok');
  assert.equal(run(1, 80), 'mid');
  assert.equal(run(1, 200), 'bad');
  assert.equal(run(2, 30), 'mid', 'half the frames of a moving pointer');
  assert.equal(run(4, 30), 'bad');
  assert.equal(run(4, 0, false), 'ok', 'a clock ticking on a still screen needs no more');
  assert.equal(run(2, 30, true, 30), 'ok', 'a view the Mac runs at 30 fps is complete with 30');
});

test('a move that never shows does not grow the meter without bound', () => {
  const meter = new Meter();
  for (let i = 1; i <= 1000; i++) meter.moved(i, i);
  assert.equal(meter.sent.size, 240);
  meter.placed({ fps: 60, q: 1000 }, 1040);
  assert.equal(meter.sent.size, 0);
  assert.equal(meter.read(1040).ms, 40);
});

// Nothing else loads the page's own script before a browser does: it needs the page around it.
test('the page script parses', () => {
  const script = readFileSync(new URL('../Web/remote.js', import.meta.url), 'utf8');
  const check = spawnSync(process.execPath, ['--input-type=module', '--check'], { input: script, encoding: 'utf8' });
  assert.equal(check.status, 0, check.stderr);
});
