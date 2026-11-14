import assert from 'node:assert/strict';
import { test } from 'node:test';
import { LiveView, Meter } from '../Web/live-view.js';

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
  const canvas = { clientWidth: 390, getContext: () => ({ drawImage: (image) => drawn.push(image.timestamp) }) };
  const aim = { style: {} }, cursor = { style: {} };
  const player = new LiveView(canvas, { aim, cursor }, {
    visible: () => true, shown: (n) => shown.push(n), placed: (meta) => placed.push(meta), fallback: () => fallback++,
  });
  const output = (index, n) => outputs[index].output({
    timestamp: n, displayWidth: 640, displayHeight: 360, close: () => closed++,
  });
  return { player, chunks, drawn, shown, placed, outputs, output, canvas, aim, cursor, get fallback() { return fallback; }, get closed() { return closed; } };
}

function header(buffer, n, q = 0, x = 0.5, y = 0.25) {
  const head = new DataView(buffer);
  head.setFloat32(0, x, true); head.setFloat32(4, y, true); head.setUint32(8, n, true);
  head.setUint32(12, q, true); head.setFloat32(16, 780, true);
  return buffer;
}
function packet(n, key = true, level = 31, q = 0) {
  const buffer = header(new ArrayBuffer(29), n, q);
  new Uint8Array(buffer, 20).set([66, 192, level, +key, 0, 0, 0, 1, key ? 0x65 : 0x41]);
  return buffer;
}
/** A message without a picture: the pointer moved inside the view. */
const pointerOnly = (q, x, y) => header(new ArrayBuffer(20), 0, q, x, y);

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
  const jpeg = packet(1);
  new Uint8Array(jpeg, 20, 2).set([0xff, 0xd8]);
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
    const s = setup(), callbacks = new Map();
    let id = 0, changes = 0;
    globalThis.requestAnimationFrame = (callback) => { callbacks.set(++id, callback); return id; };
    globalThis.cancelAnimationFrame = (id) => callbacks.delete(id);
    s.player.measureFrameRate(() => changes++);
    for (let i = 0; i < 25; i++) {
      const [key, callback] = callbacks.entries().next().value;
      callbacks.delete(key);
      callback(i * 1000 / hz);
    }
    assert.equal(s.player.framesPerSecond, Math.min(hz, 120));
    assert.equal(changes, hz !== 60 ? 1 : 0);
    assert.equal(callbacks.size, 0);
    s.player.close();
  }
});

test('turning off the view or closing the connection cancels refresh measurement', () => {
  const s = setup(), callbacks = new Map();
  let id = 0;
  globalThis.requestAnimationFrame = (callback) => { callbacks.set(++id, callback); return id; };
  globalThis.cancelAnimationFrame = (id) => callbacks.delete(id);
  s.player.measureFrameRate(() => assert.fail('cancelled probe completed'));
  s.player.stopMeasuring();
  assert.equal(callbacks.size, 0);
  s.player.measureFrameRate(() => assert.fail('closed probe completed'));
  s.player.close();
  assert.equal(callbacks.size, 0);
});

test('a pointer move without a picture moves the marker at once and is not answered', async () => {
  const s = setup();
  try {
    s.player.receive(packet(1)); await s.player.chain;
    s.output(0, 1);
    s.player.receive(pointerOnly(7, 0.75, 0.5)); await s.player.chain;
    assert.equal(s.aim.style.transform, 'translate3d(75%,50%,0)');
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
    assert.equal(s.aim.style.transform, 'translate3d(50%,25%,0)');
    s.output(0, 2);
    assert.equal(s.aim.style.transform, 'translate3d(100%,100%,0)');
    assert.deepEqual(s.placed.map((meta) => meta.q), [0, 9]);
  } finally { s.player.close(); }
});

test('the pointer picture is as large as in the view, but at least half its size on the Mac', async () => {
  const s = setup();
  try {
    s.player.setCursor({ png: 'AAAA', w: 28, h: 40, x: 5, y: 5 });
    assert.equal(s.cursor.src, 'data:image/png;base64,AAAA');
    assert.equal(s.cursor.style.width, undefined, 'no size before the first picture tells the scale');
    s.player.receive(packet(1)); await s.player.chain;
    s.output(0, 1); // 780 points on 390 pixels
    assert.deepEqual([s.cursor.style.width, s.cursor.style.height], ['14px', '20px']);
    assert.equal(s.cursor.style.transform, 'translate(-2.5px,-2.5px)');
    s.canvas.clientWidth = 195; // a quarter of the Mac's size would be too small to see
    s.player.fitCursor();
    assert.equal(s.cursor.style.width, '14px');
    s.canvas.clientWidth = 1560;
    s.player.fitCursor();
    assert.deepEqual([s.cursor.style.width, s.cursor.style.transform], ['56px', 'translate(-10px,-10px)']);
  } finally { s.player.close(); }
});

test('the meter counts updates per second and times a move until it shows', () => {
  const meter = new Meter();
  assert.deepEqual(meter.read(0, 60), { fps: 0, ms: null, level: 'idle' });
  // A second of steady movement at 60 Hz, each move shown 30 ms later.
  for (let i = 1; i <= 60; i++) { meter.moved(i, i * 16); meter.placed(i, i * 16 + 30); }
  assert.deepEqual(meter.read(1000, 60), { fps: 60, ms: 30, level: 'ok' });
  // Messages that repeat a number show nothing new about the pointer and are not timed again.
  meter.placed(60, 1500);
  assert.equal(meter.read(1500, 60).ms, 30);
  assert.deepEqual(meter.read(5000, 60), { fps: 0, ms: 30, level: 'idle' });
});

test('the meter rates delay always, and the frame rate only while the pointer moves', () => {
  const run = (shownEvery, delay, moving = true) => {
    const meter = new Meter();
    for (let i = 1; i <= 60; i++) {
      if (moving) meter.moved(i, i * 16);
      if (i % shownEvery === 0) meter.placed(i, i * 16 + (moving ? delay : 0));
    }
    return meter.read(1000 + (moving ? delay : 0), 60).level;
  };
  assert.equal(run(1, 30), 'ok');
  assert.equal(run(1, 80), 'mid');
  assert.equal(run(1, 200), 'bad');
  assert.equal(run(2, 30), 'mid', 'half the frames of a moving pointer');
  assert.equal(run(4, 30), 'bad');
  assert.equal(run(4, 0, false), 'ok', 'a clock ticking on a still screen needs no more');
});

test('a move that never shows does not grow the meter without bound', () => {
  const meter = new Meter();
  for (let i = 1; i <= 1000; i++) meter.moved(i, i);
  assert.equal(meter.sent.size, 240);
  meter.placed(1000, 1040);
  assert.equal(meter.sent.size, 0);
  assert.equal(meter.read(1040, 60).ms, 40);
});
