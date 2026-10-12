#!/usr/bin/env node
/* 《山河旅人》第四幕「L叔在哪儿」· offline tile bake (production port of the probe's
 * tools/traveler/lookdev_lshu/bake/bake_recipes.cjs + v_bake.cjs).
 *
 * Runs the web project's own planner/assembler (verbatim copies in ../web_src, never edited) headless in a
 * Node vm, exactly like web_src/tests/harness.cjs. Every source patch asserts that it matched exactly once.
 *
 *   --assets        140 prop GLBs -> assets/traveler/lshu/props/<asset>.glb (+ .import: LODs off, mesh
 *                   compression off, post-import script lshu_post_import.gd adds the crease/edge data ONCE per
 *                   asset at import time). Vertex colours sRGB-encoded, surfaces split by material role.
 *   --pool[=A,B]    bake every entry (or the listed entries) of data/traveler/lshu/pool.json:
 *                   data/traveler/lshu/tiles/<id>.json (lshu.tile.v1) + assets/traveler/lshu/tiles/proc_<sha>.glb
 *                   (procedural parts, one node per role, named by content hash so identical geometry is shared).
 *                   Proc GLBs that no tile references any more are removed (only proc_*.glb in that folder).
 *   --check[=A,B]   determinism: bake each entry twice in memory and compare the JSON + GLB bytes.
 *   --pool-file=P   read the pool list from P instead of data/traveler/lshu/pool.json (bake a staged pool first,
 *                   install it after the chain passed, so a half-baked pool is never live).
 * A tile JSON whose baked part is unchanged is not rewritten, so its offline precompute stays in place.
 * Then: Godot --headless --import, and tools/traveler/lshu/bake/precompute_tiles.gd appends the offline ground
 * info + scatter instances to every tile JSON (tools/traveler/lshu/bake/run_bake.sh runs the whole chain).
 *
 * Colour convention: COLOR_0 holds sRGB-encoded colour (NOT glTF-standard linear). Godot stores vertex colour in
 * 8 bits; sRGB keeps dark tones precise. The shared surface shader decodes it (vertex_color_srgb).
 * Material names encode the surface role: lshu_<role> (matte, glow, water, metal, ground, skirt, ...).
 * No network, no keys, no serve.py. Written files carry no timestamps or timings (byte-identical re-bakes).
 */
'use strict';
const fs = require('fs'), vm = require('vm'), path = require('path'), crypto = require('crypto');
const { landmarkWater } = require('./landmark_water.cjs'); // P0 fix #3: landmark-embedded water (global rule)
const ROOT = path.resolve(__dirname, '..', '..', '..', '..');
const WEB = path.join(ROOT, 'tools', 'traveler', 'lshu', 'web_src');
let POOL = path.join(ROOT, 'data', 'traveler', 'lshu', 'pool.json');
const TILE_JSON_OUT = path.join(ROOT, 'data', 'traveler', 'lshu', 'tiles');
const TILE_GLB_OUT = path.join(ROOT, 'assets', 'traveler', 'lshu', 'tiles');
const PROPS_OUT = path.join(ROOT, 'assets', 'traveler', 'lshu', 'props');
const RES_PROPS = 'res://assets/traveler/lshu/props/';
const RES_TILES = 'res://assets/traveler/lshu/tiles/';
const POST_IMPORT = 'res://tools/traveler/lshu/bake/lshu_post_import.gd';
const WEB_EMISSION = { day: 0.13, morning: 0.13, sunset: 0.5, night: 1.7 };
const LIGHTS = ['morning', 'day', 'sunset', 'night'];

const toSrgb = x => { x = Math.max(0, Math.min(1, x)); return x <= 0.0031308 ? x * 12.92 : 1.055 * Math.pow(x, 1 / 2.4) - 0.055; };
const r5 = v => Math.round(v * 1e5) / 1e5;
const r4 = v => Math.round(v * 1e4) / 1e4;
const v3 = a => [r5(a[0]), r5(a[1]), r5(a[2])];

// ---------------------------------------------------------------- vm context (harness.cjs + tagging patches)
function patch(src, from, to, file) {
  const n = src.split(from).length - 1;
  if (n !== 1) throw Error(`patch point in ${file} matched ${n} times: ${from.slice(0, 80)}`);
  return src.replace(from, to);
}
const PATCHES = {
  'studio/world.js': [
    // tag every asset() mesh so it is exported as an instance, not as procedural geometry
    ['n.name=id;used.push({id,position:[...n.p],scale:s,yaw:rot});',
     'n.name=id;used.push({id,position:[...n.p],scale:s,yaw:rot});n.lshuAsset={index:used.length-1,id};'],
    // procedural role context for Camp.mesh tagging
    ['ground(model,model.surface_theme||p.scene_id);paths(model);water(model);',
     "globalThis.__lshuRole='ground';ground(model,model.surface_theme||p.scene_id);globalThis.__lshuRole='steps';paths(model);globalThis.__lshuRole='water';water(model);globalThis.__lshuRole='structure';"],
    // keep nodes unbatched (optimize() would merge assets and procedural parts)
    ['  optimize();\n  const contactError', '  Camp.update();\n  const contactError'],
    ['person.keepNode=true;', 'person.keepNode=true;person.lshuPerson=true;'],
    ['return {build,tick,snapshot,get last(){return last;}};', 'return {build,tick,snapshot,get last(){return last;},get anim(){return anim;}};'],
    // grass tufts: record + role
    ["function grass(x,z,color='#7d925c',s=.14){",
     "function grass(x,z,color='#7d925c',s=.14){globalThis.__lshuGrass.push({x,z,y:model.height(x,z),color,s});const __pr=globalThis.__lshuRole;globalThis.__lshuRole='grass';try{return grass0(x,z,color,s);}finally{globalThis.__lshuRole=__pr;}}\n function grass0(x,z,color='#7d925c',s=.14){"],
  ],
  'journey/assemble.js': [
    ['[0,h.yaw,0],[h.scale,h.scale,h.scale]);', '[0,h.yaw,0],[h.scale,h.scale,h.scale]);n.lshuAsset={landmark:true,id:d.asset};'],
    ['  function flame(x,z,y,scale=.6){',
     "  function flame(x,z,y,scale=.6){globalThis.__lshuFires.push({x,y,z,scale});const __pr=globalThis.__lshuRole;globalThis.__lshuRole='flame';try{return flame0(x,z,y,scale);}finally{globalThis.__lshuRole=__pr;}}\n  function flame0(x,z,y,scale=.6){"],
  ],
};
function makeContext() {
  const ctx = {
    console, performance, TextDecoder, TextEncoder, Uint8Array, Uint32Array, Float32Array, DataView, ArrayBuffer, URL,
    setTimeout, clearTimeout, crypto: require('crypto').webcrypto,
    localStorage: { getItem: () => null, setItem: () => {} },
    fetch: async u => { const b = fs.readFileSync(path.join(WEB, String(u).replace(/^\//, ''))); return { ok: true, json: async () => JSON.parse(b), text: async () => b.toString(), arrayBuffer: async () => b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }; },
  };
  vm.createContext(ctx);
  const scripts = ['src/geometry.js', 'src/composer.js', 'src/asset-loader.js', 'src/world.js', 'studio/layout.js', 'journey/catalog.js', 'journey/planner.js', 'journey/city-runtime.js', 'journey/assemble.js', 'studio/world.js'];
  for (const f of scripts) {
    let src = fs.readFileSync(path.join(WEB, f), 'utf8');
    for (const [a, b] of PATCHES[f] || []) src = patch(src, a, b, f);
    vm.runInContext(src, ctx, { filename: f });
    if (f === 'src/geometry.js') // tag every mesh with the procedural role active when it was emitted
      vm.runInContext("(()=>{const m=Camp.mesh;Camp.mesh=function(...a){const n=m(...a);n.lshuRole=globalThis.__lshuRole||'structure';return n;};})()", ctx);
  }
  vm.runInContext('setCatalog(' + fs.readFileSync(path.join(WEB, 'assets/manifest.json'), 'utf8') + ');', ctx);
  return { ctx, run: s => vm.runInContext(s, ctx) };
}

// ---------------------------------------------------------------- minimal GLB writer / reader
function glbBytes(doc, chunks) {
  let bin = Buffer.concat(chunks);
  const binPad = (4 - bin.length % 4) % 4; bin = Buffer.concat([bin, Buffer.alloc(binPad)]);
  doc.buffers = [{ byteLength: bin.length }];
  let json = Buffer.from(JSON.stringify(doc), 'utf8');
  const jsonPad = (4 - json.length % 4) % 4; json = Buffer.concat([json, Buffer.alloc(jsonPad, 0x20)]);
  const total = 12 + 8 + json.length + 8 + bin.length, out = Buffer.alloc(total);
  out.writeUInt32LE(0x46546c67, 0); out.writeUInt32LE(2, 4); out.writeUInt32LE(total, 8);
  out.writeUInt32LE(json.length, 12); out.writeUInt32LE(0x4e4f534a, 16); json.copy(out, 20);
  out.writeUInt32LE(bin.length, 20 + json.length); out.writeUInt32LE(0x004e4942, 24 + json.length); bin.copy(out, 28 + json.length);
  return out;
}
function glbBuilder() {
  const doc = { asset: { version: '2.0', generator: 'lshu bake_recipes.cjs' }, scene: 0, scenes: [{ nodes: [] }], nodes: [], meshes: [], materials: [], accessors: [], bufferViews: [] };
  const chunks = []; let offset = 0; const matIndex = new Map();
  function attr(arr, withMinMax, width = 3) {
    const f = Float32Array.from(arr), bytes = Buffer.from(f.buffer);
    doc.bufferViews.push({ buffer: 0, byteOffset: offset, byteLength: bytes.length, target: 34962 }); chunks.push(bytes); offset += bytes.length;
    const a = { bufferView: doc.bufferViews.length - 1, componentType: 5126, count: arr.length / width, type: width === 2 ? 'VEC2' : 'VEC3' };
    if (withMinMax) { a.min = [0, 1, 2].map(k => { let v = Infinity; for (let i = k; i < f.length; i += 3) v = Math.min(v, f[i]); return v; }); a.max = [0, 1, 2].map(k => { let v = -Infinity; for (let i = k; i < f.length; i += 3) v = Math.max(v, f[i]); return v; }); }
    doc.accessors.push(a); return doc.accessors.length - 1;
  }
  function material(role) {
    if (!matIndex.has(role)) { doc.materials.push({ name: 'lshu_' + role, pbrMetallicRoughness: { baseColorFactor: [1, 1, 1, 1], metallicFactor: 0, roughnessFactor: 0.9 }, doubleSided: true, extras: { lshu_role: role, color_0: 'srgb' } }); matIndex.set(role, doc.materials.length - 1); }
    return matIndex.get(role);
  }
  function mesh(name, prims) { // prims: [{role, p, n, c, uv?}] c is sRGB already; uv (landmark water) -> TEXCOORD_0
    doc.meshes.push({ name, primitives: prims.filter(q => q.p.length).map(q => ({ attributes: Object.assign({ POSITION: attr(q.p, true), NORMAL: attr(q.n), COLOR_0: attr(q.c) }, q.uv ? { TEXCOORD_0: attr(q.uv, false, 2) } : {}), material: material(q.role), mode: 4 })) });
    return doc.meshes.length - 1;
  }
  function node(def, root = true) { doc.nodes.push(def); const i = doc.nodes.length - 1; if (root) doc.scenes[0].nodes.push(i); return i; }
  return { doc, chunks, mesh, node, bytes: () => glbBytes(doc, chunks), write: f => fs.writeFileSync(f, glbBytes(doc, chunks)) };
}
function readGlb(file) {
  const b = fs.readFileSync(file);
  if (b.readUInt32LE(0) !== 0x46546c67) throw Error('not a GLB ' + file);
  let off = 12, json = null, bin = null;
  while (off < b.length) { const len = b.readUInt32LE(off), type = b.readUInt32LE(off + 4); const body = b.subarray(off + 8, off + 8 + len); if (type === 0x4e4f534a) json = JSON.parse(body.toString('utf8')); else if (type === 0x004e4942) bin = body; off += 8 + len; }
  const read = acc => { const a = json.accessors[acc], v = json.bufferViews[a.bufferView]; if (a.componentType !== 5126 || a.type !== 'VEC3' || v.byteStride) throw Error('unexpected accessor in ' + file); const s = bin.subarray((v.byteOffset || 0) + (a.byteOffset || 0)); const out = new Float32Array(a.count * 3); for (let i = 0; i < out.length; i++) out[i] = s.readFloatLE(i * 4); return out; };
  return { json, read };
}


// ---------------------------------------------------------------- --assets: 140 asset GLBs -> assets/traveler/lshu/props
const IMPORT_TEMPLATE = src => `[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="${src}"

[params]

nodes/root_type=""
nodes/root_name=""
nodes/root_script=null
mesh_library/use_node_names_as_mesh_names=false
array_mesh/deduplicate_surfaces=true
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_name_suffixes=false
nodes/use_node_type_suffixes=false
meshes/ensure_tangents=false
meshes/generate_lods=false
meshes/create_shadow_meshes=true
meshes/light_baking=1
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=true
skins/use_named_skins=true
animation/import=false
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path="${POST_IMPORT}"
materials/extract=0
materials/extract_format=0
materials/extract_path=""
_subresources={}
gltf/naming_version=2
gltf/embedded_image_handling=1
gltf/texture_map_mode=1
`;
function writeIfChanged(file, bytes) {
  if (fs.existsSync(file) && Buffer.compare(fs.readFileSync(file), Buffer.from(bytes)) === 0) return false;
  fs.writeFileSync(file, bytes);
  return true;
}
function convertAssets() {
  fs.mkdirSync(PROPS_OUT, { recursive: true });
  const manifest = JSON.parse(fs.readFileSync(path.join(WEB, 'assets/manifest.json'), 'utf8'));
  const summary = [];
  let changed = 0;
  for (const a of manifest.assets) {
    const src = readGlb(path.join(WEB, a.file));
    const prim = src.json.meshes[0].primitives[0], srcNode = src.json.nodes[0];
    if (src.json.meshes.length !== 1 || src.json.meshes[0].primitives.length !== 1 || prim.indices !== undefined) throw Error('unexpected asset layout ' + a.id);
    if (srcNode.matrix || srcNode.translation || srcNode.rotation || srcNode.scale) throw Error('asset node has a transform ' + a.id);
    const P = src.read(prim.attributes.POSITION), N = src.read(prim.attributes.NORMAL), C = src.read(prim.attributes.COLOR_0);
    const tris = P.length / 9, regions = (a.material_regions || []).filter(r => r.triangle_count > 0), parts = a.runtime_parts || [];
    const fixed = new Map(), partPrims = parts.map(() => new Map());
    const bucket = (map, role) => { if (!map.has(role)) map.set(role, { role, p: [], n: [], c: [] }); return map.get(role); };
    for (let t = 0; t < tris; t++) {
      const role = (regions.find(r => t >= r.start_triangle && t < r.start_triangle + r.triangle_count) || {}).role || 'matte';
      const pi = parts.findIndex(q => t >= q.start_triangle && t < q.start_triangle + q.triangle_count);
      const q = pi >= 0 ? bucket(partPrims[pi], role) : bucket(fixed, role);
      for (let k = 0; k < 9; k++) {
        q.p.push(P[t * 9 + k] - (pi >= 0 ? parts[pi].pivot[k % 3] : 0));
        q.n.push(N[t * 9 + k]);
        q.c.push(toSrgb(C[t * 9 + k]));
      }
    }
    const water = a.role === 'landmark' ? landmarkWater(fixed) : null; // null (bytes unchanged) without embedded water
    const g = glbBuilder();
    g.doc.asset.extras = { lshu_color_0: 'srgb', source: a.file, source_sha256: a.sha256 || null };
    const children = parts.map((q, i) => g.node({ name: 'rotor_' + (q.name || i), translation: q.pivot, mesh: g.mesh('rotor_' + (q.name || i), [...partPrims[i].values()]), extras: { lshu: { runtime_part: { name: q.name, axis: q.axis, speed_rad_s: q.speed_rad_s, pivot: q.pivot } } } }, false));
    const keep = ['id', 'name', 'group', 'role', 'themes', 'size', 'motion', 'sockets', 'effect_points', 'runtime_parts', 'material_regions', 'ground_offset_m', 'surface_y', 'triangles', 'city', 'access', 'composition'];
    const info = {}; for (const k of keep) if (a[k] !== undefined && a[k] !== null) info[k] = a[k];
    const root = { name: a.id, mesh: g.mesh(a.id, [...fixed.values()]), extras: Object.assign({}, srcNode.extras || {}, { lshu: Object.assign({ asset: info, color_0: 'srgb' }, water ? { landmark_water: water } : {}) }) };
    if (children.length) root.children = children;
    g.node(root);
    const out = path.join(PROPS_OUT, a.id + '.glb');
    if (writeIfChanged(out, g.bytes())) changed++;
    const imp = out + '.import';
    if (!fs.existsSync(imp)) fs.writeFileSync(imp, IMPORT_TEMPLATE(RES_PROPS + a.id + '.glb'));
    summary.push({ id: a.id, tris, roles: [...fixed.keys()], rotor: parts.length });
  }
  console.log('ASSETS', summary.length, 'converted,', changed, 'changed ->', PROPS_OUT);
}

// ---------------------------------------------------------------- recipe bake
function worldPoint(m, p) { return [m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12], m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13], m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14]]; }
function classify(n, animByNode) {
  if (n.isFloor || n.isContact) return null;
  for (let a = n; a; a = a.parent) { if (a.lshuPerson || a.lshuAsset) return null; }
  const an = animByNode.get(n);
  if (an && an.type === 'smoke') return null;
  if (n.lshuRole === 'flame') return null;
  if (an && an.type === 'ripple') return 'ripple';
  if (n.name === 'SharedGround') return 'ground';
  if (n.name === 'WaterSurface') return 'water';
  if (n.name === 'ShoreFoam') return 'foam';
  if (n.isGlow) return 'glow';
  if (n.name === 'TerrainCliff') return 'cliff';
  if (n.lshuRole === 'ground') return 'skirt';
  if (n.lshuRole === 'water') return 'water_side';
  return n.lshuRole || 'structure';
}
/** Builds one pool entry in memory. Returns {json: Buffer, glb: Buffer, procName, out, ms}. Writes nothing. */
async function bakeOne(env, spec) {
  const { run } = env;
  const t0 = Date.now();
  run("globalThis.__lshuGrass=[];globalThis.__lshuFires=[];globalThis.__lshuRole='structure';");
  await run(`StudioWorld.build(Journey480.recipe(${JSON.stringify(spec.composition_id)},${JSON.stringify(spec.light)}))`);
  const L = run('StudioWorld.last'), anim = run('StudioWorld.anim'), Camp = run('Camp'), ASSETS = run('ASSETS'), J = run('Journey480');
  const m = L.model, p = L.recipe, cp = L.character;
  const animByNode = new Map(anim.map(a => [a.node, a]));
  // procedural geometry, merged per role in world space (face normals recomputed, as optimize() did)
  const prims = new Map(), smoke = [];
  for (const n of Camp.world) {
    const an = animByNode.get(n);
    if (an && an.type === 'smoke' && !n.parent) smoke.push(v3(an.base));
    const role = classify(n, animByNode); if (!role || !n.g.p.length) continue;
    if (!prims.has(role)) prims.set(role, { role, p: [], n: [], c: [], meshes: 0, opacity: n.mat.opacity, roughness: n.mat.roughness, emission: n.mat.emission, kind: n.mat.kind });
    const q = prims.get(role); q.meshes++;
    const col = n.mat.color;
    for (let i = 0; i < n.g.p.length; i += 9) {
      const a = worldPoint(n.world, n.g.p.slice(i, i + 3)), b = worldPoint(n.world, n.g.p.slice(i + 3, i + 6)), c = worldPoint(n.world, n.g.p.slice(i + 6, i + 9));
      const u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]], w = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
      let N = [u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]]; const l = Math.hypot(...N) || 1; N = N.map(x => x / l);
      q.p.push(...a, ...b, ...c); q.n.push(...N, ...N, ...N);
      for (let k = 0; k < 9; k++) q.c.push(Math.max(0, Math.min(1, col[k % 3] * n.g.c[i + k]))); // sRGB * sRGB, as the web shader
    }
  }
  // geometry only in the GLB (no recipe / light / kit), so equal geometry gives equal bytes -> one shared file
  const g = glbBuilder();
  g.doc.asset.extras = { lshu_color_0: 'srgb', note: 'Procedural tile parts only; placed assets are listed in the tile JSON.' };
  const procRoles = {};
  for (const [role, q] of prims) {
    g.node({ name: 'proc_' + role, mesh: g.mesh('proc_' + role, [q]), extras: { lshu: { role, triangles: q.p.length / 9, source_meshes: q.meshes, web_material: { opacity: q.opacity, roughness: q.roughness, emission: q.emission, kind: q.kind } } } });
    procRoles[role] = { triangles: q.p.length / 9, source_meshes: q.meshes, web_opacity: q.opacity, web_roughness: q.roughness ?? null };
  }
  const glb = g.bytes();
  const procName = 'proc_' + crypto.createHash('sha256').update(glb).digest('hex').slice(0, 16) + '.glb';
  // instances
  const instances = L.used.map((u, i) => {
    const a = ASSETS[u.id] || {};
    let node = null; for (const n of Camp.world) { if (n.lshuAsset && n.lshuAsset.index === i) { node = n; break; } }
    const an = node ? animByNode.get(node) : null;
    const role = u.role || a.role;
    const out = { asset_id: u.id, position: v3(u.position), yaw: r5(u.yaw || 0), scale: r5(u.scale), role, group: a.group || null,
      anim: an ? (an.type === 'sway480' ? 'sway' : an.type) : (a.motion === 'gentle_sway' ? 'sway' : a.motion === 'bob' ? 'bob' : null),
      motion: a.motion || null };
    if (an && an.amplitude !== undefined) out.sway_amplitude = an.amplitude;
    if (an && an.phase !== undefined) out.phase = r4(an.phase);
    if (a.material_regions && a.material_regions.some(r => r.triangle_count > 0)) out.regions = [...new Set(a.material_regions.filter(r => r.triangle_count > 0).map(r => r.role))];
    if (a.runtime_parts && a.runtime_parts.length) out.runtime_parts = a.runtime_parts.map(r => r.name);
    return out;
  });
  // landmark effect points in world space
  const effects = [];
  for (const inst of instances) {
    const a = ASSETS[inst.asset_id]; if (!a || !a.effect_points) continue;
    const c = Math.cos(inst.yaw), s = Math.sin(inst.yaw);
    for (const e of a.effect_points) { const q = e.position.map(v => v * inst.scale); effects.push({ type: e.type, asset_id: inst.asset_id, position: v3([inst.position[0] + q[0] * c + q[2] * s, inst.position[1] + q[1], inst.position[2] - q[0] * s + q[2] * c]) }); }
  }
  const fires = run('globalThis.__lshuFires').map(f => ({ position: v3([f.x, f.y, f.z]), flame_center: v3([f.x, f.y + 0.45 * f.scale, f.z]), scale: r5(f.scale), source: 'camp_kit' }));
  for (const e of effects) if (e.type === 'flame') fires.push({ position: e.position, flame_center: e.position, scale: 0.6, source: e.asset_id });
  const lamps = (Camp.lanternPositions || []).filter(q => q && q[1] > -50).map(v3);
  const place = J.places[p.scene_id], C = J.C;
  const action = cp.action || 'look';
  const pose = action === 'tea' ? 'seated' : action === 'bloom' ? 'carrying' : 'standing';
  const waterRegions = instances.filter(i => (i.regions || []).includes('water')).map(i => i.asset_id);
  const glowRegions = instances.filter(i => (i.regions || []).includes('glow')).map(i => i.asset_id);
  const heights = m.heights.map(row => row.map(r4));
  let ymin = Infinity, ymax = -Infinity; for (const row of heights) for (const h of row) { ymin = Math.min(ymin, h); ymax = Math.max(ymax, h); }
  const out = {
    schema: 'lshu.tile.v1', id: spec.id, composition_id: spec.composition_id, name: spec.name || place.name, description: spec.description || null,
    light: spec.light, lights_available: LIGHTS,
    recipe: p, config_version: J.version,
    place: { id: place.id, name: place.name, theme: place.theme, landform: place.landform, asset: place.asset, new_city: !!place.new_city, city: place.city || null, enhanced: !!place.enhanced },
    layout: { id: p.variant, name: C.layouts[p.variant].name, shape: C.layouts[p.variant].shape },
    kit: { id: p.profile, name: C.profiles[p.profile].name, mode: C.profiles[p.profile].mode },
    tile: { size: [8, 8], half: 4, ground_y_range: [r4(ymin), r4(ymax)], skirt_bottom_y: -0.54, plinth_bottom_y: -0.8275, web_floor_y: -0.92, surface_theme: m.surface_theme || p.scene_id },
    terrain: { N: m.N, step: r5(m.step), origin: [-4, -4], heights },
    paths: m.paths.map(q => ({ id: q.id, kind: q.kind, width: r4(q.width), points: q.points.map((pt, i) => [r4(pt[0]), r4(q.ys ? q.ys[i] : m.height(pt[0], pt[1])), r4(pt[1])]) })),
    water: m.water ? Object.assign({}, m.water, { proc_roles: ['water', 'water_side', 'foam', 'ripple'].filter(r => procRoles[r]), landmark_water_regions: waterRegions }) : (waterRegions.length ? { level: null, landmark_water_regions: waterRegions } : null),
    glow: { proc: !!procRoles.glow, landmark_glow_regions: glowRegions, web_emission: WEB_EMISSION },
    hero: m.hero, camp: m.camp, pads: m.pads, peaks: m.peaks, reservations: (m.assembly && m.assembly.reservations) || [],
    instances,
    character: { position: v3([cp.x, cp.y, cp.z]), ground_y: r5(m.height(cp.x, cp.z)), yaw: r5(cp.yaw ?? 0.42), action, pose, kit: C.profiles[p.profile].mode, support: cp.support || 'ground', seat_top: cp.seat_top !== undefined ? r5(cp.seat_top) : null, web_scale: cp.scale || 0.72 },
    fires, lamps, effects, smoke,
    grass: run('globalThis.__lshuGrass').map(q => ({ position: v3([q.x, q.y, q.z]), height: r4(q.s), color: q.color })),
    proc: { file: RES_TILES + procName, roles: procRoles, color_0: 'srgb' },
    stats: { web_triangles_total: L.triangles, proc_triangles: Object.values(procRoles).reduce((s, q) => s + q.triangles, 0), instances: instances.length, unique_assets: new Set(instances.map(i => i.asset_id)).size, checks: L.checks },
  };
  return { json: Buffer.from(JSON.stringify(out), 'utf8'), glb, procName, out, ms: Date.now() - t0 };
}

function poolEntries(sel) {
  const pool = JSON.parse(fs.readFileSync(POOL, 'utf8'));
  const tiles = pool.tiles || [];
  if (!sel) return tiles;
  const want = sel.split(',').filter(Boolean);
  const out = want.map(id => { const t = tiles.find(q => q.id === id); if (!t) throw Error('not in pool.json: ' + id); return t; });
  return out;
}
function spec(t) { return { id: t.id, composition_id: t.composition_id, light: t.light || 'day', name: t.name || null, description: t.description || null }; }
function argValue(argv, key) {
  for (const a of argv) { if (a === key) return ''; if (a.startsWith(key + '=')) return a.slice(key.length + 1); }
  return null;
}

(async () => {
  const argv = process.argv.slice(2);
  const poolFile = argValue(argv, '--pool-file');
  if (poolFile) POOL = path.resolve(poolFile);
  if (argv.includes('--assets')) convertAssets();
  const poolSel = argValue(argv, '--pool'), checkSel = argValue(argv, '--check');
  if (poolSel === null && checkSel === null) return;
  const env = makeContext();
  if (checkSel !== null) {
    let bad = 0;
    for (const t of poolEntries(checkSel || null)) {
      const a = await bakeOne(env, spec(t)), b = await bakeOne(env, spec(t));
      const same = Buffer.compare(a.json, b.json) === 0 && Buffer.compare(a.glb, b.glb) === 0;
      let disk = 'absent';
      const jf = path.join(TILE_JSON_OUT, t.id + '.json');
      if (fs.existsSync(jf)) { const txt = fs.readFileSync(jf); const cut = txt.indexOf(',"precompute":'); disk = Buffer.compare(cut >= 0 ? Buffer.concat([txt.subarray(0, cut), Buffer.from('}')]) : txt, a.json) === 0 ? 'same' : 'DIFFERENT'; }
      if (!same) bad++;
      console.log('DETERMINISTIC', t.id, same, 'json_bytes=' + a.json.length, 'glb=' + a.procName, 'vs_disk=' + disk);
    }
    process.exitCode = bad ? 1 : 0;
    return;
  }
  fs.mkdirSync(TILE_JSON_OUT, { recursive: true });
  fs.mkdirSync(TILE_GLB_OUT, { recursive: true });
  for (const t of poolEntries(poolSel || null)) {
    const r = await bakeOne(env, spec(t));
    const gf = path.join(TILE_GLB_OUT, r.procName);
    const glbNew = writeIfChanged(gf, r.glb);
    if (!fs.existsSync(gf + '.import')) fs.writeFileSync(gf + '.import', IMPORT_TEMPLATE(RES_TILES + r.procName));
    const jf = path.join(TILE_JSON_OUT, t.id + '.json');
    let jsonNew = true;
    if (fs.existsSync(jf)) { // same baked part -> keep the file (and its precompute) untouched
      const txt = fs.readFileSync(jf), cut = txt.indexOf(',"precompute":');
      jsonNew = Buffer.compare(cut >= 0 ? Buffer.concat([txt.subarray(0, cut), Buffer.from('}')]) : txt, r.json) !== 0;
    }
    if (jsonNew) fs.writeFileSync(jf, r.json);
    const o = r.out;
    console.log('BAKED', o.id, o.composition_id, o.place.id, o.light, 'pose=' + o.character.pose, 'inst=' + o.stats.instances, 'proc_tris=' + o.stats.proc_triangles, r.procName + (glbNew ? ' (new)' : ''), 'json=' + (jsonNew ? 'written' : 'unchanged'), r.ms + 'ms');
  }
  // remove proc GLBs no tile JSON references any more (only our own proc_*.glb files)
  const referenced = new Set();
  for (const f of fs.readdirSync(TILE_JSON_OUT)) if (f.endsWith('.json')) { const txt = fs.readFileSync(path.join(TILE_JSON_OUT, f), 'utf8'); const mm = txt.match(/"file":"res:\/\/assets\/traveler\/lshu\/tiles\/(proc_[0-9a-f]{16}\.glb)"/); if (mm) referenced.add(mm[1]); }
  for (const f of fs.readdirSync(TILE_GLB_OUT)) if (/^proc_[0-9a-f]{16}\.glb$/.test(f) && !referenced.has(f)) { fs.unlinkSync(path.join(TILE_GLB_OUT, f)); if (fs.existsSync(path.join(TILE_GLB_OUT, f + '.import'))) fs.unlinkSync(path.join(TILE_GLB_OUT, f + '.import')); console.log('REMOVED unreferenced', f); }
  console.log('PROC_GLBS', referenced.size, 'referenced');
})().catch(e => { console.error(e); process.exitCode = 1; });
