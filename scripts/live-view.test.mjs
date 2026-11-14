import assert from 'node:assert/strict';
import { test } from 'node:test';
import { LiveView } from '../Web/live-view.js';

function setup() {
  const outputs = [], chunks = [], drawn = [], shown = [];
  let fallback = 0, closed = 0;
  globalThis.VideoDecoder = class {
    static async isConfigSupported() { return { supported: true }; }
    constructor(callbacks) { this.state = 'unconfigured'; outputs.push(callbacks); }
    configure() { this.state = 'configured'; }
    decode(chunk) { chunks.push(chunk); }
    close() { this.state = 'closed'; }
  };
  globalThis.EncodedVideoChunk = class { constructor(init) { Object.assign(this, init); } };
  const canvas = { getContext: () => ({ drawImage: (image) => drawn.push(image.timestamp) }) };
  const player = new LiveView(canvas, { style: {} }, {
    visible: () => true, shown: (n) => shown.push(n), fallback: () => fallback++,
  });
  const output = (index, n) => outputs[index].output({
    timestamp: n, displayWidth: 640, displayHeight: 360, close: () => closed++,
  });
  return { player, chunks, drawn, shown, outputs, output, canvas, get fallback() { return fallback; }, get closed() { return closed; } };
}

function packet(n, key = true, level = 31) {
  const buffer = new ArrayBuffer(21), head = new DataView(buffer);
  head.setFloat32(0, 0.5, true); head.setFloat32(4, 0.25, true); head.setUint32(8, n, true);
  new Uint8Array(buffer, 12).set([66, 192, level, +key, 0, 0, 0, 1, key ? 0x65 : 0x41]);
  return buffer;
}

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
  new Uint8Array(jpeg, 12, 2).set([0xff, 0xd8]);
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
