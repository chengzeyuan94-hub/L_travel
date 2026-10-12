// 旅人场景地图摆放器（2026-09-22，描述表驱动版）
//
// 两个致命件一个都不自己写（Carlos 三次否决旧编辑器的原因就是这两条）：
//   - 选中：three.js Raycaster，打到真网格上取最前面那个（不是量原点的屏幕距离）
//   - 手柄：three.js 官方 TransformControls
// 点空白处只取消选中，**绝不生成任何东西**。所有操作都有屏幕按钮，E/R/T 严格照 C4D。
//
// 场景结构不再写死：从服务端 /scene 取 scenes.py 里的描述表，按表建对象、按表写回。

import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { TransformControls } from 'three/addons/controls/TransformControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';

// **与引擎逐字一致**，不要自己另发明一套。
// baghdad_viewer.gd:89-92  stage_point(a) = Vector3(-a.x, a.y, a.z)   —— 镜像的是 X
// place_asset / baghdad_mountain_layer.gd  rotation.y = deg_to_rad(yaw_deg)  —— yaw 正号，不镜像
//
// 之前这里写成 (x, y, −z) 配 −yaw：镜像轴不同、yaw 符号还反了。
// 位置看起来没问题（两种镜像差一个绕 Y 180°，连相机一起变换后成像相同），
// 但**朝向是反的** —— Carlos 2026-09-22 一眼看出"编辑器里的拱门和实机相反"。
const S2T = (x, y, z) => new THREE.Vector3(-x, y, z);
const T2S = (v) => [-v.x, v.y, v.z];
const yawS2T = (deg) => deg * Math.PI / 180;
const yawT2S = (rad) => rad * 180 / Math.PI;

let scene, camera, renderer, orbit, gizmo, raycaster, ground;
let spec = null;           // { view, title, groups, doc, camera }
const items = [];
let selected = null, boxHelper = null;
const savedMat = new Map();
const undoStack = [];
const pendingDeletes = {};   // { groupKey: [{id,index}] }  只在保存时才真正写入
const pendingHides = {};     // { groupKey: [{id,index}] }  隐藏（非破坏性，可恢复）
const pendingUnhides = {};   // { groupKey: [{id,hidden_index}] }
let hiddenStore = {};        // 服务端发来的 editor_hidden 内容
let currentCat = null;
let camPos = new THREE.Vector3(), camTgt = new THREE.Vector3(), camFov = 40;
let groundH = null;          // 地形高度函数，导入落地用

const $ = (id) => document.getElementById(id);
const status = (t, bad) => { const e = $('status'); e.textContent = t; e.style.color = bad ? 'var(--warn)' : 'var(--dim)'; };
const fmt = (v) => (Math.round(v * 1000) / 1000).toString();

// ============================================================ 工具

function dig(obj, path) {
  let cur = obj;
  for (const k of path) {
    if (cur == null || typeof cur !== 'object' || !(k in cur)) return null;
    cur = cur[k];
  }
  return cur;
}

function res(p) { return '/file/' + String(p).replace(/^res:\/\//, ''); }

const gltfLoader = new GLTFLoader();
const fbxLoader = new FBXLoader();
const cache = new Map();

function prep(root) {
  root.traverse((o) => { if (o.isMesh) { o.castShadow = false; o.receiveShadow = false; } });
  const box = new THREE.Box3().setFromObject(root);
  const size = new THREE.Vector3(); box.getSize(size);
  root.userData.bounds = { x: size.x || 1, y: size.y || 1, z: size.z || 1, minY: box.min.y };
  return root;
}

async function loadAsset(path) {
  if (!path) return null;
  const url = res(path);
  if (cache.has(url)) return cache.get(url);
  const p = new Promise((resolve) => {
    const ext = url.split('?')[0].split('.').pop().toLowerCase();
    const ok = (o) => resolve(prep(o));
    const fail = () => { console.warn('载入失败', url); resolve(null); };
    if (ext === 'fbx') fbxLoader.load(url, ok, undefined, fail);
    else if (ext === 'glb' || ext === 'gltf') gltfLoader.load(url, (g) => ok(g.scene), undefined, fail);
    else fail();
  });
  cache.set(url, p);
  return p;
}

function clone(proto) {
  const o = proto.clone(true);
  o.userData.bounds = proto.userData.bounds;
  return o;
}

function placeholder(h, color) {
  const m = new THREE.Mesh(
    new THREE.CapsuleGeometry(Math.max(0.03, h * 0.17), Math.max(0.05, h * 0.66), 6, 12),
    new THREE.MeshLambertMaterial({ color: color || 0xffb43d }));
  m.userData.bounds = { x: h * 0.34, y: h, z: h * 0.34, minY: -h * 0.5 };
  return m;
}

// ============================================================ 地形预览

function makeHeight(relief) {
  const ridges = (relief && relief.ridges) || [];
  const broad = relief && relief.broad_undulation;
  return function h(x, z) {
    let v = 0;
    for (const r of ridges) {
      if (!r || !r.center || !r.radius) continue;
      const a = -(r.angle_deg || 0) * Math.PI / 180;
      const dx = x - r.center[0], dz = z - r.center[1];
      const u = dx * Math.cos(a) - dz * Math.sin(a);
      const w = dx * Math.sin(a) + dz * Math.cos(a);
      const q = Math.hypot(u / Math.max(0.05, r.radius[0]), w / Math.max(0.05, r.radius[1]));
      if (q < 1) v += (r.height_u || 0) * (0.5 + 0.5 * Math.cos(q * Math.PI));
    }
    if (broad && broad.amplitude_u) {
      const wl = Math.max(1, broad.wavelength_u || 30);
      v += broad.amplitude_u * 0.5 * (Math.sin(x / wl * 6.283) * Math.cos(z / wl * 4.1));
    }
    return v;
  };
}

function bands(b, lo, hi) {
  const out = [];
  if (!Array.isArray(b) || !b.length) { for (let v = lo; v <= hi; v += 2) out.push(v); return out; }
  for (const e of b) { const st = Math.max(0.4, e[2]); for (let v = e[0]; v < e[1]; v += st) out.push(v); }
  out.push(b[b.length - 1][1]);
  return out;
}

function buildGround(groundBlock) {
  const relief = (groundBlock && groundBlock.relief) || {};
  const H = makeHeight(relief);
  const size = (groundBlock && groundBlock.size_u) || [140, 160];
  const ctr = (groundBlock && groundBlock.center_stage) || [0, 0, 40];
  const alb = (groundBlock && groundBlock.albedo) || [0.84, 0.67, 0.45];
  const xs = bands(relief.x_bands, ctr[0] - size[0] / 2, ctr[0] + size[0] / 2);
  const zs = bands(relief.z_bands, ctr[2] - size[1] / 2, ctr[2] + size[1] / 2);
  const nx = xs.length, nz = zs.length;
  const pos = [], col = [], idx = [];
  const base = new THREE.Color(alb[0], alb[1], alb[2]);
  const dark = base.clone().multiplyScalar(0.78);
  for (let j = 0; j < nz; j++) for (let i = 0; i < nx; i++) {
    const x = xs[i], z = zs[j], y = H(x, z);
    const p = S2T(x, y, z); pos.push(p.x, p.y, p.z);
    const e = 0.6;
    const sl = Math.min(1, Math.hypot((H(x + e, z) - H(x - e, z)) / (2 * e), (H(x, z + e) - H(x, z - e)) / (2 * e)) * 2.2);
    const c = base.clone().lerp(dark, sl); col.push(c.r, c.g, c.b);
  }
  for (let j = 0; j < nz - 1; j++) for (let i = 0; i < nx - 1; i++) {
    const a = j * nx + i;
    idx.push(a, a + nx, a + nx + 1, a, a + nx + 1, a + 1);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
  g.setIndex(idx); g.computeVertexNormals();
  // cull 必须关：stage→three 的 z 取负是一次镜像、会翻手性，而 Godot/three 判正面靠绕序
  const m = new THREE.MeshLambertMaterial({ vertexColors: true, flatShading: true, side: THREE.DoubleSide });
  const mesh = new THREE.Mesh(g, m);
  mesh.userData.notSelectable = true;
  return { mesh, height: H, tris: (nx - 1) * (nz - 1) * 2 };
}

// ============================================================ 按描述表建场景

function addItem(it) { it.node.userData.item = it; scene.add(it.node); items.push(it); return it; }

function sizeToScale(sizeVal, axis, bounds) {
  if (axis === 'scale' || !bounds) return Math.max(1e-3, sizeVal || 1);
  const b = axis === 'x' ? bounds.x : (axis === 'z' ? bounds.z : bounds.y);
  return Math.max(1e-3, (sizeVal || b)) / Math.max(1e-6, b);
}
function scaleToSize(scaleVal, axis, bounds) {
  if (axis === 'scale' || !bounds) return scaleVal;
  const b = axis === 'x' ? bounds.x : (axis === 'z' ? bounds.z : bounds.y);
  return scaleVal * b;
}

async function buildScene() {
  const doc = spec.doc;
  const gr = buildGround(doc.ground);
  ground = gr.mesh; scene.add(ground);
  const H = gr.height; groundH = H;

  for (const g of spec.groups) {
    const container = dig(doc, g.path);
    if (container == null) { console.warn('描述表路径取不到', g.key, g.path); continue; }

    // ---- 椭圆起伏块
    if (g.kind === 'ridges') {
      if (!Array.isArray(container)) continue;
      container.forEach((r, i) => {
        if (!r || !r.center || !r.radius) return;
        const grp = new THREE.Group();
        const up = (r.height_u || 0) >= 0;
        const disc = new THREE.Mesh(new THREE.CircleGeometry(1, 40),
          new THREE.MeshBasicMaterial({ color: up ? 0x4da3ff : 0xff8a5c, transparent: true, opacity: 0.26, side: THREE.DoubleSide, depthWrite: false }));
        disc.rotation.x = -Math.PI / 2; grp.add(disc);
        const ring = new THREE.Mesh(new THREE.RingGeometry(0.965, 1.0, 40),
          new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.7, side: THREE.DoubleSide, depthWrite: false }));
        ring.rotation.x = -Math.PI / 2; grp.add(ring);
        grp.position.copy(S2T(r.center[0], r.height_u || 0, r.center[1]));
        grp.scale.set(Math.max(0.05, r.radius[0]), 1, Math.max(0.05, r.radius[1]));
        grp.rotation.y = yawS2T(r.angle_deg || 0);
        addItem({ group: g, kind: 'ridge', index: i, id: (g.label + ' ' + (i + 1)), node: grp, base: r });
      });
      continue;
    }

    const entries = g.kind === 'single' ? [container] : (Array.isArray(container) ? container : []);
    const originFrom = g.origin_from ? (dig(doc, g.origin_from) || [0, 0, 0]) : null;

    for (let i = 0; i < entries.length; i++) {
      const e = entries[i];
      if (!e || typeof e !== 'object') continue;
      const assetPath = g.asset_key ? e[g.asset_key] : (g.asset_from ? dig(doc, g.asset_from) : null);
      let node = assetPath ? await loadAsset(assetPath) : null;
      const sizeVal = g.size_key ? e[g.size_key] : null;
      if (node) node = clone(node);
      else node = placeholder(Number(sizeVal) || (g.key === 'character' ? 0.6375 : 0.3),
        g.key === 'character' ? 0xffb43d : 0x8fb3d9);

      const b = node.userData.bounds;
      const s = g.size_key ? sizeToScale(Number(sizeVal), g.size_axis, b) : 1;
      node.scale.set(s, s, s);

      const raw = (g.pos_key && e[g.pos_key]) || [0, 0, 0];
      const sx = raw[0] + (originFrom ? originFrom[0] : 0);
      const sy = raw[1] + (originFrom ? originFrom[1] : 0);
      const sz = raw[2] + (originFrom ? originFrom[2] : 0);
      // 贴地：营地/道具类存的 y 多为 0，按地形高度落地，方便肉眼判断
      const lift = (g.key === 'ridges') ? 0 : H(sx, sz);
      node.position.copy(S2T(sx, sy + lift, sz));
      if (g.yaw_key) node.rotation.y = yawS2T(Number(e[g.yaw_key]) || 0);

      const label = (e.id != null ? String(e.id) : (g.kind === 'single' ? g.label : g.label + ' ' + (i + 1)));
      addItem({
        group: g, kind: g.key, index: i, id: label, node, base: e, bounds: b,
        origin: originFrom, groundLift: lift,
      });
    }
  }

  status('已载入 ' + spec.title + '：' + items.length + ' 个可编辑对象，地形预览 ' + gr.tris + ' 三角');
  $('counts').textContent = spec.title + ' · 对象 ' + items.length;
}

// ============================================================ 选中

function clearHL() {
  if (boxHelper) { scene.remove(boxHelper); boxHelper.geometry.dispose(); boxHelper = null; }
  for (const [m, v] of savedMat) {
    if (m.emissive) { m.emissive.setHex(v.hex); if ('emissiveIntensity' in m) m.emissiveIntensity = v.inten; }
    if (v.op !== undefined) m.opacity = v.op;
  }
  savedMat.clear();
}

function applyHL(it) {
  boxHelper = new THREE.BoxHelper(it.node, 0xffb43d);
  boxHelper.material.depthTest = false;
  scene.add(boxHelper);
  it.node.traverse((o) => {
    if (!o.isMesh || !o.material) return;
    for (const m of (Array.isArray(o.material) ? o.material : [o.material])) {
      if (m.emissive) {
        savedMat.set(m, { hex: m.emissive.getHex(), inten: m.emissiveIntensity });
        m.emissive.setHex(0x6b4a00); if ('emissiveIntensity' in m) m.emissiveIntensity = 1.0;
      } else if (m.transparent) {
        savedMat.set(m, { hex: 0, inten: 1, op: m.opacity });
        m.opacity = Math.min(1, m.opacity + 0.3);
      }
    }
  });
}

function select(it) {
  clearHL(); selected = it || null;
  if (!selected) { gizmo.detach(); renderList(); renderProps(); return; }
  if (selected.group.key !== currentCat) { currentCat = selected.group.key; renderCats(); }
  applyHL(selected); gizmo.attach(selected.node);
  renderList(); renderProps();
}

function itemOf(obj) { let o = obj; while (o) { if (o.userData && o.userData.item) return o.userData.item; o = o.parent; } return null; }

function pick(ev) {
  const r = renderer.domElement.getBoundingClientRect();
  const ndc = new THREE.Vector2(((ev.clientX - r.left) / r.width) * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1);
  raycaster.setFromCamera(ndc, camera);
  const hits = raycaster.intersectObjects(scene.children, true);
  for (const h of hits) {
    if (h.object === ground || (h.object.userData && h.object.userData.notSelectable)) continue;
    const it = itemOf(h.object); if (it) return { item: it, point: h.point };
  }
  for (const h of hits) if (h.object === ground) return { item: null, point: h.point };
  return { item: null, point: null };
}

// ============================================================ 面板

function renderCats() {
  const seen = [];
  for (const g of spec.groups) {
    const n = items.filter((i) => i.group.key === g.key).length;
    if (n > 0 || g.kind === 'single') seen.push({ g, n });
  }
  if (!currentCat && seen.length) currentCat = seen[0].g.key;
  let hid = 0; for (const k in hiddenStore) hid += (hiddenStore[k] || []).length;
  $('cats').innerHTML = seen.map(({ g, n }) =>
    '<button data-c="' + g.key + '" class="' + (g.key === currentCat ? 'on' : '') + '">' +
    g.label + ' <span style="opacity:.6">' + n + '</span></button>').join('') +
    '<button data-c="__hidden" class="' + (currentCat === '__hidden' ? 'on' : '') + '"' +
    ' title="隐藏的条目都在这里，点一下排队恢复">已隐藏 <span style="opacity:.6">' + hid + '</span></button>';
  $('cats').querySelectorAll('button').forEach((b) => b.addEventListener('click', () => {
    currentCat = b.dataset.c; renderCats(); renderList();
  }));
}

function renderList() {
  if (currentCat === '__hidden') { renderHiddenList(); return; }
  const rows = items.filter((i) => i.group.key === currentCat);
  $('list').innerHTML = rows.length ? rows.map((it) => {
    const sp = T2S(it.node.position);
    return '<div class="row' + (it === selected ? ' sel' : '') + '" data-i="' + items.indexOf(it) + '">' +
      '<span class="t">' + it.id + '</span><span class="n">' + fmt(sp[0]) + ' , ' + fmt(sp[2]) + '</span></div>';
  }).join('') : '<div style="padding:10px;color:var(--dim);font-size:13px">这一类没有条目</div>';
  $('list').querySelectorAll('.row').forEach((r) => r.addEventListener('click', () => {
    select(items[parseInt(r.dataset.i, 10)]); frameSel(true);
  }));
}

function fldXYZ(label, trio) {
  return '<div class="fld"><label>' + label + '</label><div class="xyz">' + trio.map(([t, v, k]) =>
    k === null ? '<div class="c"></div>' :
      '<div class="c"><span>' + t + '</span><input type="number" step="0.01" value="' + fmt(v) + '" data-k="' + k + '"></div>').join('') + '</div></div>';
}
function fld1(label, v, k, note) {
  return '<div class="fld"><label>' + label + '</label><input type="number" step="0.01" value="' + fmt(v) + '" data-k="' + k + '">' +
    (note ? '<div style="font-size:11px;color:var(--dim);margin-top:3px">' + note + '</div>' : '') + '</div>';
}

function renderProps() {
  const host = $('props');
  if (!selected) { host.innerHTML = '<div class="none">还没选中东西。<br>在画面里点一个模型，或者从左边列表里点一行。</div>'; return; }
  const it = selected, n = it.node, g = it.group, sp = T2S(n.position);
  const out = ['<h3>' + it.id + '　<span style="color:var(--dim);font-weight:400">' + g.label + '</span></h3>'];

  if (it.kind === 'ridge') {
    out.push(fldXYZ('中心 / 高度', [['X', sp[0], 'rx'], ['高', sp[1], 'rh'], ['Z', sp[2], 'rz']]));
    out.push(fldXYZ('半径', [['横', n.scale.x, 'sx'], ['—', 0, null], ['纵', n.scale.z, 'sz']]));
    out.push(fld1('转向（度）', yawT2S(n.rotation.y), 'yaw'));
    out.push('<div class="none" style="font-size:12px">高度可为负（挖浅坑）。蓝=凸起，橙=下凹。</div>');
  } else {
    const shown = [sp[0] - (it.origin ? it.origin[0] : 0),
                   sp[1] - (it.origin ? it.origin[1] : 0) - it.groundLift,
                   sp[2] - (it.origin ? it.origin[2] : 0)];
    out.push(fldXYZ(g.origin_from ? '位置（相对组原点）' : '位置',
      [['X', shown[0], 'px'], ['Y', shown[1], 'py'], ['Z', shown[2], 'pz']]));
    if (g.yaw_key) out.push(fld1('转向（度）', yawT2S(n.rotation.y), 'yaw'));
    if (g.size_key) {
      const sv = scaleToSize(n.scale.y, g.size_axis, it.bounds);
      out.push(fld1(g.size_key + (g.size_axis === 'scale' ? '（倍率）' : '（单位）'), sv, 'size'));
    }
    for (const ex of (g.extra_keys || [])) out.push(fld1(ex, Number(it.base[ex]) || 0, 'x:' + ex));
    if (g.locked) out.push('<div class="none" style="font-size:12px">只读键：' + g.locked.join('、') + '（已定版，编辑器不写回）</div>');
    if (g.note) out.push('<div class="none" style="font-size:12px">' + g.note + '</div>');
  }
  out.push('<hr><div class="none" style="font-size:12px">数字可直接改，回车生效。Y 显示的是相对地面的抬升。</div>');
  host.innerHTML = out.join('');
  host.querySelectorAll('input[data-k]').forEach((inp) => {
    inp.addEventListener('change', () => applyField(inp.dataset.k, parseFloat(inp.value)));
    inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') inp.blur(); });
  });
}

function applyField(k, v) {
  if (!selected || !isFinite(v)) return;
  pushUndo(selected);
  const it = selected, n = it.node, g = it.group, sp = T2S(n.position);
  const o = it.origin || [0, 0, 0];
  if (k === 'px') n.position.copy(S2T(v + o[0], sp[1], sp[2]));
  else if (k === 'py') n.position.copy(S2T(sp[0], v + o[1] + it.groundLift, sp[2]));
  else if (k === 'pz') n.position.copy(S2T(sp[0], sp[1], v + o[2]));
  else if (k === 'rx') n.position.copy(S2T(v, sp[1], sp[2]));
  else if (k === 'rh') n.position.copy(S2T(sp[0], v, sp[2]));
  else if (k === 'rz') n.position.copy(S2T(sp[0], sp[1], v));
  else if (k === 'sx') n.scale.x = Math.max(0.05, v);
  else if (k === 'sz') n.scale.z = Math.max(0.05, v);
  else if (k === 'yaw') n.rotation.y = yawS2T(v);
  else if (k === 'size') { const s = sizeToScale(v, g.size_axis, it.bounds); n.scale.set(s, s, s); }
  else if (k.startsWith('x:')) it.base['__' + k.slice(2)] = v;   // extra 键暂存，保存时读回
  afterXform();
}

function afterXform() { if (boxHelper && selected) boxHelper.setFromObject(selected.node); renderProps(); }

// ============================================================ 撤销

function pushUndo(it) {
  if (!it) return;
  undoStack.push({ it, p: it.node.position.clone(), r: it.node.rotation.clone(), s: it.node.scale.clone() });
  if (undoStack.length > 150) undoStack.shift();
}
function undo() {
  const s = undoStack.pop();
  if (!s) { status('没有可撤销的了'); return; }
  if (s.restore) {
    const it = s.restore;
    scene.add(it.node); items.push(it); it.node.userData.item = it;
    if (s.wasHide) {
      const arr = pendingHides[s.groupKey] || [];
      const k = arr.findIndex((r) => (r.id != null && it.base && r.id === it.base.id) || r.index === it.index);
      if (k >= 0) arr.splice(k, 1);
    } else if (!s.wasNew) {
      const arr = pendingDeletes[s.groupKey] || [];
      const k = arr.findIndex((r) => (r.id != null && it.base && r.id === it.base.id) || r.index === it.index);
      if (k >= 0) arr.splice(k, 1);
    }
    currentCat = s.groupKey; renderCats(); renderList(); select(it); refreshPendingBadge();
    status('已撤销' + (s.wasHide ? '隐藏' : '删除') + '「' + it.id + '」');
    return;
  }
  s.it.node.position.copy(s.p); s.it.node.rotation.copy(s.r); s.it.node.scale.copy(s.s);
  select(s.it); status('已撤销');
}

// ============================================================ 删除 / 导入

function pendingCount() {
  let d = 0; for (const k in pendingDeletes) d += pendingDeletes[k].length;
  let h = 0; for (const k in pendingHides) h += pendingHides[k].length;
  let u = 0; for (const k in pendingUnhides) u += pendingUnhides[k].length;
  let hid = 0; for (const k in hiddenStore) hid += (hiddenStore[k] || []).length;
  const a = items.filter((i) => i.isNew).length;
  return { d, a, h, u, hid };
}

function refreshPendingBadge() {
  const { d, a, h, u, hid } = pendingCount();
  const bits = [];
  if (a) bits.push('待新增 ' + a);
  if (h) bits.push('待隐藏 ' + h);
  if (u) bits.push('待恢复 ' + u);
  if (d) bits.push('待删除 ' + d);
  if (hid) bits.push('已隐藏 ' + hid);
  $('counts').textContent = spec.title + ' · 对象 ' + items.length + (bits.length ? ' · ' + bits.join(' / ') : '');
}

function deleteSelected() {
  if (!selected) { status('先选中一个条目', true); return; }
  const it = selected, g = it.group;
  if (g.kind === 'single') {
    status('「' + g.label + '」是场景骨架里的单体，不能删；要挪走就把它拖出画外', true);
    return;
  }
  if (!it.isNew) {
    const left = items.filter((x) => x.group.key === g.key).length - 1;
    const already = (pendingDeletes[g.key] || []).length;
    const msg = left <= 0
      ? '这会把「' + g.label + '」整组删空（删除不可恢复）。\n\n一般用「隐藏」更安全 —— 确定要删除吗？'
      : '删除「' + it.id + '」？删除不可恢复，一般用「隐藏」就够。';
    if (!confirm(msg)) { status('已取消删除'); return; }
    const rec = { index: it.index };
    if (it.base && it.base.id != null) rec.id = it.base.id;
    else if (it.base) {
      // 没有 id 的类别只能按下标删，而 Codex 随时在写同一个文件。
      // 回传关键值快照，服务端比对不一致就拒绝，避免删错条目。
      rec.expect = {};
      if (it.kind === 'ridge') {
        for (const k of ['center', 'radius', 'height_u', 'angle_deg'])
          if (it.base[k] !== undefined) rec.expect[k] = it.base[k];
      } else {
        if (g.pos_key && it.base[g.pos_key] !== undefined) rec.expect[g.pos_key] = it.base[g.pos_key];
        if (g.size_key && it.base[g.size_key] !== undefined) rec.expect[g.size_key] = it.base[g.size_key];
      }
    }
    (pendingDeletes[g.key] || (pendingDeletes[g.key] = [])).push(rec);
  }
  // 撤销：把节点和条目放回去
  undoStack.push({ restore: it, groupKey: g.key, wasNew: !!it.isNew });
  scene.remove(it.node);
  items.splice(items.indexOf(it), 1);
  select(null); renderCats(); renderList(); refreshPendingBadge();
  status('已标记删除「' + it.id + '」—— 保存后才真正写入；⌘Z 可撤销');
}

function hideSelected() {
  if (!selected) { status('先选中一个条目', true); return; }
  const it = selected, g = it.group;
  if (g.kind !== 'list') {
    status('「' + g.label + '」不是数组条目（单体/起伏块）；要它消失请把位置挪出画外', true);
    return;
  }
  if (it.isNew) { status('这是还没保存的新条目，直接删就行', true); return; }
  const rec = { index: it.index };
  if (it.base && it.base.id != null) rec.id = it.base.id;
  (pendingHides[g.key] || (pendingHides[g.key] = [])).push(rec);
  undoStack.push({ restore: it, groupKey: g.key, wasHide: true });
  scene.remove(it.node);
  items.splice(items.indexOf(it), 1);
  select(null); renderCats(); renderList(); refreshPendingBadge();
  status('已标记隐藏「' + it.id + '」—— 保存后游戏里不再出现，可在「已隐藏」里恢复；⌘Z 撤销');
}

function renderHiddenList() {
  const host = $('list');
  const rows = [];
  for (const gk in hiddenStore) {
    const g = (spec.groups || []).find((x) => x.key === gk);
    (hiddenStore[gk] || []).forEach((rec, i) => {
      const e = (rec && rec.entry) || {};
      const marked = (pendingUnhides[gk] || []).some((u) => String(u.id) === String(e.id) || u.hidden_index === i);
      rows.push('<div class="row" data-g="' + gk + '" data-i="' + i + '" data-id="' +
        (e.id != null ? e.id : '') + '">' +
        '<span class="t">' + (g ? g.label : gk) + ' · ' + (e.id != null ? e.id : '#' + i) + '</span>' +
        '<span class="n">' + (marked ? '待恢复' : '点此恢复') + '</span></div>');
    });
  }
  host.innerHTML = rows.length ? rows.join('')
    : '<div style="padding:10px;color:var(--dim);font-size:13px">没有隐藏的条目</div>';
  host.querySelectorAll('.row').forEach((r) => r.addEventListener('click', () => {
    const gk = r.dataset.g, i = parseInt(r.dataset.i, 10), id = r.dataset.id;
    const arr = pendingUnhides[gk] || (pendingUnhides[gk] = []);
    const k = arr.findIndex((u) => (id && String(u.id) === id) || u.hidden_index === i);
    if (k >= 0) arr.splice(k, 1); else arr.push(id ? { id } : { hidden_index: i });
    renderHiddenList(); refreshPendingBadge();
    status('保存后生效：恢复 ' + (pendingUnhides[gk] || []).length + ' 个隐藏条目');
  }));
}

function eligibleAddGroups() {
  return (spec.groups || []).filter((g) => g.kind === 'list' && g.asset_key);
}

function fillAddTarget() {
  const sel = $('addTarget');
  const list = eligibleAddGroups();
  sel.innerHTML = list.map((g) => '<option value="' + g.key + '">加到：' + g.label + '</option>').join('');
  if (!list.length) {
    sel.innerHTML = '<option value="">（本场景没有可追加的类别）</option>';
    const l = $('l-import'); if (l) l.style.opacity = '0.45';
  }
}

async function importFiles(files) {
  const gkey = $('addTarget').value;
  const g = (spec.groups || []).find((x) => x.key === gkey);
  if (!g) { status('先选一个要加到哪一类', true); return; }
  for (const f of files) {
    const ext = f.name.split('.').pop().toLowerCase();
    if (!['glb', 'gltf', 'fbx'].includes(ext)) { status('只认 .glb / .gltf / .fbx：' + f.name, true); continue; }
    status('上传 ' + f.name + '…');
    let up;
    try {
      const buf = await f.arrayBuffer();
      let bin = ''; const bytes = new Uint8Array(buf);
      const CH = 0x8000;
      for (let i = 0; i < bytes.length; i += CH) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
      const r = await fetch('/upload', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ view: spec.view, name: f.name, data_b64: btoa(bin) }) });
      up = await r.json();
      if (!r.ok || up.error) { status('上传失败：' + (up.error || r.status), true); continue; }
    } catch (e) { status('上传出错：' + e.message, true); continue; }

    const proto = await loadAsset(up.res_path);
    const node = proto ? clone(proto) : placeholder(0.3, 0x8fb3d9);
    const b = node.userData.bounds;
    // 默认尺寸：按同类现有条目的 size 中位数，落在画面里能看见
    const peers = items.filter((i) => i.group.key === gkey && !i.isNew);
    let defSize = 0.3;
    if (peers.length) {
      const arr = peers.map((i) => scaleToSize(i.node.scale.y, g.size_axis, i.bounds)).sort((a, c) => a - c);
      defSize = arr[Math.floor(arr.length / 2)];
    }
    const s = sizeToScale(defSize, g.size_axis, b);
    node.scale.set(s, s, s);
    // 放在相机前方、地面上
    const front = camTgt.clone().sub(camPos).setY(0).normalize().multiplyScalar(3.2).add(camPos);
    const sp = T2S(front);
    const lift = groundH ? groundH(sp[0], sp[2]) : 0;
    node.position.copy(S2T(sp[0], lift, sp[2]));

    const it = addItem({ group: g, kind: g.key, index: -1, id: f.name, node, bounds: b,
                         origin: null, groundLift: lift, isNew: true, newAsset: up.res_path });
    currentCat = gkey; renderCats(); renderList(); select(it); refreshPendingBadge();
    const impMsg = up.godot_imported ? '，已完成 Godot 导入'
      : '，⚠ Godot 导入未成功（引擎会静默跳过它）：' + (up.import_error || '原因未知');
    status('已导入「' + f.name + '」→ ' + up.saved_to + '（' + Math.round(up.bytes / 1024) + ' KB）' +
      impMsg + '；拖手柄摆好后按保存。' +
      (ext === 'fbx' ? ' 注意：.fbx 外链贴图带不上，游戏里可能是白模。' : ''));
    if (!up.godot_imported) console.error('Godot 导入失败', up);
    console.log(up.note);
  }
}

// ============================================================ 保存

function collectAdds() {
  const out = {};
  for (const it of items) {
    if (!it.isNew) continue;
    const g = it.group, n = it.node, sp = T2S(n.position);
    (out[g.key] || (out[g.key] = [])).push({
      asset: it.newAsset,
      pos: [sp[0], sp[1] - it.groundLift, sp[2]],
      yaw: yawT2S(n.rotation.y),
      size: scaleToSize(n.scale.y, g.size_axis, it.bounds),
    });
  }
  return out;
}

function collectEdits() {
  const out = {};
  for (const it of items) {
    if (it.isNew) continue;
    const g = it.group, n = it.node, sp = T2S(n.position);
    const arr = out[g.key] || (out[g.key] = []);
    if (it.kind === 'ridge') {
      arr.push({ index: it.index, center: [sp[0], sp[2]], height_u: sp[1],
                 radius: [n.scale.x, n.scale.z], angle_deg: yawT2S(n.rotation.y) });
      continue;
    }
    const o = it.origin || [0, 0, 0];
    const rec = { index: it.index };
    if (it.base && it.base.id != null) rec.id = it.base.id;
    if (g.pos_key) rec.pos = [sp[0] - o[0], sp[1] - o[1] - it.groundLift, sp[2] - o[2]];
    if (g.yaw_key) rec.yaw = yawT2S(n.rotation.y);
    if (g.size_key) rec.size = scaleToSize(n.scale.y, g.size_axis, it.bounds);
    for (const ex of (g.extra_keys || [])) {
      const v = it.base['__' + ex];
      if (v !== undefined) rec[ex] = v;
    }
    arr.push(rec);
  }
  return out;
}

async function save(overwrite) {
  if (overwrite && !confirm('这会直接改游戏正在读的 ' + spec.file + '。\nCodex 可能同时在写它。\n（会先自动备份）确定？')) return;
  status('保存中…');
  try {
    const r = await fetch('/save', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ view: spec.view, edits: collectEdits(), adds: collectAdds(),
                             deletes: pendingDeletes, hides: pendingHides,
                             unhides: pendingUnhides, overwrite: !!overwrite }) });
    const j = await r.json();
    if (!r.ok || j.error) { status('保存失败：' + (j.error || r.status), true); return; }
    const na = (j.added || []).length, nr = (j.removed || []).length;
    const nh = (j.hidden || []).length, nu = (j.unhidden || []).length;
    status('已保存 → ' + j.wrote + '（改值 ' + j.changed + ' 项' +
      (na ? '，新增 ' + na : '') + (nh ? '，隐藏 ' + nh : '') +
      (nu ? '，恢复 ' + nu : '') + (nr ? '，删除 ' + nr : '') +
      '，顶层键 ' + j.top_level_keys + '，叶子 ' + j.leaves_before + '→' + j.leaves_after + '）' +
      (j.notes.length ? ' · ' + j.notes.length + ' 条跳过' : ''));
    if (j.notes.length) console.warn('跳过/拒绝的条目:', j.notes);
    if (na) console.log('新增:', j.added);
    if (nr) console.log('删除:', j.removed);
    if (na || nr || nh || nu) {
      for (const k in pendingDeletes) delete pendingDeletes[k];
      for (const k in pendingHides) delete pendingHides[k];
      for (const k in pendingUnhides) delete pendingUnhides[k];
      for (const it of items) if (it.isNew) { it.isNew = false; }
      refreshPendingBadge();
      status($('status').textContent + ' —— 结构变了，建议刷新页面重新读一次');
    }
  } catch (e) { status('保存出错：' + e.message, true); }
}

// ============================================================ 实机渲染对比

let sceneList = null;          // /scenes 的结果，带 capture_flags
let lastShot = null;           // { url, report, label }
let rendering = false;

function fillPresets() {
  const sel = $('renderPreset');
  const me = (sceneList && sceneList.scenes || []).find((x) => x.view === spec.view);
  const flags = (me && me.capture_flags) || [{ label: '默认', args: [] }];
  sel.innerHTML = flags.map((f, i) =>
    '<option value="' + i + '">' + f.label + '</option>').join('');
  sel._flags = flags;
}

function numRow(label, a, b, digits, lowerBetter) {
  if (a == null && b == null) return '';
  const f = (v) => (v == null ? '—' : Number(v).toFixed(digits));
  let delta = '';
  if (a != null && b != null) {
    const d = Number(b) - Number(a);
    if (Math.abs(d) > Math.pow(10, -digits) / 2) {
      const worse = lowerBetter ? d > 0 : false;
      delta = ' <span class="' + (worse ? 'up' : 'dn') + '">(' +
        (d > 0 ? '+' : '') + d.toFixed(digits) + ')</span>';
    }
  }
  return '<span style="margin-right:16px">' + label + ' <b>' + f(b) + '</b>' +
    (a != null ? ' <span style="opacity:.55">← ' + f(a) + '</span>' : '') + delta + '</span>';
}

function showShotNumbers(prev, cur) {
  const p = prev || {}, c = cur || {};
  const parts = [];
  for (const [k, lab] of [['arch', '拱门'], ['tree', '生命树'], ['character', '人物'], ['fortress', '城堡']]) {
    if (c[k] || p[k]) parts.push(numRow(lab + '占比', (p[k] || {}).height_fraction, (c[k] || {}).height_fraction, 3));
  }
  parts.push('<br>');
  parts.push(numRow('draw calls', p.draw_calls, c.draw_calls, 0, true));
  parts.push(numRow('P50 ms', p.p50, c.p50, 3, true));
  parts.push(numRow('P95 ms', p.p95, c.p95, 3, true));
  if (c.horizon_y_uv != null) parts.push(numRow('地平线 y', p.horizon_y_uv, c.horizon_y_uv, 3));
  $('shotNums').innerHTML = parts.join('');
}

function setWipe(v) {
  const cur = $('shotCur'), edge = $('shotEdge');
  cur.style.clipPath = 'inset(0 ' + (100 - v) + '% 0 0)';
  if (v > 0 && v < 100 && $('shotPrev').src) {
    edge.style.display = 'block';
    edge.style.left = v + '%';
  } else edge.style.display = 'none';
}

async function doRender() {
  if (rendering) { status('上一张还在渲，等一下', true); return; }
  const sel = $('renderPreset');
  const flags = ((sel._flags || [])[parseInt(sel.value || '0', 10)] || { args: [] }).args;
  rendering = true;
  $('b-render').textContent = '渲染中…';
  status('实机渲染中（约 5 秒，用的是副本，不写线上文件）…');
  try {
    const r = await fetch('/render', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ view: spec.view, edits: collectEdits(), adds: collectAdds(),
                             deletes: pendingDeletes, hides: pendingHides,
                             unhides: pendingUnhides, flags }) });
    const j = await r.json();
    if (!r.ok || j.error) { status('渲染起不来：' + (j.error || r.status), true); return; }
    const job = j.job;
    let st = null;
    for (let i = 0; i < 80; i++) {
      await new Promise((s2) => setTimeout(s2, 900));
      st = await (await fetch('/render/status?job=' + encodeURIComponent(job))).json();
      if (st.state === 'done' || st.state === 'failed') break;
      status('实机渲染：' + st.state + '…');
    }
    if (!st || st.state !== 'done') {
      status('渲染失败：' + ((st && (st.error || (st.log_errors || [])[0])) || '未知'), true);
      if (st) console.error('渲染日志', st.log_errors, st.log_tail);
      return;
    }
    const url = '/render/image?job=' + encodeURIComponent(job) + '&t=' + Date.now();
    const prev = lastShot;
    $('shotPrev').src = prev ? prev.url : '';
    $('shotCur').src = url;
    $('shot').classList.add('show');
    $('shotTitle').textContent = '实机渲染 · ' + sel.options[sel.selectedIndex].text +
      '（' + st.seconds + ' 秒）' + (prev ? ' —— 拖滑块与上一次对比' : '');
    $('wipeLab').style.display = prev ? '' : 'none';
    $('wipe').value = prev ? 50 : 100;
    setWipe(prev ? 50 : 100);
    showShotNumbers(prev && prev.report, st.report);
    lastShot = { url, report: st.report, label: sel.options[sel.selectedIndex].text };
    const warn = st.live_file_untouched ? '' : ' ⚠ 渲染期间线上文件被改动过（可能是 Codex）';
    // 渲染前服务端已把 edits/adds/deletes/hides/unhides 一并写进副本，
    // 结构性改动（新增/删除/隐藏/恢复）在文件里已经生效，页面里的待办要清掉，
    // 否则下一次渲染会再发一遍，服务端找不到条目只会记一条「跳过」，但状态栏会误导人。
    const sv = j.saved || st.saved || {};
    const na = (sv.added || []).length, nr = (sv.removed || []).length;
    const nh = (sv.hidden || []).length, nu = (sv.unhidden || []).length;
    if (na || nr || nh || nu) {
      for (const k in pendingDeletes) delete pendingDeletes[k];
      for (const k in pendingHides) delete pendingHides[k];
      for (const k in pendingUnhides) delete pendingUnhides[k];
      for (const it of items) if (it.isNew) { it.isNew = false; }
      refreshPendingBadge();
    }
    if ((sv.notes || []).length) console.warn('渲染前保存时跳过/拒绝的条目:', sv.notes);
    status('渲染完成（' + st.seconds + ' 秒）' +
      (sv.changed ? '；已存副本，改值 ' + sv.changed + ' 项' : '') +
      (nh ? '，隐藏 ' + nh : '') + (nu ? '，恢复 ' + nu : '') +
      (na ? '，新增 ' + na : '') + (nr ? '，删除 ' + nr : '') + warn);
    if ((st.log_errors || []).length) console.warn('渲染日志里的问题:', st.log_errors);
  } catch (e) {
    status('渲染出错：' + e.message, true);
  } finally {
    rendering = false;
    $('b-render').textContent = '实机渲染';
  }
}

// ============================================================ 镜头

function frameSel(gentle) {
  if (!selected) return;
  const box = new THREE.Box3().setFromObject(selected.node);
  const c = new THREE.Vector3(); box.getCenter(c);
  const r = Math.max(0.3, box.getSize(new THREE.Vector3()).length() * 0.5);
  const dir = camera.position.clone().sub(orbit.target).normalize();
  const d = gentle ? Math.max(r * 4, camera.position.distanceTo(orbit.target) * 0.75) : r * 3.2;
  orbit.target.copy(c); camera.position.copy(c.clone().add(dir.multiplyScalar(d))); orbit.update();
}
function gameCam() {
  camera.position.copy(camPos); orbit.target.copy(camTgt);
  camera.fov = camFov; camera.updateProjectionMatrix(); orbit.update();
  status('回到游戏机位（fov ' + camFov + '）—— 这就是玩家看到的构图');
}
function topCam() {
  const c = camTgt.clone();
  orbit.target.copy(c); camera.position.copy(c.clone().setY(c.y + 40)).add(new THREE.Vector3(0, 0, 0.01));
  orbit.update(); status('俯视（方便摆位置，不是游戏构图）');
}

// ============================================================ 启动

async function main() {
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x2b2f3a);
  camera = new THREE.PerspectiveCamera(40, 1, 0.03, 3000);
  renderer = new THREE.WebGLRenderer({ canvas: $('cv'), antialias: true });
  renderer.setPixelRatio(Math.min(2, devicePixelRatio));

  scene.add(new THREE.HemisphereLight(0xbcd0f0, 0x6b5a48, 1.25));
  const sun = new THREE.DirectionalLight(0xffd7ab, 1.9);
  sun.position.set(-40, 26, 60); scene.add(sun);

  orbit = new OrbitControls(camera, renderer.domElement);
  orbit.enableDamping = true; orbit.dampingFactor = 0.12;
  orbit.mouseButtons = { LEFT: THREE.MOUSE.ROTATE, MIDDLE: THREE.MOUSE.PAN, RIGHT: THREE.MOUSE.PAN };

  gizmo = new TransformControls(camera, renderer.domElement);
  gizmo.setSize(0.9);
  gizmo.addEventListener('dragging-changed', (e) => { orbit.enabled = !e.value; if (e.value) pushUndo(selected); else afterXform(); });
  gizmo.addEventListener('objectChange', afterXform);
  const helper = gizmo.getHelper ? gizmo.getHelper() : gizmo;
  helper.traverse((o) => { o.userData.notSelectable = true; });
  scene.add(helper);

  raycaster = new THREE.Raycaster();
  resize(); addEventListener('resize', resize);

  // 点选：pointer 与 mouse 两套都挂并去重 —— 只挂 pointer 时某些输入栈只发 mouse，
  // 症状就是"点了完全没反应"，正是旧编辑器被否的那个感受。
  let down = null, lastClick = 0;
  const onDown = (ev) => {
    if (ev.altKey) { orbit.enabled = true; down = null; return; }
    const r = pick(ev); orbit.enabled = !r.item; down = { x: ev.clientX, y: ev.clientY };
  };
  const onUp = (ev) => {
    if (!down) return;
    const moved = Math.hypot(ev.clientX - down.x, ev.clientY - down.y); down = null;
    if (moved > 5) return;
    const now = performance.now(); if (now - lastClick < 60) return; lastClick = now;
    select(pick(ev).item);     // 点空白只取消选中，绝不生成东西
  };
  renderer.domElement.addEventListener('pointerdown', onDown, true);
  renderer.domElement.addEventListener('mousedown', onDown, true);
  renderer.domElement.addEventListener('pointerup', onUp);
  renderer.domElement.addEventListener('mouseup', onUp);

  const modes = { 'm-move': 'translate', 'm-rot': 'rotate', 'm-scale': 'scale' };
  Object.keys(modes).forEach((id) => $(id).addEventListener('click', () => setMode(modes[id])));
  $('b-frame').addEventListener('click', () => frameSel(false));
  $('b-cam').addEventListener('click', gameCam);
  $('b-top').addEventListener('click', topCam);
  $('b-undo').addEventListener('click', undo);
  // 沙丘块的盘子半径很大（巴格达实测 14×5），连起来会挡视线，所以给个显隐开关
  const bR = $('b-ridges');
  if (bR) bR.addEventListener('click', () => {
    const on = !bR.classList.contains('on');
    bR.classList.toggle('on', on);
    for (const it of items) if (it.kind === 'ridge') it.node.visible = on;
    if (!on && selected && selected.kind === 'ridge') select(null);
    status(on ? '沙丘块已显示' : '沙丘块已隐藏（不影响保存）');
  });
  const bG = $('b-ground');
  if (bG) bG.addEventListener('click', () => {
    const on = !bG.classList.contains('on');
    bG.classList.toggle('on', on);
    if (ground) ground.visible = on;
    status(on ? '地形预览已显示' : '地形预览已隐藏');
  });

  $('b-hide').addEventListener('click', hideSelected);
  $('b-del').addEventListener('click', deleteSelected);
  $('f-import').addEventListener('change', (e) => { importFiles([...e.target.files]); e.target.value = ''; });
  // 拖文件进画面也能导入
  const mid = $('mid'), drop = $('drop');
  ['dragenter', 'dragover'].forEach((t) => mid.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add('show'); }));
  ['dragleave', 'drop'].forEach((t) => mid.addEventListener(t, (e) => { e.preventDefault(); drop.classList.remove('show'); }));
  mid.addEventListener('drop', (e) => { const f = [...(e.dataTransfer.files || [])]; if (f.length) importFiles(f); });

  $('b-render').addEventListener('click', doRender);
  $('wipe').addEventListener('input', (e) => setWipe(+e.target.value));
  $('shotClose').addEventListener('click', () => $('shot').classList.remove('show'));
  $('shotSwap').addEventListener('click', () => {
    const a = $('shotPrev').src, b = $('shotCur').src;
    $('shotPrev').src = b; $('shotCur').src = a;
    status('已互换左右');
  });

  $('b-save').addEventListener('click', () => save(false));
  $('b-save-live').addEventListener('click', () => save(true));

  addEventListener('keydown', (e) => {
    const t = e.target; if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA')) return;
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z') { e.preventDefault(); undo(); return; }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const k = e.key.toLowerCase();
    if (k === 'e') setMode('translate'); else if (k === 'r') setMode('rotate');
    else if (k === 't') setMode('scale'); else if (k === 'escape') select(null);
  });

  // 场景切换器
  try {
    const list = await (await fetch('/scenes')).json();
    sceneList = list;
    const host = $('sceneSel');
    if (host) {
      host.innerHTML = list.scenes.map((s) =>
        '<button data-v="' + s.view + '">' + s.title + '</button>').join('');
      host.querySelectorAll('button').forEach((b) => b.addEventListener('click', () => {
        location.search = '?view=' + b.dataset.v;
      }));
    }
  } catch (e) { /* 切换器不是必需 */ }

  // 提示框加关闭：窄窗口下它会盖住画布
  const hb = $('hintbox');
  if (hb) {
    const x = document.createElement('button');
    x.textContent = '知道了';
    x.style.cssText = 'margin-top:7px;padding:3px 9px;font-size:12px';
    x.addEventListener('click', () => hb.remove());
    hb.appendChild(document.createElement('br'));
    hb.appendChild(x);
  }

  const qs = new URLSearchParams(location.search);
  const view = qs.get('view') || '';
  const source = qs.get('source') || '';      // copy | live；不传则由服务端决定（优先副本）
  status('正在读场景…');
  try {
    const p = new URLSearchParams();
    if (view) p.set('view', view);
    if (source) p.set('source', source);
    const qstr = p.toString();
    spec = await (await fetch('/scene' + (qstr ? '?' + qstr : ''))).json();
    if (spec.error) { status('读不到场景：' + spec.error, true); return; }
  } catch (e) { status('读不到场景：' + e.message, true); return; }

  document.title = spec.title + ' · 地图摆放器';
  // 明确告诉用户这一页读的是副本还是线上，并给一个回到线上的入口
  const tag = $('srcTag');
  if (tag) {
    if (spec.loaded_from === 'copy') {
      tag.textContent = '正在编辑你的副本' + (spec.live_newer_than_copy ? '（线上已更新，可能落后）' : '');
      tag.style.background = 'rgba(255,180,61,.18)'; tag.style.color = 'var(--accent)';
      tag.title = spec.loaded_path + ' —— 点一下改读线上文件（会丢掉副本里未合并的改动）';
      tag.style.cursor = 'pointer';
      tag.addEventListener('click', () => {
        if (confirm('改为读线上文件？\n你副本里的改动不会被删除，但这一页会显示线上状态。')) {
          location.search = '?view=' + spec.view + '&source=live';
        }
      });
    } else {
      tag.textContent = '正在编辑线上文件的状态';
      tag.style.background = 'rgba(77,163,255,.16)'; tag.style.color = 'var(--accent2)';
      tag.title = spec.loaded_path;
    }
  }
  const cs = spec.camera || {};
  const cblk = dig(spec.doc, cs.path || []) || {};
  const cp = cblk[cs.pos_key] || [0, 0.3, 0];
  const cl = cblk[cs.look_key] || [0, 1.5, 10];
  camFov = Number(cblk[cs.fov_key]) || 40;
  camPos = S2T(cp[0], cp[1], cp[2]); camTgt = S2T(cl[0], cl[1], cl[2]);
  camera.fov = camFov; camera.updateProjectionMatrix();
  camera.position.copy(camPos); orbit.target.copy(camTgt); orbit.update();

  $('sceneSel').querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.v === spec.view));

  hiddenStore = spec.hidden || {};
  fillAddTarget();
  fillPresets();
  await buildScene();
  renderCats(); renderList(); renderProps();
  animate();
}

function setMode(m) {
  gizmo.setMode(m);
  $('m-move').classList.toggle('on', m === 'translate');
  $('m-rot').classList.toggle('on', m === 'rotate');
  $('m-scale').classList.toggle('on', m === 'scale');
}
function resize() {
  const mid = $('mid'), w = mid.clientWidth, h = mid.clientHeight;
  renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix();
}
let camDriftTimer = 0;
function checkCamDrift() {
  const tag = $('camTag');
  if (!tag) return;
  const dp = camera.position.distanceTo(camPos);
  const dt = orbit.target.distanceTo(camTgt);
  const dfov = Math.abs(camera.fov - camFov);
  const off = dp > 0.05 || dt > 0.05 || dfov > 0.1;
  if (off) {
    tag.textContent = '⚠ 当前不是游戏机位（所见比例不代表实机）';
    tag.style.display = '';
  } else {
    tag.style.display = 'none';
  }
}

function animate() {
  requestAnimationFrame(animate);
  orbit.update();
  if (++camDriftTimer % 20 === 0) checkCamDrift();
  renderer.render(scene, camera);
}

main().catch((e) => { status('启动失败：' + e.message, true); console.error(e); });
