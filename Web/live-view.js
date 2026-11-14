// Owns decoding for one WebSocket. Closing it invalidates every pending async callback.
export class LiveView {
  constructor(canvas, marker, { visible, shown, fallback }) {
    this.canvas = canvas;
    this.context = canvas.getContext('2d');
    this.marker = marker;
    this.visible = visible;
    this.shown = shown;
    this.fallback = fallback;
    this.codec = typeof VideoDecoder === 'function' ? 'h264' : 'jpeg';
    this.framesPerSecond = 60;
    this.pending = new Map();
    this.chain = Promise.resolve();
    this.epoch = 0;
    this.timer = 0;
    this.decoder = null;
    this.closed = false;
    this.refreshProbe = 0;
  }

  // Measure rendering cadence, not the device name: ProMotion can still be limited to 60 Hz by Safari.
  // Probe only while the view is on, and cancel when its connection closes or the view turns off.
  measureFrameRate(changed) {
    this.stopMeasuring();
    if (this.closed || this.codec !== 'h264') return;
    const intervals = [];
    let previous;
    const sample = (time) => {
      if (previous !== undefined) intervals.push(time - previous);
      previous = time;
      if (intervals.length < 24) { this.refreshProbe = requestAnimationFrame(sample); return; }
      this.refreshProbe = 0;
      intervals.sort((a, b) => a - b);
      const fps = Math.min(120, Math.max(30, Math.round(1000 / intervals[12])));
      if (fps !== this.framesPerSecond) { this.framesPerSecond = fps; changed(); }
    };
    this.refreshProbe = requestAnimationFrame(sample);
  }

  stopMeasuring() {
    if (this.refreshProbe) cancelAnimationFrame(this.refreshProbe);
    this.refreshProbe = 0;
  }

  receive(buffer) {
    const epoch = this.epoch;
    // Serialize submissions, not decoder outputs: some decoders need a second input before output.
    this.chain = this.chain.then(() => {
      if (!this.closed && epoch === this.epoch) return this.decode(buffer, epoch);
    }).catch(() => this.useJPEG());
  }

  async decode(buffer, epoch) {
    const head = new DataView(buffer);
    const meta = { n: head.getUint32(8, true), x: head.getFloat32(0, true), y: head.getFloat32(4, true) };
    if (head.getUint16(12) === 0xffd8) {
      // Also handles a Mac without the required low-latency hardware encoder.
      if (this.codec !== 'jpeg') { this.useJPEG(); return; }
      let image;
      try {
        image = await createImageBitmap(new Blob([new Uint8Array(buffer, 12)], { type: 'image/jpeg' }));
        if (!this.closed && epoch === this.epoch) this.draw(image, meta);
      } finally {
        image?.close();
        if (!this.closed && epoch === this.epoch) this.shown(meta.n);
      }
      return;
    }
    if (this.codec !== 'h264') return;
    const key = head.getUint8(15) === 1;
    const codec = 'avc1.' + [...new Uint8Array(buffer, 12, 3)].map((n) => n.toString(16).padStart(2, '0')).join('');
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
    // A decoder which buffers more than our two-frame window must not leave the view stalled.
    if (!this.timer) this.timer = setTimeout(() => this.useJPEG(), 2000);
    this.decoder.decode(new EncodedVideoChunk({
      type: key ? 'key' : 'delta', timestamp, data: new Uint8Array(buffer, 16),
    }));
  }

  draw(image, meta) {
    if (!this.visible()) return;
    const width = image.displayWidth ?? image.width, height = image.displayHeight ?? image.height;
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
    this.context.drawImage(image, 0, 0);
    this.marker.style.left = meta.x * 100 + '%';
    this.marker.style.top = meta.y * 100 + '%';
    this.marker.hidden = false;
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
    this.stopMeasuring();
    this.releaseDecoder();
    this.codec = 'jpeg';
    this.fallback();
  }

  close() {
    this.closed = true;
    this.epoch++;
    this.stopMeasuring();
    this.releaseDecoder();
  }
}
