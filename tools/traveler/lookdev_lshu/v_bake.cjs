#!/usr/bin/env node
/* Verifier (v_) wrapper around bake/bake_recipes.cjs: bakes fresh recipes as baked/v_<ID>.json + _proc.glb
 * WITHOUT touching baked/index.json or any other file. Usage: node v_bake.cjs J315:day=v_J315 ... */
'use strict';
const fs = require('fs'), path = require('path');
const BAKED = path.join(__dirname, 'baked') + path.sep;
const orig = fs.writeFileSync;
fs.writeFileSync = function (p, ...rest) {
  const s = String(p);
  if (s.startsWith(BAKED)) {
    const base = s.slice(BAKED.length);
    if (base === 'index.json') { console.log('SKIP index.json'); return; }
    if (!base.startsWith('v_')) throw Error('v_bake refuses to write ' + s);
  } else {
    throw Error('v_bake refuses to write outside baked/: ' + s);
  }
  return orig.call(fs, p, ...rest);
};
for (const a of process.argv.slice(2)) if (!/=v_[A-Za-z0-9_]+$/.test(a)) throw Error('spec must end with =v_<ID>: ' + a);
require('./bake/bake_recipes.cjs');
