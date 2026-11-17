// Shared by content.js and offscreen.js: hardware H.264 via WebCodecs → JSON-safe messages.
// Messages: {k:'cfg', w, h, avcc}  (before the first frame and on every size change)
//           {k:'f', key, d}         (one access unit, AVCC length-prefixed, base64)
globalThis.MacPiPEncoder ??= class {
  constructor(send) {
    this.send = send;
    this.enc = null;
    this.w = this.h = this.n = 0;
    this.wantKey = true;
  }

  static b64(u8) {
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  }

  // Takes ownership of `frame`.
  encode(frame) {
    try {
      let w = frame.displayWidth, h = frame.displayHeight;
      const s = Math.min(1, 1920 / w, 1080 / h); // cap at 1080p: plenty for a PiP, cheap to encode
      w = Math.max(2, Math.round((w * s) / 2) * 2);
      h = Math.max(2, Math.round((h * s) / 2) * 2);
      if (!this.enc || this.enc.state === 'closed' || w !== this.w || h !== this.h) this.configure(w, h);
      if (this.enc.encodeQueueSize > 2) return; // behind: drop, never queue latency
      this.enc.encode(frame, { keyFrame: this.wantKey || this.n++ % 180 === 0 });
      this.wantKey = false;
    } catch (e) {
      console.warn('MacPiP encode', e);
    } finally {
      frame.close();
    }
  }

  configure(w, h) {
    try { this.enc?.close(); } catch (_) {}
    this.w = w; this.h = h; this.n = 0; this.wantKey = true;
    this.enc = new VideoEncoder({
      output: (chunk, meta) => {
        const desc = meta?.decoderConfig?.description;
        if (desc) {
          const u8 = desc instanceof ArrayBuffer ? new Uint8Array(desc) : new Uint8Array(desc.buffer, desc.byteOffset, desc.byteLength);
          this.send({ k: 'cfg', w: this.w, h: this.h, avcc: MacPiPEncoder.b64(u8) });
        }
        const buf = new Uint8Array(chunk.byteLength);
        chunk.copyTo(buf);
        this.send({ k: 'f', key: chunk.type === 'key', d: MacPiPEncoder.b64(buf) });
      },
      error: (e) => { console.warn('MacPiP encoder', e); this.enc = null; },
    });
    this.enc.configure({
      codec: 'avc1.640033',
      width: w, height: h,
      bitrate: Math.min(12e6, Math.max(2e6, w * h * 4)),
      framerate: 60,
      latencyMode: 'realtime',
      hardwareAcceleration: 'prefer-hardware',
      avc: { format: 'avc' },
    });
  }

  key() { this.wantKey = true; }
  close() { try { this.enc?.close(); } catch (_) {} this.enc = null; }
};
