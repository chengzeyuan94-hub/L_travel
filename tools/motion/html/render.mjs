#!/usr/bin/env node
// Deterministic HTML -> PNG frame renderer (headless Chrome over the DevTools protocol; node >= 22, no npm).
//
//   node tools/motion/html/render.mjs PAGE.html --out DIR [--frames 0:450] [--fps 30] [--workers 4]
//        [--alpha] [--size 1920x1080] [--query "k=v&k2=v2"] [--only 12,40] [--timeout 120] [--keep-profile]
//
// Page contract (see tools/motion/README.md, "HTML pages"):
//   window.setupScene(info)          optional, awaited once per worker; info = {width, height, fps, alpha, frames:[a,b], worker}
//   window.renderFrame(i, fps)       required, awaited per frame; must draw frame i as a pure function of i
//                                    (random access: workers render contiguous chunks in parallel)
// The renderer also, before each frame:
//   * sets a virtual clock: performance.now() / Date.now() return i/fps seconds (from 0 / from a fixed epoch);
//     requestAnimationFrame callbacks are never needed (they still fire, but do not rely on them);
//   * Math.random is a seeded PRNG (same sequence in every worker; seed with --seed);
//   and after renderFrame resolves it seeks every CSS / Web Animation (document.getAnimations()) and every SVG
//   SMIL timeline to t = i/fps, waits for fonts and images, then captures the viewport (Page.captureScreenshot).
// --alpha: transparent page background -> RGBA PNGs (the page must not paint an opaque background itself).
//
// Static server: the page's own directory is served at /, plus
//   /__repo/<path>     the repository (worktree) root, read-only (game assets, card art, CG, fonts in repo)
//   /__scratch/<path>  the motion scratch dir (Godot plates, intermediates)
//   /__fonts/<file>    system CJK font files (see FONT_FILES; /__motion/fonts.css declares them)
//   /__motion/<file>   tools/motion/html/lib (fonts.css, motion.js helpers)
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../../..");
const SCRATCH = "/private/tmp/claude-501/-Users-chengzeyuan-Developer-SilkRoad/881e8717-f317-4a7f-9cf5-81713e061c3a/scratchpad/motion";
const CHROME = process.env.MOTION_CHROME || path.join(os.homedir(), ".cache/puppeteer/chrome-headless-shell/mac_arm-153.0.8010.36/chrome-headless-shell-mac-arm64/chrome-headless-shell");
const ASSETS = "/System/Library/AssetsV2";

// ------------------------------------------------------------------ args
function parseArgs(argv) {
  const a = { fps: 30, workers: Math.max(1, Math.min(6, Math.floor(os.cpus().length / 4))), size: "1920x1080", query: "", timeout: 120, seed: 1234 };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => argv[++i];
    if (k === "--out") a.out = v();
    else if (k === "--frames") a.frames = v();
    else if (k === "--fps") a.fps = Number(v());
    else if (k === "--workers") a.workers = Number(v());
    else if (k === "--alpha") a.alpha = true;
    else if (k === "--size") a.size = v();
    else if (k === "--query") a.query = v();
    else if (k === "--only") a.only = v();
    else if (k === "--timeout") a.timeout = Number(v());
    else if (k === "--seed") a.seed = Number(v());
    else if (k === "--keep-profile") a.keepProfile = true;
    else if (k === "--gpu") a.gpu = v();
    else if (k === "-h" || k === "--help") a.help = true;
    else rest.push(k);
  }
  a.page = rest[0];
  return a;
}

// ------------------------------------------------------------------ static server
const MIME = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css",
  ".json": "application/json", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp",
  ".svg": "image/svg+xml", ".gif": "image/gif", ".otf": "font/otf", ".ttf": "font/ttf", ".ttc": "font/collection",
  ".woff": "font/woff", ".woff2": "font/woff2", ".wav": "audio/wav", ".ogg": "audio/ogg", ".mp4": "video/mp4",
  ".webm": "video/webm", ".glsl": "text/plain", ".txt": "text/plain", ".bin": "application/octet-stream" };

// family name -> file (downloadable macOS fonts live under AssetsV2 with hashed folder names: resolve at start)
const FONT_FILES = ["WawaSC-Regular.otf", "WawaTC-Regular.otf", "Yuanti.ttc", "Kaiti.ttc", "Xingkai.ttc", "Libian.ttc", "Hanzipen.ttc",
  "Hannotate.ttc", "Baoli.ttc", "WeibeiSC-Bold.otf", "YuppySC-Regular.otf", "Lantinghei.ttc", "PingFang.ttc"];
function findFonts() {
  const map = {};
  const walk = (dir, depth) => {
    let ents = [];
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = path.join(dir, e.name);
      if (e.isDirectory() && depth < 4) walk(p, depth + 1);
      else if (FONT_FILES.includes(e.name) && !map[e.name]) map[e.name] = p;
    }
  };
  walk(ASSETS, 0);
  for (const f of ["/System/Library/Fonts/Supplemental/Songti.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc", "/Library/Fonts/Arial Unicode.ttf"])
    if (fs.existsSync(f)) map[path.basename(f)] = f;
  return map;
}

function startServer(pageDir, fonts) {
  const roots = { "/__repo/": REPO, "/__scratch/": SCRATCH, "/__motion/": path.join(HERE, "lib") };
  const server = http.createServer((req, res) => {
    let u = decodeURIComponent(new URL(req.url, "http://x").pathname);
    let file = null;
    if (u.startsWith("/__fonts/")) file = fonts[u.slice(9)] || null;
    else {
      for (const [pre, root] of Object.entries(roots)) if (u.startsWith(pre)) { file = path.join(root, u.slice(pre.length)); if (!file.startsWith(root)) file = null; break; }
      if (file === null && !u.startsWith("/__")) { file = path.join(pageDir, u); if (!file.startsWith(pageDir)) file = null; }
    }
    if (!file || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end("not found: " + u); return; }
    res.writeHead(200, { "Content-Type": MIME[path.extname(file).toLowerCase()] || "application/octet-stream", "Access-Control-Allow-Origin": "*", "Cache-Control": "max-age=3600" });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok(server)));
}

// ------------------------------------------------------------------ chrome + CDP
async function launchChrome(profile, gpu) {
  fs.rmSync(profile, { recursive: true, force: true });
  fs.mkdirSync(profile, { recursive: true });
  const args = [`--user-data-dir=${profile}`, "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check",
    "--hide-scrollbars", "--mute-audio", "--force-color-profile=srgb", "--font-render-hinting=none", "--disable-lcd-text",
    "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
    "--allow-file-access-from-files", "--autoplay-policy=no-user-gesture-required", "--enable-unsafe-swiftshader",
    "--ignore-gpu-blocklist"];
  if (gpu === "swiftshader") args.push("--use-angle=swiftshader");
  else if (gpu !== "default") args.push("--use-angle=metal");
  args.push("about:blank");
  const proc = spawn(CHROME, args, { stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  proc.stderr.on("data", (d) => { stderr += d.toString(); if (stderr.length > 20000) stderr = stderr.slice(-10000); });
  const portFile = path.join(profile, "DevToolsActivePort");
  for (let i = 0; i < 300; i++) {
    if (fs.existsSync(portFile)) {
      const port = Number(fs.readFileSync(portFile, "utf8").split("\n")[0]);
      if (port) return { proc, port, stderr: () => stderr };
    }
    await sleep(50);
  }
  proc.kill("SIGKILL");
  throw new Error("chrome did not start: " + stderr.slice(-2000));
}

class CDP {
  constructor(url) { this.url = url; this.id = 0; this.pending = new Map(); this.listeners = []; }
  open() {
    return new Promise((ok, fail) => {
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => ok();
      this.ws.onerror = (e) => fail(new Error("websocket error " + (e.message || "")));
      this.ws.onmessage = (ev) => {
        const m = JSON.parse(typeof ev.data === "string" ? ev.data : Buffer.from(ev.data).toString());
        if (m.id && this.pending.has(m.id)) {
          const { ok: res, fail: rej } = this.pending.get(m.id);
          this.pending.delete(m.id);
          if (m.error) rej(new Error(m.error.message + " " + (m.error.data || ""))); else res(m.result);
        } else if (m.method) for (const l of this.listeners) l(m);
      };
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((ok, fail) => { this.pending.set(id, { ok, fail }); this.ws.send(JSON.stringify({ id, method, params })); });
  }
  once(method, timeoutMs) {
    return new Promise((ok, fail) => {
      const t = setTimeout(() => fail(new Error("timeout waiting for " + method)), timeoutMs);
      const l = (m) => { if (m.method === method) { clearTimeout(t); this.listeners = this.listeners.filter((x) => x !== l); ok(m.params); } };
      this.listeners.push(l);
    });
  }
  close() { try { this.ws.close(); } catch {} }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The timer must be cleared when p settles: a pending timeout keeps the race promise — and with it the resolved value,
// i.e. every multi-MB screenshot — alive for `ms`, which exhausted node's 4 GB heap after ~1150 1080p frames.
const withTimeout = (p, ms, what) => {
  let timer;
  return Promise.race([p, new Promise((_, f) => { timer = setTimeout(() => f(new Error("timeout: " + what)), ms); })]).finally(() => clearTimeout(timer));
};

// injected before any page script: virtual clock + seeded Math.random + frame helpers
function prelude(seed, fps) {
  return `(() => {
  let __t = 0; const __epoch = 1790000000000;
  const pn = performance.now.bind(performance);
  Object.defineProperty(window, "__motionTime", { get: () => __t, set: (v) => { __t = v; } });
  performance.now = () => __t * 1000;
  Date.now = () => __epoch + Math.round(__t * 1000);
  let s = ${seed >>> 0};
  Math.random = () => { s |= 0; s = s + 0x6D2B79F5 | 0; let t = Math.imul(s ^ s >>> 15, 1 | s); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  window.__motion = { fps: ${fps}, realNow: pn,
    seekTimelines(t) {
      for (const a of document.getAnimations ? document.getAnimations() : []) { try { a.pause(); a.currentTime = t * 1000; } catch (e) {} }
      for (const svg of document.querySelectorAll("svg")) { if (svg.pauseAnimations) { svg.pauseAnimations(); svg.setCurrentTime(t); } }
    },
    async settle() {
      if (document.fonts && document.fonts.ready) await document.fonts.ready;
      const imgs = [...document.images].filter((im) => !im.complete);
      await Promise.all(imgs.map((im) => new Promise((r) => { im.onload = im.onerror = r; })));
      if (window.__motionBeforeCapture) await window.__motionBeforeCapture();
    } };
})();`;
}

async function runWorker(k, a, frames, url, fonts, stats) {
  const profile = path.join(SCRATCH, "chrome", `render-${process.pid}-w${k}`);
  const { proc, port, stderr } = await launchChrome(profile, a.gpu);
  const [W, H] = a.size.split("x").map(Number);
  let cdp;
  try {
    const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json();
    cdp = new CDP(target.webSocketDebuggerUrl);
    await cdp.open();
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await cdp.send("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: 1, mobile: false });
    if (a.alpha) await cdp.send("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } });
    await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: prelude(a.seed, a.fps) });
    const logs = [];
    cdp.listeners.push((m) => {
      if (m.method === "Runtime.consoleAPICalled") logs.push(m.params.args.map((x) => x.value ?? x.description ?? "").join(" "));
      if (m.method === "Runtime.exceptionThrown") logs.push("EXCEPTION " + JSON.stringify(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
    });
    const loaded = cdp.once("Page.loadEventFired", a.timeout * 1000);
    await cdp.send("Page.navigate", { url });
    await loaded;
    const ev = async (expr) => {
      const r = await withTimeout(cdp.send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }), a.timeout * 1000, expr.slice(0, 80));
      if (r.exceptionDetails) throw new Error("page error: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text) + "\n" + logs.slice(-10).join("\n"));
      return r.result?.value;
    };
    const has = await ev("typeof window.renderFrame === 'function'");
    if (!has) throw new Error("page has no window.renderFrame(i, fps)\n" + logs.slice(-10).join("\n"));
    const t0 = Date.now();
    await ev(`(async () => { await window.__motion.settle(); if (window.setupScene) await window.setupScene(${JSON.stringify({ width: W, height: H, fps: a.fps, alpha: !!a.alpha, frames: [frames[0], frames[frames.length - 1]], worker: k })}); await window.__motion.settle(); return true; })()`);
    stats.setupMs[k] = Date.now() - t0;
    if (k === 0) stats.webgl = await ev(`(() => { try { const c = document.createElement('canvas'); const g = c.getContext('webgl2') || c.getContext('webgl'); if (!g) return 'none'; const d = g.getExtension('WEBGL_debug_renderer_info'); return (g instanceof WebGL2RenderingContext ? 'webgl2 ' : 'webgl1 ') + (d ? g.getParameter(d.UNMASKED_RENDERER_WEBGL) : g.getParameter(g.RENDERER)); } catch (e) { return 'error ' + e; } })()`);
    for (const i of frames) {
      const f0 = Date.now();
      const t = i / a.fps;
      await ev(`(async () => { window.__motionTime = ${t}; await window.renderFrame(${i}, ${a.fps}); window.__motion.seekTimelines(${t}); await window.__motion.settle(); return true; })()`);
      const f1 = Date.now();
      const shot = await withTimeout(cdp.send("Page.captureScreenshot", { format: "png", fromSurface: true, captureBeyondViewport: false, optimizeForSpeed: true }), a.timeout * 1000, "screenshot " + i);
      fs.writeFileSync(path.join(a.out, `frame_${String(i).padStart(5, "0")}.png`), Buffer.from(shot.data, "base64"));
      const f2 = Date.now();
      stats.frames.push({ i, worker: k, render_ms: f1 - f0, capture_ms: f2 - f1 });
      stats.done++;
      if (stats.done % 30 === 0 || stats.done === stats.total) {
        const el = (Date.now() - stats.t0) / 1000;
        process.stdout.write(`  ${stats.done}/${stats.total} frames  ${el.toFixed(1)}s  (${(stats.done / el).toFixed(1)} fps)\n`);
      }
    }
    stats.logs.push(...logs.slice(-20).map((l) => `[w${k}] ${l}`));
  } catch (e) {
    e.message += "\n[chrome stderr] " + stderr().slice(-1500);
    throw e;
  } finally {
    if (cdp) cdp.close();
    proc.kill("SIGKILL");
    await sleep(100);
    if (!a.keepProfile) fs.rmSync(profile, { recursive: true, force: true });
  }
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  if (a.help || !a.page || !a.out) {
    console.log(fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").filter((l) => l.startsWith("//")).map((l) => l.slice(3)).join("\n"));
    process.exit(a.help ? 0 : 2);
  }
  const page = path.resolve(a.page);
  a.out = path.resolve(a.out);
  fs.mkdirSync(a.out, { recursive: true });
  let frames;
  if (a.only) frames = a.only.split(",").map(Number);
  else {
    const [s, e] = (a.frames || "0:1").split(":").map(Number);
    frames = [];
    for (let i = s; i < e; i++) frames.push(i);
  }
  const fonts = findFonts();
  const server = await startServer(path.dirname(page), fonts);
  const port = server.address().port;
  const url = `http://127.0.0.1:${port}/${encodeURIComponent(path.basename(page))}${a.query ? "?" + a.query : ""}`;
  const n = Math.max(1, Math.min(a.workers, frames.length));
  const chunks = Array.from({ length: n }, (_, k) => frames.slice(Math.floor((k * frames.length) / n), Math.floor(((k + 1) * frames.length) / n)));
  const stats = { t0: Date.now(), done: 0, total: frames.length, frames: [], setupMs: [], logs: [], webgl: "" };
  console.log(`render ${path.basename(page)} -> ${a.out}  frames ${frames[0]}..${frames[frames.length - 1]} (${frames.length})  workers ${n}  ${a.size}${a.alpha ? " alpha" : ""}`);
  try {
    await Promise.all(chunks.map((c, k) => runWorker(k, a, c, url, fonts, stats)));
  } finally {
    server.closeAllConnections();
    server.close();
  }
  const wall = (Date.now() - stats.t0) / 1000;
  const r = stats.frames.map((f) => f.render_ms).sort((x, y) => x - y);
  const c = stats.frames.map((f) => f.capture_ms).sort((x, y) => x - y);
  const q = (arr, p) => arr[Math.min(arr.length - 1, Math.floor(arr.length * p))];
  const report = { page, out: a.out, frames: frames.length, workers: n, size: a.size, alpha: !!a.alpha, fps: a.fps, wall_s: wall,
    frames_per_s: frames.length / wall, setup_ms: stats.setupMs, webgl: stats.webgl,
    render_ms: { p50: q(r, 0.5), p95: q(r, 0.95), max: r[r.length - 1] }, capture_ms: { p50: q(c, 0.5), p95: q(c, 0.95), max: c[c.length - 1] },
    per_frame: stats.frames.sort((x, y) => x.i - y.i), console: stats.logs };
  fs.writeFileSync(path.join(a.out, "render.json"), JSON.stringify(report, null, 1));
  console.log(`done: ${frames.length} frames in ${wall.toFixed(1)}s = ${(frames.length / wall).toFixed(2)} fps overall; per frame render p50 ${report.render_ms.p50} ms, capture p50 ${report.capture_ms.p50} ms; webgl: ${stats.webgl}`);
  if (stats.logs.length) console.log("page console (last lines):\n  " + stats.logs.slice(-8).join("\n  "));
}

main().then(() => process.exit(0)).catch((e) => { console.error("render failed:", e.stack || e.message); process.exit(1); });
