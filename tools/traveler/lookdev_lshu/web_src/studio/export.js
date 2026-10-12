/* Uncompressed glTF 2.0 binary exporter for the static snapshot; no external dependencies. */
const StudioExport=(()=>{
 const linear=x=>x<=.04045?x/12.92:Math.pow((x+.055)/1.055,2.4);
 function glb(){Camp.update();const nodes=[],meshes=[],materials=[],bufferViews=[],accessors=[],chunks=[];let offset=0;
  function attr(arr,type){let data=new Float32Array(arr);const bytes=new Uint8Array(data.buffer);bufferViews.push({buffer:0,byteOffset:offset,byteLength:bytes.length,target:34962});chunks.push(bytes);offset+=bytes.length;const width=3,a={bufferView:bufferViews.length-1,componentType:5126,count:arr.length/width,type};if(type==='VEC3'){a.min=[0,1,2].map(k=>{let v=Infinity;for(let i=k;i<arr.length;i+=3)v=Math.min(v,arr[i]);return v;});a.max=[0,1,2].map(k=>{let v=-Infinity;for(let i=k;i<arr.length;i+=3)v=Math.max(v,arr[i]);return v;});}accessors.push(a);return accessors.length-1;}
  for(const n of Camp.world){if(n.isFloor||n.isContact||n.mat.opacity<.01||!n.g||n.g.p.length===0)continue;let m=n.mat;let material={name:n.name||'Surface',pbrMetallicRoughness:{baseColorFactor:[...m.color.map(linear),m.opacity],metallicFactor:0,roughnessFactor:m.roughness??.86},doubleSided:!!n.doubleSide};if(m.opacity<.99)material.alphaMode='BLEND';if(m.emission)material.emissiveFactor=m.color.map(v=>Math.min(1,linear(v)*m.emission));materials.push(material);
   meshes.push({name:n.name||'Mesh',primitives:[{attributes:{POSITION:attr(n.g.p,'VEC3'),NORMAL:attr(n.g.n,'VEC3'),COLOR_0:attr(n.g.c.map(linear),'VEC3')},material:materials.length-1,mode:4}]});nodes.push({name:n.name||'ScenePart',mesh:meshes.length-1,matrix:Array.from(n.world)});
  }
  const doc={asset:{version:'2.0',generator:'Lshu Travel Studio 4.1 - static snapshot'},scene:0,scenes:[{name:'TravelTile',nodes:nodes.map((_,i)=>i)}],nodes,meshes,materials,accessors,bufferViews,buffers:[{byteLength:offset}],extras:{recipe:StudioWorld.last.recipe,note:'Static model; no lights, camera, animation, or stage shadow floor.'}};
  let json=new TextEncoder().encode(JSON.stringify(doc));const jp=(json.length+3)&~3,bp=(offset+3)&~3,total=12+8+jp+8+bp,output=new ArrayBuffer(total),v=new DataView(output),u=new Uint8Array(output);v.setUint32(0,0x46546c67,true);v.setUint32(4,2,true);v.setUint32(8,total,true);v.setUint32(12,jp,true);v.setUint32(16,0x4e4f534a,true);u.fill(32,20,20+jp);u.set(json,20);v.setUint32(20+jp,bp,true);v.setUint32(24+jp,0x004e4942,true);let o=28+jp;for(const c of chunks){u.set(c,o);o+=c.length;}return new Blob([output],{type:'model/gltf-binary'});
 }
 return {glb};
})();
