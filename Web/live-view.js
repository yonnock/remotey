// The page's half of what Sources/Remotey/Wire.swift writes.
export const POINTER = 0, JPEG = 1, H264 = 2;

// One binary message of the live view, little endian: Uint8 kind, Uint8 frames per second the view runs at,
// Uint8 flags (1: the view follows the text caret, 2: it is fitted to the window in front, so its zoom is the
// Mac's choice), Float32 pointer x and y and Float32 focus x and y (0...1 inside the picture; the focus is the
// pointer, or the caret while the view follows the text), Float32 width and height of what the picture shows
// and Float32 its left and top edge (Mac points, in the coordinates the `displays` message uses), Uint32
// number of the last pointer move it includes, Uint32 number of the view request it was cut for, Uint32
// picture number, then the picture. POINTER has none: pointer or focus moved inside the picture sent last.
export const HEADER = 47;
export function parseUpdate(buffer) {
  const head = new DataView(buffer), float = (at) => head.getFloat32(at, true);
  return { kind: head.getUint8(0), fps: head.getUint8(1), followsText: (head.getUint8(2) & 1) === 1,
    fitted: (head.getUint8(2) & 2) === 2,
    x: float(3), y: float(7), fx: float(11), fy: float(15), width: float(19), height: float(23), left: float(27), top: float(31),
    q: head.getUint32(35, true), v: head.getUint32(39, true), n: head.getUint32(43, true),
    picture: new Uint8Array(buffer, HEADER) };
}

// The pointer ahead of the Mac's answer. A move takes the way to the Mac and back before an update shows
// it: 30 ms at home, 100 to 400 ms over a relay. So the page adds the moves that are still under way to the
// place the last update named, and the pointer follows the finger at once, whatever the link.
//
// It does what Input.swift does with a move of whole points, which is what the page sends: a target off every
// display is held at the edge of the display the pointer is on. Every update names the last move its place
// includes, so a move counts until an update has it. What the page cannot know, the Mac's own mouse or a
// pointer the Mac put elsewhere, comes with the next update, and the moves under way are added to that.
export class Ahead {
  constructor() {
    this.displays = null;
    this.moves = [];
  }

  // A move with the number `q` left for the Mac, in whole Mac points.
  moved(q, x, y) {
    this.moves.push({ q, x, y });
    // No update names them: another viewer has the live view. They say nothing about a later picture.
    if (this.moves.length > 512) this.moves.shift();
  }

  clear() {
    this.moves = [];
  }

  // Where the pointer is on the Mac once it has made the moves that `update` does not include, in Mac
  // points. Null if that is where the update has it: no move is under way, or the Mac's displays are not
  // known yet (the list is under way).
  onMac(update) {
    // Numbers wrap at 2^32.
    while (this.moves.length && ((this.moves[0].q - update.q) | 0) <= 0) this.moves.shift();
    if (!this.moves.length || !this.displays?.length || !(update.width > 0) || !(update.height > 0)) return null;
    // The place came as a share of the view in 32-bit floats. On the Mac it is whole points, or a fraction
    // the Mac's mouse left; a 16th of a point is finer than either and coarser than the floats' error.
    const exact = (value) => Math.round(value * 16) / 16;
    const on = (p) => this.displays.find((d) => p.x >= d.x && p.x < d.x + d.w && p.y >= d.y && p.y < d.y + d.h);
    let at = { x: exact(update.left + update.x * update.width), y: exact(update.top + update.y * update.height) };
    for (const move of this.moves) {
      const to = { x: at.x + move.x, y: at.y + move.y };
      if (!on(to)) {
        const home = on(at) ?? this.displays.find((d) => d.x === 0 && d.y === 0) ?? this.displays[0];
        to.x = Math.min(Math.max(to.x, home.x), home.x + home.w - 1);
        to.y = Math.min(Math.max(to.y, home.y), home.y + home.h - 1);
      }
      at = to;
    }
    return at;
  }

  // The pointer's place in the picture of `update`, 0...1: where the update has it, and from there the moves
  // it does not include.
  place(update) {
    const at = this.onMac(update);
    if (!at) return { x: update.x, y: update.y };
    const x = (at.x - update.left) / update.width, y = (at.y - update.top) / update.height;
    // The picture follows the pointer one way to the Mac and back later. Until then a pointer that was in
    // the picture waits at its edge, in sight.
    const inside = (value) => value >= 0 && value <= 1, held = (value) => Math.min(1, Math.max(0, value));
    return inside(update.x) && inside(update.y) ? { x: held(x), y: held(y) } : { x, y };
  }
}

// An H.264 picture as H264Encoder.swift packs it: profile, compatibility and level, a flag for a
// key frame, then Annex B.
export function parseH264(picture) {
  return { codec: 'avc1.' + [...picture.subarray(0, 3)].map((n) => n.toString(16).padStart(2, '0')).join(''),
    key: picture[3] === 1, data: picture.subarray(4) };
}

// Owns decoding for one WebSocket. Closing it invalidates every pending async callback.
export class LiveView {
  // `picture` holds the canvas and `aim`, which is moved to the pointer's place and holds the marker and
  // `cursor`, the pointer's picture. `shown` answers a picture by number, `placed` reports every update
  // that reached the display, and `fallback` says that `codec` is JPEG from now on, so the view has to be
  // asked for again.
  constructor(canvas, { picture, aim, cursor }, { shown, placed, fallback }) {
    this.canvas = canvas;
    this.picture = picture;
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
    this.meta = null;
    this.target = null;
    this.ahead = new Ahead();
    this.leads = false;
  }

  // The page shows the view or hides it. Hidden, nothing is drawn and the pointer is gone.
  show(on) {
    this.on = on;
    if (!on) {
      this.aim.hidden = true;
      this.ahead.clear(); // no update will name the moves under way
    }
    this.layout();
  }

  // Whether the pointer is drawn ahead of the Mac's answer. The page asks for that while the window in front
  // has the phone's shape: the picture then stands still, and the pointer moves in it. Where the picture
  // follows the pointer, a pointer ahead of it runs to the picture's edge and comes back as the picture
  // catches up, which is harder to steer than a pointer that waits for the Mac.
  lead(on) {
    if (on === this.leads) return;
    this.leads = on;
    if (!on) this.ahead.clear();
    this.placeAim();
  }

  // A pointer move of whole Mac points with the number `q` left for the Mac. Drawn ahead, the pointer goes
  // there at once: in a picture that is fitted to a window, not in one the Mac cuts around the pointer for
  // want of a window in front.
  moved(q, x, y) {
    if (!this.on || this.closed || !this.leads || !this.meta?.fitted) return;
    this.ahead.moved(q, x, y);
    this.placeAim();
  }

  // The Mac's displays, as the `displays` message lists them: where a move ends at an edge.
  setDisplays(list) {
    this.ahead.displays = list;
    this.placeAim();
  }

  /**
   * The zoom the page wants, in CSS pixels per Mac point. Until a picture of that zoom arrives (while a
   * pinch runs, or the request is under way) the picture at hand stands in, scaled around the point the
   * view is cut around, which is where the new picture will be centred. 0: the Mac picks the zoom (the view
   * is fitted to a window), so every picture is shown as it comes.
   */
  zoomTo(zoom) {
    this.target = zoom;
    this.layout();
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
      if (last) Object.assign(last, { x: meta.x, y: meta.y, fx: meta.fx, fy: meta.fy, followsText: meta.followsText, q: meta.q });
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
            // The decoder works: the watch starts over for the pictures still pending.
            clearTimeout(this.timer);
            this.timer = 0;
            if (this.pending.size) this.watch();
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
    if (!this.timer) this.watch();
    this.decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp, data }));
  }

  // A decoder that gives no picture back for two seconds while it has some must not leave the view stalled,
  // since the agent waits for answers. Pictures that keep coming out are no stall, however many are pending:
  // a burst after a Wi-Fi hold keeps some pending for a while, and a slow decoder lowers the frame rate.
  watch() {
    this.timer = setTimeout(() => this.useJPEG(), 2000);
  }

  draw(image, meta) {
    if (!this.on) return;
    const width = image.displayWidth ?? image.width, height = image.displayHeight ?? image.height;
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
    this.context.drawImage(image, 0, 0);
    this.place(meta, true);
  }

  place(meta, picture = false) {
    if (!this.on) return;
    this.meta = meta;
    this.layout();
    this.aim.hidden = false;
    // A fault of the page is no fault of the decoder: it must not switch the stream to JPEG.
    try { this.placed(meta, picture); } catch (error) { (globalThis.reportError ?? console.error)(error); }
  }

  /**
   * Where the picture lies on the display: drawn to cover it (`object-fit: cover`), so it is cropped,
   * never stretched, while the display changes size. Call when the display changed size.
   */
  box() {
    const w = this.canvas.clientWidth, h = this.canvas.clientHeight, pw = this.canvas.width, ph = this.canvas.height;
    if (!w || !h || !pw || !ph) return null;
    const scale = Math.max(w / pw, h / ph);
    return { left: (w - pw * scale) / 2, top: (h - ph * scale) / 2, width: pw * scale, height: ph * scale };
  }

  // Puts marker and pointer picture where the pointer is: where the last update has it, and from there
  // the moves the Mac has yet to answer. Runs with every move of the finger.
  placeAim(box = this.box()) {
    if (!box || !this.meta || !this.on) return;
    const at = this.ahead.place(this.meta);
    this.aim.style.transform = `translate3d(${box.left + at.x * box.width}px,${box.top + at.y * box.height}px,0)`;
  }

  // Moves marker and pointer picture, and scales the picture for a zoom preview. Only transforms change:
  // the browser moves layers, with no layout and no repaint.
  layout() {
    const box = this.box(), meta = this.meta;
    if (!box || !meta || !this.on) { this.picture.style.transform = ''; return; }
    this.placeAim(box);
    // The picture's own zoom follows from its width in Mac points and its width on the display.
    const scale = this.target ? this.target / (box.width / meta.width) : 1;
    if (Math.abs(scale - 1) < 0.01) this.picture.style.transform = '';
    else {
      const ax = box.left + meta.fx * box.width, ay = box.top + meta.fy * box.height;
      this.picture.style.transform = `translate(${ax}px,${ay}px) scale(${scale}) translate(${-ax}px,${-ay}px)`;
    }
    this.fitCursor();
  }

  // The Mac's pointer is not part of the stream. It arrives as a picture whenever its shape changes.
  setCursor({ png, w, h, x, y }) {
    if (this.closed) return;
    this.pointer = { w, h, x, y };
    this.cursor.src = 'data:image/png;base64,' + png;
    this.fitCursor();
  }

  // The pointer is as large as in the picture, but never below half its size on the Mac, so it stays
  // recognisable in the overview.
  fitCursor() {
    const box = this.box();
    if (!this.pointer || !this.meta?.width || !box) return;
    const scale = Math.max(0.5, box.width / this.meta.width), { w, h, x, y } = this.pointer;
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
      // The median, since a busy page makes some frames late. Rounded to 5: Safari's frame times wander around
      // 60 Hz (59 in the iOS Simulator), and a rate one off would restart the stream for nothing.
      const fps = Math.min(120, Math.max(30, Math.round(1000 / intervals[12] / 5) * 5));
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
