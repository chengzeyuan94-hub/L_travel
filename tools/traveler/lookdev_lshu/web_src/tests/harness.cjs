const fs=require('fs'),vm=require('vm'),path=require('path');const ROOT=path.resolve(__dirname,'../..');
const ctx={console,performance,TextDecoder,TextEncoder,Uint8Array,Uint32Array,Float32Array,DataView,ArrayBuffer,Blob,URL,setTimeout,clearTimeout,crypto:require('crypto').webcrypto,localStorage:{getItem:()=>null,setItem:()=>{}},fetch:async function(u){const p=path.join(ROOT,String(u).replace(/^\//,''));const b=fs.readFileSync(p);return {ok:true,json:async()=>JSON.parse(b),text:async()=>b.toString(),arrayBuffer:async()=>b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength)};}};
vm.createContext(ctx);
const scripts=['src/geometry.js','src/composer.js','src/asset-loader.js','src/world.js','studio/layout.js','journey/catalog.js','journey/planner.js','journey/city-runtime.js','journey/assemble.js','studio/world.js'];
for(const f of scripts)vm.runInContext(fs.readFileSync(path.join(ROOT,f),'utf8'),ctx,{filename:f});
vm.runInContext('setCatalog('+fs.readFileSync(ROOT+'/assets/manifest.json','utf8')+');',ctx);
module.exports={ctx,run:s=>vm.runInContext(s,ctx),ROOT};
