// The page's half of what Sources/Remotey/Wire.swift writes.
export const POINTER = 0, JPEG = 1, H264 = 2;

// One binary message of the live view, little endian: Uint8 kind, Uint8 frames per second the view runs at,
// Float32 pointer x and y (0...1 inside the picture), Float32 picture width in Mac points, Uint32 number of
// the last pointer move it includes, Uint32 picture number, then the picture. POINTER has none: the pointer
// moved inside the picture sent last.
export function parseUpdate(buffer) {
  const head = new DataView(buffer);
  return { kind: head.getUint8(0), fps: head.getUint8(1), x: head.getFloat32(2, true), y: head.getFloat32(6, true),
    width: head.getFloat32(10, true), q: head.getUint32(14, true), n: head.getUint32(18, true),
    picture: new Uint8Array(buffer, 22) };
}

// An H.264 picture as H264Encoder.swift packs it: profile, compatibility and level, a flag for a
// key frame, then Annex B.
export function parseH264(picture) {
  return { codec: 'avc1.' + [...picture.subarray(0, 3)].map((n) => n.toString(16).padStart(2, '0')).join(''),
    key: picture[3] === 1, data: picture.subarray(4) };
}

// Owns decoding for one WebSocket. Closing it invalidates every pending async callback.
export class LiveView {
  // `aim` is moved to the pointer's place and holds the marker and `cursor`, the pointer's picture.
  // `shown` answers a picture by number, `placed` reports every update that reached the display, and
  // `fallback` says that `codec` is JPEG from now on, so the view has to be asked for again.
  constructor(canvas, { aim, cursor }, { shown, placed, fallback }) {
    this.canvas = canvas;
    // Opaque and not bound to the page's own drawing where the browser allows it: less work per frame.
    this.context = canvas.getContext('2d', { alpha: false, desynchronized: true });
    this.aim = aim;
    this.cursor = cursor;
    this.shown = shown;
    this.placed = placed;
    this.fallback = fallback;
    this.on = false;
    this.codec = typeof VideoDecoder === 'function' ? 'h264' : 'jpeg';
    this.pending = new Map();
    this.chain = Promise.resolve();
    this.epoch = 0;
    this.timer = 0;
    this.decoder = null;
    this.decoderCodec = null;
    this.closed = false;
    this.pointer = null;
    this.viewWidth = 0;
  }

  // The page shows the view or hides it. Hidden, nothing is drawn and the pointer is gone.
  show(on) {
    this.on = on;
    if (!on) this.aim.hidden = true;
  }

  receive(buffer) {
    const epoch = this.epoch;
    // Serialize submissions, not decoder outputs: some decoders need a second input before output.
    this.chain = this.chain.then(() => {
      if (!this.closed && epoch === this.epoch) return this.decode(buffer, epoch);
    }).catch(() => this.useJPEG());
  }

  async decode(buffer, epoch) {
    const { kind, picture, ...meta } = parseUpdate(buffer);
    if (kind === POINTER) {
      // While the picture sent last is still being decoded, the new place waits with it:
      // the pointer never runs ahead of its picture.
      const last = [...this.pending.values()].at(-1);
      if (last) Object.assign(last, { x: meta.x, y: meta.y, q: meta.q });
      else this.place(meta);
      return;
    }
    if (kind === JPEG) {
      // Also handles a Mac without the required low-latency hardware encoder.
      if (this.codec !== 'jpeg') { this.useJPEG(); return; }
      let image;
      try {
        image = await createImageBitmap(new Blob([picture], { type: 'image/jpeg' }));
        if (!this.closed && epoch === this.epoch) this.draw(image, meta);
      } finally {
        image?.close();
        if (!this.closed && epoch === this.epoch) this.shown(meta.n);
      }
      return;
    }
    if (kind !== H264 || this.codec !== 'h264') return;
    const { codec, key, data } = parseH264(picture);
    if (!this.decoder || this.decoderCodec !== codec) {
      if (!key) throw new Error('H.264 stream must start with an IDR');
      const config = { codec, optimizeForLatency: true };
      if (!(await VideoDecoder.isConfigSupported(config)).supported) throw new Error('H.264 config unsupported');
      if (this.closed || epoch !== this.epoch) return;
      this.releaseDecoder();
      this.decoderCodec = codec;
      const decoder = this.decoder = new VideoDecoder({
        output: (image) => {
          try {
            if (this.closed || epoch !== this.epoch || this.decoder !== decoder) return;
            const meta = this.pending.get(image.timestamp);
            if (!meta) return;
            this.pending.delete(image.timestamp);
            this.draw(image, meta);
            this.shown(meta.n);
            if (!this.pending.size) { clearTimeout(this.timer); this.timer = 0; }
          } catch { this.useJPEG(); }
          finally { image.close(); }
        },
        error: () => { if (!this.closed && epoch === this.epoch && this.decoder === decoder) this.useJPEG(); },
      });
      this.decoder.configure(config);
    }
    // These timestamps correlate output to acknowledgements; frames are drawn immediately, not paced by them.
    const timestamp = meta.n;
    this.pending.set(timestamp, meta);
    // A decoder which buffers more than the agent's window of pictures must not leave the view stalled.
    if (!this.timer) this.timer = setTimeout(() => this.useJPEG(), 2000);
    this.decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp, data }));
  }

  draw(image, meta) {
    if (!this.on) return;
    const width = image.displayWidth ?? image.width, height = image.displayHeight ?? image.height;
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
    this.context.drawImage(image, 0, 0);
    this.place(meta);
  }

  // Moves marker and pointer picture. `aim` covers the display, so a shift in percent of its own size
  // is a place inside the picture, and the browser only has to move a layer: no layout, no repaint.
  place(meta) {
    if (!this.on) return;
    this.aim.style.transform = `translate3d(${meta.x * 100}%,${meta.y * 100}%,0)`;
    this.aim.hidden = false;
    if (meta.width !== this.viewWidth) {
      this.viewWidth = meta.width;
      this.fitCursor();
    }
    this.placed(meta);
  }

  // The Mac's pointer is not part of the stream. It arrives as a picture whenever its shape changes.
  setCursor({ png, w, h, x, y }) {
    if (this.closed) return;
    this.pointer = { w, h, x, y };
    this.cursor.src = 'data:image/png;base64,' + png;
    this.fitCursor();
  }

  // Call when the display changed size. The pointer is as large as in the picture, but never below
  // half its size on the Mac, so it stays recognisable in the overview.
  fitCursor() {
    const display = this.canvas.clientWidth;
    if (!this.pointer || !this.viewWidth || !display) return;
    const scale = Math.max(0.5, display / this.viewWidth), { w, h, x, y } = this.pointer;
    Object.assign(this.cursor.style, { width: w * scale + 'px', height: h * scale + 'px',
      transform: `translate(${-x * scale}px,${-y * scale}px)` });
  }

  releaseDecoder() {
    if (this.decoder && this.decoder.state !== 'closed') this.decoder.close();
    this.decoder = null;
    for (const meta of this.pending.values()) this.shown(meta.n); // discarded on a config change
    this.pending.clear();
    clearTimeout(this.timer);
    this.timer = 0;
  }

  useJPEG() {
    if (this.closed || this.codec === 'jpeg') return;
    this.epoch++;
    this.releaseDecoder();
    this.codec = 'jpeg';
    this.fallback();
  }

  close() {
    this.closed = true;
    this.epoch++;
    this.releaseDecoder();
  }
}

// The display's rendering cadence, measured rather than taken from the device name: ProMotion can still
// be limited to 60 Hz by Safari. It belongs to the page, not to a connection: the next one asks for the
// same rate at once instead of starting over at 60.
export class Cadence {
  // `changed` runs when a probe finds another rate than the last one.
  constructor(changed) {
    this.framesPerSecond = 60;
    this.changed = changed;
    this.probe = 0;
  }

  measure() {
    this.stop();
    const intervals = [];
    let previous;
    const sample = (time) => {
      if (previous !== undefined) intervals.push(time - previous);
      previous = time;
      if (intervals.length < 24) { this.probe = requestAnimationFrame(sample); return; }
      this.probe = 0;
      intervals.sort((a, b) => a - b);
      const fps = Math.min(120, Math.max(30, Math.round(1000 / intervals[12])));
      if (fps !== this.framesPerSecond) { this.framesPerSecond = fps; this.changed(); }
    };
    this.probe = requestAnimationFrame(sample);
  }

  stop() {
    if (this.probe) cancelAnimationFrame(this.probe);
    this.probe = 0;
  }
}

// How good the live view is right now: updates of the display per second, and the time from sending a
// pointer move until the display shows it (the way to the Mac and back, encoding and decoding).
export class Meter {
  constructor() {
    this.shown = [];
    this.moves = [];
    this.sent = new Map();
    this.delay = null;
    this.target = 0;
  }

  // A pointer move with this number left for the Mac.
  moved(q, now) {
    this.moves.push(now);
    this.sent.set(q, now);
    if (this.sent.size > 240) this.sent.delete(this.sent.keys().next().value);
  }

  // The display shows an update: of a view that runs at `fps`, including the move with the number `q`.
  placed({ fps, q }, now) {
    this.target = fps;
    this.shown.push(now);
    const left = this.sent.get(q);
    if (left === undefined) return;
    // Later updates with the same number show nothing new about the pointer.
    for (const key of this.sent.keys()) { this.sent.delete(key); if (key === q) break; }
    this.delay = this.delay === null ? now - left : this.delay + (now - left - this.delay) * 0.2;
  }

  // A still screen sends nothing, so only a moving pointer shows whether the view's rate is reached.
  // level: 'idle', 'ok', 'mid' or 'bad'.
  read(now) {
    const target = this.target;
    const recent = (times) => { while (times.length && now - times[0] > 1000) times.shift(); return times.length; };
    const fps = recent(this.shown), moving = recent(this.moves) >= target / 2;
    const ms = this.delay === null ? null : Math.round(this.delay);
    let level = 'ok';
    if (!fps) level = 'idle';
    else if (ms > 120 || (moving && fps < target * 0.4)) level = 'bad';
    else if (ms > 60 || (moving && fps < target * 0.7)) level = 'mid';
    return { fps, ms, level };
  }
}
