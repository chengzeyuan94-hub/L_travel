'use strict';
/* 《山河旅人》第四幕「L叔在哪儿」· P0 fix #3 — landmark-embedded water (asset-conversion time, one global rule).
 *
 * Called by bake_recipes.cjs --assets for every asset whose manifest role is "landmark". Nothing here knows an
 * asset, tile or place id: a landmark's water is found by geometry and colour only.
 *
 *  1. Water tops. (a) Up-facing triangles (face normal y > 0.9) of the manifest "water" material region.
 *     (b) Up-facing matte triangles (face normal y > 0.95) whose sRGB colour is in the water class
 *         (hue 165–205°, saturation >= 0.45, value >= 0.58). Roof tiles, blue domes and glazed trims of the same
 *         hue fail on saturation or value (checked over all 40 landmarks), and vertical waterfalls stay matte.
 *     Side and bottom faces of water boxes keep their role and colour.
 *  2. Connected tops (shared vertices) form one pool. Per pool:
 *     - every normal is set straight up (0, 1, 0), positions are kept;
 *     - one colour, the area-weighted mean of the pool's own colours (removes the web's per-triangle bands,
 *       the "radial triangles" on fan-shaped pools);
 *     - the pool is subdivided (same step count for every triangle of the pool, so no T-junctions; target
 *       edge CELL_M) and each vertex stores its horizontal distance to the pool's shoreline (the pool's
 *       boundary edges) in TEXCOORD_0.x, and the pool's largest shoreline distance in TEXCOORD_0.y (> 0 marks
 *       a pool top). Units: asset metres; the water shader multiplies by the instance scale.
 *  3. All water geometry goes to the "water" role (lshu_water.gdshader), which turns the shoreline distance
 *     into depth colour, shore foam and ripples with the same uniforms as procedural lakes (look.json).
 * Deterministic: pure function of the source arrays; assets without water are returned untouched.
 */

const CELL_M = 0.12;            // target sub-triangle edge (m) for the shoreline-distance field
const UP_WATER_REGION = 0.9;    // face normal y of a top face in a manifest water region
const UP_MATTE = 0.95;          // face normal y of a matte water top
const HUE = [165, 205], SAT_MIN = 0.45, VAL_MIN = 0.58;
const QUANT = 2000;             // vertex adjacency quantisation (0.5 mm), as the import-time edge pass

function hsv(r, g, b) {
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
  let h = 0;
  if (d > 0) {
    if (mx === r) h = ((g - b) / d) % 6; else if (mx === g) h = (b - r) / d + 2; else h = (r - g) / d + 4;
    h *= 60; if (h < 0) h += 360;
  }
  return [h, mx > 0 ? d / mx : 0, mx];
}
const toLinear = x => x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
const toSrgb = x => { x = Math.max(0, Math.min(1, x)); return x <= 0.0031308 ? x * 12.92 : 1.055 * Math.pow(x, 1 / 2.4) - 0.055; };

function faceNormal(p, t) {
  const o = t * 9;
  const ux = p[o + 3] - p[o], uy = p[o + 4] - p[o + 1], uz = p[o + 5] - p[o + 2];
  const wx = p[o + 6] - p[o], wy = p[o + 7] - p[o + 1], wz = p[o + 8] - p[o + 2];
  const nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
  const l = Math.hypot(nx, ny, nz);
  return l > 0 ? [nx / l, ny / l, nz / l, l * 0.5] : [0, 0, 0, 0];
}
function isWaterColour(c, t) { // c: sRGB-encoded, 9 floats per triangle
  const o = t * 9;
  const r = (c[o] + c[o + 3] + c[o + 6]) / 3, g = (c[o + 1] + c[o + 4] + c[o + 7]) / 3, b = (c[o + 2] + c[o + 5] + c[o + 8]) / 3;
  const [h, s, v] = hsv(r, g, b);
  return h >= HUE[0] && h <= HUE[1] && s >= SAT_MIN && v >= VAL_MIN;
}
const vkey = (x, y, z) => Math.round(x * QUANT) + ',' + Math.round(y * QUANT) + ',' + Math.round(z * QUANT);
function tri(q, t) { return { p: q.p.slice(t * 9, t * 9 + 9), n: q.n.slice(t * 9, t * 9 + 9), c: q.c.slice(t * 9, t * 9 + 9) }; }

function segDist(px, pz, ax, az, bx, bz) {
  const dx = bx - ax, dz = bz - az, l2 = dx * dx + dz * dz;
  let u = l2 > 0 ? ((px - ax) * dx + (pz - az) * dz) / l2 : 0;
  u = Math.max(0, Math.min(1, u));
  return Math.hypot(px - (ax + dx * u), pz - (az + dz * u));
}

/** One pool: triangles (each {p,n,c}) -> {p,n,c,uv, triangles, inradius, source_triangles}. */
function buildPool(tris) {
  // boundary edges = edges used by exactly one triangle of the pool
  const edges = new Map();
  let maxEdge = 0, area = 0, lr = 0, lg = 0, lb = 0;
  for (const t of tris) {
    const k = [0, 1, 2].map(i => vkey(t.p[i * 3], t.p[i * 3 + 1], t.p[i * 3 + 2]));
    for (let e = 0; e < 3; e++) {
      const a = e, b = (e + 1) % 3;
      const key = k[a] < k[b] ? k[a] + '|' + k[b] : k[b] + '|' + k[a];
      const rec = edges.get(key);
      if (rec) rec.count++; else edges.set(key, { count: 1, ax: t.p[a * 3], az: t.p[a * 3 + 2], bx: t.p[b * 3], bz: t.p[b * 3 + 2] });
      maxEdge = Math.max(maxEdge, Math.hypot(t.p[b * 3] - t.p[a * 3], t.p[b * 3 + 1] - t.p[a * 3 + 1], t.p[b * 3 + 2] - t.p[a * 3 + 2]));
    }
    const ar = faceNormal(t.p, 0)[3];
    area += ar;
    for (let v = 0; v < 3; v++) { lr += toLinear(t.c[v * 3]) * ar / 3; lg += toLinear(t.c[v * 3 + 1]) * ar / 3; lb += toLinear(t.c[v * 3 + 2]) * ar / 3; }
  }
  const shore = [...edges.values()].filter(e => e.count === 1);
  const col = area > 0 ? [toSrgb(lr / area), toSrgb(lg / area), toSrgb(lb / area)] : [tris[0].c[0], tris[0].c[1], tris[0].c[2]];
  const steps = Math.max(1, Math.ceil(maxEdge / CELL_M));
  const dist = (x, z) => { let d = Infinity; for (const s of shore) d = Math.min(d, segDist(x, z, s.ax, s.az, s.bx, s.bz)); return shore.length ? d : 0; };
  const out = { p: [], n: [], c: [], d: [] };
  for (const t of tris) {
    const A = t.p.slice(0, 3), B = t.p.slice(3, 6), C = t.p.slice(6, 9);
    const P = (i, j) => [0, 1, 2].map(k => A[k] + (B[k] - A[k]) * i / steps + (C[k] - A[k]) * j / steps);
    const grid = new Map();
    const at = (i, j) => { const key = i * (steps + 1) + j; if (!grid.has(key)) { const q = P(i, j); grid.set(key, { q, d: dist(q[0], q[2]) }); } return grid.get(key); };
    const emit = (...vs) => { for (const v of vs) { out.p.push(...v.q); out.n.push(0, 1, 0); out.c.push(...col); out.d.push(v.d); } };
    for (let i = 0; i < steps; i++) {
      for (let j = 0; j < steps - i; j++) {
        emit(at(i, j), at(i + 1, j), at(i, j + 1));
        if (i + j < steps - 1) emit(at(i + 1, j), at(i + 1, j + 1), at(i, j + 1));
      }
    }
  }
  let inradius = 0; for (const d of out.d) inradius = Math.max(inradius, d);
  const uv = []; for (const d of out.d) uv.push(d, inradius);
  return { p: out.p, n: out.n, c: out.c, uv, triangles: out.p.length / 9, inradius, source_triangles: tris.length, steps };
}

/**
 * fixed: Map role -> {role, p, n, c} of the asset's non-rotor geometry (c already sRGB-encoded). Mutates it:
 * matte water tops move out of "matte"; the "water" bucket becomes [non-top water faces (uv 0,0)] + [pools].
 * Returns a summary ({pools, triangles, ...}) or null when the asset has no embedded water.
 */
function landmarkWater(fixed) {
  const tops = [];
  const keepWater = { p: [], n: [], c: [] };
  const matte = fixed.get('matte');
  let matteMoved = 0;
  if (matte) {
    const keep = { p: [], n: [], c: [] };
    for (let t = 0; t < matte.p.length / 9; t++) {
      const f = faceNormal(matte.p, t);
      const x = tri(matte, t);
      if (f[1] > UP_MATTE && isWaterColour(matte.c, t)) { tops.push(x); matteMoved++; } else { keep.p.push(...x.p); keep.n.push(...x.n); keep.c.push(...x.c); }
    }
    if (matteMoved) { matte.p = keep.p; matte.n = keep.n; matte.c = keep.c; }
  }
  const water = fixed.get('water');
  let regionTops = 0;
  if (water) {
    for (let t = 0; t < water.p.length / 9; t++) {
      const x = tri(water, t);
      if (faceNormal(water.p, t)[1] > UP_WATER_REGION) { tops.push(x); regionTops++; } else { keepWater.p.push(...x.p); keepWater.n.push(...x.n); keepWater.c.push(...x.c); }
    }
  }
  if (!tops.length) return null;
  // connected components over shared (quantised) vertices, in first-triangle order
  const parent = tops.map((_, i) => i);
  const find = i => { while (parent[i] !== i) { parent[i] = parent[parent[i]]; i = parent[i]; } return i; };
  const owner = new Map();
  tops.forEach((t, i) => {
    for (let v = 0; v < 3; v++) {
      const k = vkey(t.p[v * 3], t.p[v * 3 + 1], t.p[v * 3 + 2]);
      if (owner.has(k)) { const a = find(i), b = find(owner.get(k)); if (a !== b) parent[Math.max(a, b)] = Math.min(a, b); } else owner.set(k, i);
    }
  });
  const groups = new Map();
  tops.forEach((t, i) => { const r = find(i); if (!groups.has(r)) groups.set(r, []); groups.get(r).push(t); });
  const bucket = { role: 'water', p: keepWater.p, n: keepWater.n, c: keepWater.c, uv: [] };
  for (let i = 0; i < bucket.p.length / 3; i++) bucket.uv.push(0, 0);
  const pools = [];
  for (const g of groups.values()) {
    const pool = buildPool(g);
    bucket.p.push(...pool.p); bucket.n.push(...pool.n); bucket.c.push(...pool.c); bucket.uv.push(...pool.uv);
    pools.push({ source_triangles: pool.source_triangles, triangles: pool.triangles, steps: pool.steps, inradius_m: Math.round(pool.inradius * 1e4) / 1e4 });
  }
  if (matte && matte.p.length === 0) fixed.delete('matte');
  fixed.set('water', bucket);
  return { rule: 'lshu landmark water v1', matte_tops_moved: matteMoved, water_region_tops: regionTops, pools };
}

module.exports = { landmarkWater, CELL_M };
