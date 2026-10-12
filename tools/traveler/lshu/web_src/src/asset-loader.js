/* Minimal reader for THIS PACK's validated uncompressed glTF 2.0 GLBs.
   Not a general replacement for GLTFLoader. External user GLBs use GLTFLoader. */
const AssetLoader=(()=>{
 const cache=new Map(),srgb=x=>x<=.0031308?x*12.92:1.055*Math.pow(x,1/2.4)-.055;
 function parse(buffer){const v=new DataView(buffer);if(v.getUint32(0,true)!==0x46546c67||v.getUint32(4,true)!==2||v.getUint32(8,true)!==buffer.byteLength)throw Error('无效 GLB');let j,bin;
  for(let offset=12;offset<buffer.byteLength;){const size=v.getUint32(offset,true),type=v.getUint32(offset+4,true);offset+=8;if(offset+size>buffer.byteLength)throw Error('GLB chunk 超界');if(type===0x4e4f534a)j=JSON.parse(new TextDecoder().decode(new Uint8Array(buffer,offset,size)));if(type===0x004e4942)bin=offset;offset+=size;}
  if(!j||bin===undefined)throw Error('GLB 缺少数据');let prim=j.meshes[0].primitives[0];
  function read(name){let a=j.accessors[prim.attributes[name]],b=j.bufferViews[a.bufferView];if(a.componentType!==5126||a.type!=='VEC3'||b.byteStride)throw Error('不是本素材包的顶点格式');return Array.from(new Float32Array(buffer,bin+(b.byteOffset||0)+(a.byteOffset||0),a.count*3));}
  return {p:read('POSITION'),n:read('NORMAL'),c:read('COLOR_0').map(srgb)};
 }
 async function load(id){if(cache.has(id))return cache.get(id);const promise=(async()=>{const a=ASSETS[id];if(!a)throw Error('未知素材 '+id);let r=await fetch(a.file);if(!r.ok)throw Error('缺少模型 '+id);return parse(await r.arrayBuffer());})();cache.set(id,promise);try{return await promise;}catch(e){cache.delete(id);throw e;}}
 return {load,parse,cache};
})();
