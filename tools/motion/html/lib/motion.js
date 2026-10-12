// Small deterministic helpers for motion pages (served at /__motion/motion.js; plain ES module, no deps).
//   import { ease, clamp, lerp, remap, env, rng, noise1, loadImage, ImageSeq, Timeline, fontsReady } from "/__motion/motion.js";
// Everything is a pure function of time: renderFrame(i, fps) -> t = i / fps -> draw.

export const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
export const lerp = (a, b, u) => a + (b - a) * u;
export const remap = (x, a, b, c = 0, d = 1) => lerp(c, d, clamp((x - a) / (b - a)));
/** 0..1 progress of t through [a, b] */
export const prog = (t, a, b) => clamp((t - a) / (b - a));

export const ease = {
  linear: (u) => u,
  inSine: (u) => 1 - Math.cos((u * Math.PI) / 2),
  outSine: (u) => Math.sin((u * Math.PI) / 2),
  inOutSine: (u) => 0.5 - 0.5 * Math.cos(u * Math.PI),
  inQuad: (u) => u * u,
  outQuad: (u) => 1 - (1 - u) * (1 - u),
  inOutQuad: (u) => (u < 0.5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2),
  inCubic: (u) => u * u * u,
  outCubic: (u) => 1 - Math.pow(1 - u, 3),
  inOutCubic: (u) => (u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2),
  outQuart: (u) => 1 - Math.pow(1 - u, 4),
  inOutQuart: (u) => (u < 0.5 ? 8 * u ** 4 : 1 - Math.pow(-2 * u + 2, 4) / 2),
  outQuint: (u) => 1 - Math.pow(1 - u, 5),
  outExpo: (u) => (u >= 1 ? 1 : 1 - Math.pow(2, -10 * u)),
  inOutExpo: (u) => (u <= 0 ? 0 : u >= 1 ? 1 : u < 0.5 ? Math.pow(2, 20 * u - 10) / 2 : (2 - Math.pow(2, -20 * u + 10)) / 2),
  outBack: (u, s = 1.70158) => 1 + (s + 1) * Math.pow(u - 1, 3) + s * Math.pow(u - 1, 2),
  outElastic: (u) => (u <= 0 ? 0 : u >= 1 ? 1 : Math.pow(2, -10 * u) * Math.sin((u * 10 - 0.75) * ((2 * Math.PI) / 3)) + 1),
  /** critically damped spring 0 -> 1, k = stiffness-ish (6..14) */
  spring: (u, k = 9, z = 0.55) => 1 - Math.exp(-z * k * u) * Math.cos(k * Math.sqrt(1 - z * z) * u),
};

/** attack / hold / release envelope: 0 before a, ramps to 1 over [a, a+in], 1 until b-out, ramps to 0 by b */
export function env(t, a, b, fadeIn = 0.3, fadeOut = 0.3, e = ease.inOutSine) {
  if (t <= a || t >= b) return 0;
  const i = fadeIn > 0 ? clamp((t - a) / fadeIn) : 1;
  const o = fadeOut > 0 ? clamp((b - t) / fadeOut) : 1;
  return e(Math.min(i, o));
}

/** seeded PRNG (mulberry32); rng(seed)() -> [0,1). Same seed, same sequence, in every worker. */
export function rng(seed = 1) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
/** stable hash of an integer (and optional salt) to [0,1) */
export const hash1 = (n, salt = 0) => {
  let x = Math.imul((n | 0) ^ Math.imul(salt | 0, 0x9e3779b1), 0x85ebca6b);
  x ^= x >>> 13; x = Math.imul(x, 0xc2b2ae35); x ^= x >>> 16;
  return (x >>> 0) / 4294967296;
};
/** smooth 1D value noise, deterministic */
export function noise1(x, salt = 0) {
  const i = Math.floor(x), f = x - i, u = f * f * (3 - 2 * f);
  return lerp(hash1(i, salt), hash1(i + 1, salt), u) * 2 - 1;
}

export const fontsReady = () => (document.fonts ? document.fonts.ready : Promise.resolve());

export function loadImage(src) {
  return new Promise((ok, fail) => {
    const im = new Image();
    im.decoding = "sync";
    im.onload = () => ok(im);
    im.onerror = () => fail(new Error("image failed: " + src));
    im.src = src;
  });
}

/** A frame sequence (e.g. a Godot plate under /__scratch/.../frame_%05d.png) loaded on demand, with a small cache. */
export class ImageSeq {
  constructor(pattern, { first = 0, count = Infinity, cache = 8 } = {}) { this.pattern = pattern; this.first = first; this.count = count; this.cacheSize = cache; this.cache = new Map(); }
  url(i) { const n = this.first + Math.max(0, Math.min(this.count - 1, i)); return this.pattern.replace(/%0(\d)d/, (_, w) => String(n).padStart(Number(w), "0")); }
  async get(i) {
    const u = this.url(i);
    if (!this.cache.has(u)) {
      this.cache.set(u, loadImage(u));
      if (this.cache.size > this.cacheSize) this.cache.delete(this.cache.keys().next().value);
    }
    return this.cache.get(u);
  }
}

/** Declarative timeline of named cues: tl.at("title", 1.2, 2.0) then tl.p("title", t) -> 0..1 */
export class Timeline {
  constructor() { this.cues = {}; }
  at(name, start, dur) { this.cues[name] = [start, dur]; return this; }
  p(name, t, e = ease.linear) { const [s, d] = this.cues[name]; return e(clamp((t - s) / d)); }
  on(name, t) { const [s, d] = this.cues[name]; return t >= s && t < s + d; }
}

/** Draw text along a baseline with per-glyph reveal; ctx.font must be set. Returns total advance. */
export function revealText(ctx, text, x, y, u, { stagger = 0.08, rise = 18, spacing = 0 } = {}) {
  const chars = [...text];
  let cx = x;
  const n = chars.length;
  chars.forEach((ch, k) => {
    const w = ctx.measureText(ch).width;
    const local = clamp((u * (1 + stagger * (n - 1)) - k * stagger));
    const e = ease.outCubic(local);
    ctx.save();
    ctx.globalAlpha *= e;
    ctx.fillText(ch, cx, y + (1 - e) * rise);
    ctx.restore();
    cx += w + spacing;
  });
  return cx - x;
}
