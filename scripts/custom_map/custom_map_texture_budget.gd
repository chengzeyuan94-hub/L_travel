class_name CustomMapTextureBudget
extends RefCounted
const ACTOR_SIDE:=4096
const ACTOR_PIXELS:=50331648
const ACTOR_IMAGES:=3
const ACTOR_MATERIALS:=8
const MAP_ACTORS:=2
const MAP_BYTES:=384*1024*1024
static var _crc_table:PackedInt64Array=PackedInt64Array()
static func bad(message:String)->Dictionary:return {"ok":false,"message":message}
static func be32(b:PackedByteArray,at:int)->int:return int(b[at])*16777216+int(b[at+1])*65536+int(b[at+2])*256+int(b[at+3])
static func crc(b:PackedByteArray,begin:int,end:int)->int:
 if _crc_table.is_empty():
  for i in 256:
   var c:=i
   for j in 8:c=(c>>1)^0xedb88320 if c&1 else c>>1
   _crc_table.append(c)
 var value:=0xffffffff
 for at in range(begin,end):value=_crc_table[(value^b[at])&255]^(value>>8)
 return value^0xffffffff
static func image_header(b:PackedByteArray,side:int)->Dictionary:
 if b.size()<24 or b.size()>8*1024*1024:return bad("图片体积不合要求")
 var w:=0;var h:=0;var depth:=0;var ext:=""
 if b.slice(0,8)==PackedByteArray([137,80,78,71,13,10,26,10]):
  var at:=8;var count:=0;var ended:=false;var idat:=false
  while at+12<=b.size():
   var n:=be32(b,at)
   if n<0 or n>b.size()-at-12 or count>128:return bad("PNG 区块截断或超限")
   var name:=b.slice(at+4,at+8).get_string_from_ascii()
   if crc(b,at+4,at+8+n)!=be32(b,at+8+n):return bad("PNG 区块 CRC 损坏")
   if count==0:
    if name!="IHDR" or n!=13:return bad("PNG 头损坏")
    w=be32(b,at+8);h=be32(b,at+12);depth=int(b[at+16])
    var color:=int(b[at+17]);var valid_depths:Dictionary={0:[1,2,4,8,16],2:[8,16],3:[1,2,4,8],4:[8,16],6:[8,16]}
    if not valid_depths.has(color) or depth not in valid_depths.get(color,[]):return bad("PNG 颜色类型与位深组合不合法")
    if b[at+18]!=0 or b[at+19]!=0 or b[at+20] not in [0,1]:return bad("PNG 压缩、过滤或交错字段不合法")
   elif name=="IHDR":return bad("PNG 重复头")
   if name=="IDAT":idat=true
   if name=="IEND":
    if n!=0 or at+12!=b.size():return bad("PNG 结束结构损坏")
    ended=true;break
   at+=n+12;count+=1
  if not ended or not idat:return bad("PNG 截断或无数据")
  ext="png"
 elif b[0]==255 and b[1]==216:
  if b[b.size()-2]!=255 or b[b.size()-1]!=217:return bad("JPEG 截断")
  var at:=2;var found:=false;var scan:=false
  while at+4<=b.size():
   if b[at]!=255:return bad("JPEG 结构损坏")
   var marker:=int(b[at+1]);at+=2
   if marker==255:at-=1;continue
   if marker in [216,217] or marker in range(208,216):continue
   var n:=int(b[at])*256+int(b[at+1])
   if n<2 or n>b.size()-at:return bad("JPEG 区块截断")
   if marker in [192,193,194]:
    if n<8 or found:return bad("JPEG 尺寸头损坏")
    depth=int(b[at+2]);h=int(b[at+3])*256+int(b[at+4]);w=int(b[at+5])*256+int(b[at+6]);found=true
   if marker==218:
    if n<6 or at+n>=b.size()-2:return bad("JPEG 扫描段损坏")
    scan=true;break
   at+=n
  if not found or not scan:return bad("JPEG 无尺寸或扫描段")
  ext="jpg"
 else:return bad("不是实际 PNG/JPEG 图片")
 if w<1 or h<1 or w>side or h>side:return bad("图片边长超出 %d 像素限制"%side)
 return {"ok":true,"width":w,"height":h,"depth":depth,"ext":ext,"pixels":w*h}
static func glb_plan(bytes:PackedByteArray,actor:bool)->Dictionary:
 if bytes.size()<28 or bytes.size()>16*1024*1024:return bad("GLB 体积不合法")
 if bytes.decode_u32(0)!=0x46546c67 or bytes.decode_u32(4)!=2 or bytes.decode_u32(8)!=bytes.size():return bad("不是完整 GLB2")
 var n:=int(bytes.decode_u32(12))
 if n<2 or bytes.decode_u32(16)!=0x4e4f534a or n>bytes.size()-28:return bad("GLB JSON 截断")
 var parsed:Variant=JSON.parse_string(bytes.slice(20,20+n).get_string_from_utf8())
 if not parsed is Dictionary:return bad("GLB JSON 损坏")
 var d:Dictionary=parsed;var at:=20+n
 if bytes.decode_u32(at+4)!=0x004e4942 or at+8+bytes.decode_u32(at)!=bytes.size():return bad("GLB BIN 截断")
 var binary:=bytes.slice(at+8)
 for key in ["images","textures","samplers","materials","bufferViews","extensionsUsed","extensionsRequired"]:
  if not d.get(key,[]) is Array:return bad("GLB 预检数组损坏")
 for name in d.get("extensionsRequired",[]):
  if not name is String or name not in ["KHR_materials_emissive_strength","KHR_materials_unlit"] or name not in d.get("extensionsUsed",[]):return bad("GLB 必需扩展不支持")
 var plans:Array=[];var pixels:=0;var high:=false
 for image in d.get("images",[]):
  if not image is Dictionary or image.has("uri") or not _index(image.get("bufferView"),d.get("bufferViews",[]).size()):return bad("图片必须引用嵌入 BIN")
  var view:Variant=d.bufferViews[int(image.bufferView)]
  if not view is Dictionary or not _integer(view.get("byteOffset",0)) or not _integer(view.get("byteLength")) or int(view.get("byteOffset",0))<0 or int(view.byteLength)<0 or int(view.get("byteOffset",0))+int(view.byteLength)>binary.size():return bad("图片缓冲越界")
  var off:=int(view.get("byteOffset",0));var header:=image_header(binary.slice(off,off+int(view.byteLength)),ACTOR_SIDE if actor else 2048)
  if not header.ok:return header
  if image.get("mimeType")!=("image/png" if header.ext=="png" else "image/jpeg"):return bad("图片 MIME 与实际格式不符")
  pixels+=int(header.pixels);high=high or int(header.width)>2048 or int(header.height)>2048;plans.append(header)
 if high:
  if not actor or plans.size()>ACTOR_IMAGES or d.get("materials",[]).size()>ACTOR_MATERIALS or pixels>ACTOR_PIXELS:return bad("高分棋子须最多3图、8材质、192 MiB基础像素")
  for plan in plans:
   if int(plan.depth)!=8:return bad("高分棋子纹理仅支持8bit")
  var sources:Dictionary={}
  for texture in d.get("textures",[]):
   if not texture is Dictionary or not _index(texture.get("source"),plans.size()):return bad("纹理源引用越界")
   if sources.has(int(texture.source)):return bad("高分棋子禁止 texture/sampler 源别名")
   sources[int(texture.source)]=true
 else:
  if pixels*4>64*1024*1024:return bad("GLB 解码纹理总量超过64 MiB")
 return {"ok":true,"high_resolution":high,"decoded_texture_bytes":pixels*4,"images":plans,"doc":d,"binary":binary}
static func _integer(v:Variant)->bool:return (v is int or v is float) and is_finite(float(v)) and float(v)==floor(float(v))
static func _index(v:Variant,size:int)->bool:return _integer(v) and int(v)>=0 and int(v)<size
