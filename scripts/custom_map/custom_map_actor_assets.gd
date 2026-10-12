class_name CustomMapActorAssets
extends RefCounted
## Separate bounded existing-rig profile. City GLBs keep their static-only gate.
const MAX_ANIMATIONS:=16
const MAX_JOINTS:=64
static func fail(text:String)->Dictionary:return CustomMapLocalAssets.fail(text)
static func inspect_bytes(bytes:PackedByteArray,metadata_only:=false)->Dictionary:
 if bytes.size()<28 or bytes.size()>CustomMapLocalAssets.LIMIT:return fail("棋子 GLB 体积不合法")
 if bytes.decode_u32(0)!=0x46546c67 or bytes.decode_u32(4)!=2 or bytes.decode_u32(8)!=bytes.size():return fail("不是完整 GLB2")
 var length:=int(bytes.decode_u32(12))
 if length<2 or bytes.decode_u32(16)!=0x4e4f534a or 28+length>bytes.size():return fail("GLB JSON 截断")
 var parsed:Variant=JSON.parse_string(bytes.slice(20,20+length).get_string_from_utf8())
 if not parsed is Dictionary:return fail("GLB JSON 损坏")
 var doc:Dictionary=parsed;var at:=20+length
 if bytes.decode_u32(at+4)!=0x004e4942 or at+8+bytes.decode_u32(at)!=bytes.size():return fail("GLB BIN 截断")
 var binary:=bytes.slice(at+8)
 if CustomMapLocalAssets._unsupported_extensions(doc):return fail("棋子包含不支持的扩展")
 if CustomMapLocalAssets._has_uri(doc):return fail("棋子必须自包含，禁止 URI 和脚本")
 for name in ["nodes","meshes","skins","animations","accessors","bufferViews","scenes"]:
  if not doc.get(name,[]) is Array:return fail("棋子数组字段不合法")
 var safe:=doc.duplicate(true);safe.erase("skins");safe.erase("animations")
 for node in safe.get("nodes",[]):
  if not node is Dictionary:return fail("棋子节点类型不合法")
  node.erase("skin")
 for mesh in safe.get("meshes",[]):
  if not mesh is Dictionary or not mesh.get("primitives") is Array:return fail("棋子网格不合法")
  for primitive in mesh.primitives:
   if not primitive is Dictionary or not primitive.get("attributes") is Dictionary:return fail("棋子顶点属性不合法")
   primitive.attributes.erase("JOINTS_0");primitive.attributes.erase("WEIGHTS_0")
 # Shared static gate validates geometry, materials, all scenes and instance budgets before
 # the original animated GLB is ever handed to Godot. This generated static copy is discarded.
 var meta:=CustomMapLocalAssets.inspect_bytes(_pack(safe,binary),"actor_base",true)
 if not meta.ok:return fail("棋子基础网格："+meta.message)
 var metadata_rig_error:=_rig_error(doc,binary,1000000.0,1000000.0)
 if metadata_rig_error!="":return fail(metadata_rig_error)
 if metadata_only:return {"ok":true,"id":CustomMapLocalAssets._hash(bytes)+".glb","kind":"actor_model","bytes":bytes,"high_resolution":meta.high_resolution,"decoded_texture_bytes":meta.decoded_texture_bytes}
 var checked:=CustomMapLocalAssets.inspect_bytes(_pack(safe,binary),"actor_base")
 if not checked.ok:return fail("棋子基础网格："+checked.message)
 var rig_error:=_rig_error(doc,binary,maxf(1.0,checked.bounds.size.length()*2.0),maxf(0.00001,checked.bounds.size.y*0.35))
 if rig_error!="":return fail(rig_error)
 var effective:=_effective_rest_bounds(doc,binary,checked.bounds)
 if not effective.ok:return fail(effective.message)
 checked.erase("scene") # Release discarded static PackedScene/textures before animated import.
 CustomMapLocalAssets.native_import_calls+=1
 var document:=GLTFDocument.new();var state:=GLTFState.new()
 if document.append_from_buffer(bytes,"",state)!=OK:return fail("棋子实际 GLB 解码失败")
 var scene:=document.generate_scene(state)
 if scene==null:return fail("棋子场景生成失败")
 var post:=_actual_error(scene)
 if post!="":scene.free();return fail(post)
 var clips:Array=[]
 for player:AnimationPlayer in animation_players(scene):
  player.stop()
  for name in player.get_animation_list():
   var animation:=player.get_animation(name)
   if name=="RESET":continue
   clips.append({"name":str(name),"duration":animation.length})
 var box:AABB=effective.bounds
 if box.size==Vector3.ZERO or not box.position.is_finite() or not box.size.is_finite() or maxf(box.size.x,box.size.z)<0.00001 or box.size.length()>10000:scene.free();return fail("棋子实际边界不合法")
 var packed:=PackedScene.new();CustomMapLocalAssets._owners(scene,scene);var err:=packed.pack(scene);scene.free()
 if err!=OK:return fail("棋子预览打包失败")
 return {"ok":true,"id":CustomMapLocalAssets._hash(bytes)+".glb","kind":"actor_model","bytes":bytes,"scene":packed,"bounds":box,"clips":clips,"skins":doc.get("skins",[]).size(),"nodes":doc.get("nodes",[]).size(),"meshes":doc.get("meshes",[]).size(),"high_resolution":meta.high_resolution,"decoded_texture_bytes":meta.decoded_texture_bytes}
static func _pack(doc:Dictionary,binary:PackedByteArray)->PackedByteArray:
 var json:=JSON.stringify(doc).to_utf8_buffer()
 while json.size()%4:json.append(32)
 var bin:=binary.duplicate()
 while bin.size()%4:bin.append(0)
 var out:=PackedByteArray();out.resize(20);out.encode_u32(0,0x46546c67);out.encode_u32(4,2);out.encode_u32(8,28+json.size()+bin.size());out.encode_u32(12,json.size());out.encode_u32(16,0x4e4f534a);out.append_array(json)
 var header:=PackedByteArray();header.resize(8);header.encode_u32(0,bin.size());header.encode_u32(4,0x004e4942);out.append_array(header);out.append_array(bin);return out
static func _values(doc:Dictionary,binary:PackedByteArray,id:Variant,shape:String)->Array:
 var out:Array=[]
 if not CustomMapLocalAssets._index(id,doc.accessors.size()):return out
 var ac:Dictionary=doc.accessors[int(id)]
 if ac.type!=shape or int(ac.componentType)!=5126:return out
 var count:=int(ac.count)
 if count>(64 if shape=="MAT4" else 18000):return []
 var components:int={"SCALAR":1,"VEC3":3,"VEC4":4,"MAT4":16}[shape];var view:Dictionary=doc.bufferViews[int(ac.bufferView)];var offset:=int(view.get("byteOffset",0))+int(ac.get("byteOffset",0));var stride:=int(view.get("byteStride",4*components))
 for i in count:
  var row:Array=[]
  for c in components:
   var value:=binary.decode_float(offset+i*stride+c*4)
   if not is_finite(value):return []
   row.append(value)
  out.append(row)
 return out
static func _rig_error(doc:Dictionary,binary:PackedByteArray,displacement_limit:float,root_vertical_limit:float)->String:
 var worlds:=_world_transforms(doc)
 var nodes:Array=doc.nodes;var accessors:Array=doc.accessors;var skins:Array=doc.get("skins",[]);var animations:Array=doc.get("animations",[])
 if skins.size()>4 or animations.size()>MAX_ANIMATIONS:return "最多4骨架绑定、16动画"
 var reachable:Dictionary={};var scene:Dictionary=doc.scenes[int(doc.get("scene",0))];var stack:Array=scene.get("nodes",[]).duplicate()
 while not stack.is_empty():
  var id:int=int(stack.pop_back());reachable[id]=true;stack.append_array(nodes[id].get("children",[]))
 var parents:Dictionary={};var all_joints:Dictionary={}
 for index in nodes.size():
  for child in nodes[index].get("children",[]):parents[int(child)]=index
 for skin in skins:
  if skin is Dictionary and skin.get("joints") is Array:
   for joint in skin.joints:
    if CustomMapLocalAssets._index(joint,nodes.size()):all_joints[int(joint)]=true
 var joints_total:=0
 for skin in skins:
  if not skin is Dictionary or not skin.get("joints") is Array or skin.joints.is_empty() or skin.joints.size()>MAX_JOINTS:return "骨架 joints 类型或数量不合法"
  var joints:Dictionary={}
  for id in skin.joints:
   if not CustomMapLocalAssets._index(id,nodes.size()) or not reachable.has(int(id)) or joints.has(int(id)):return "骨骼引用越界、不可达或重复"
   joints[int(id)]=true
  joints_total+=skin.joints.size()
  if joints_total>MAX_JOINTS:return "总骨骼引用超过64"
  if skin.has("skeleton") and (not CustomMapLocalAssets._index(skin.skeleton,nodes.size()) or not reachable.has(int(skin.skeleton))):return "骨架根引用不合法"
  if skin.has("inverseBindMatrices"):
   var values:=_values(doc,binary,skin.inverseBindMatrices,"MAT4")
   if values.size()!=skin.joints.size():return "inverseBindMatrices 类型或数量不合法"
   for row:Array in values:
    var basis:=Basis(Vector3(row[0],row[1],row[2]),Vector3(row[4],row[5],row[6]),Vector3(row[8],row[9],row[10]))
    if absf(float(row[3]))>0.00001 or absf(float(row[7]))>0.00001 or absf(float(row[11]))>0.00001 or absf(float(row[15])-1.0)>0.00001:return "骨架逆绑定矩阵必须为仿射矩阵"
    if absf(basis.determinant())<0.00000001:return "骨架逆绑定矩阵退化"
    for number in row:
     if absf(number)>100000:return "骨架逆绑定矩阵超限"
 var bound_meshes:Dictionary={}
 for node in nodes:
  if not node.has("skin"):continue
  if not node.has("mesh") or not CustomMapLocalAssets._index(node.skin,skins.size()):return "节点 skin 引用不合法"
  bound_meshes[int(node.mesh)]=true
  var joint_count:int=skins[int(node.skin)].joints.size()
  for primitive in doc.meshes[int(node.mesh)].primitives:
   var attr:Dictionary=primitive.attributes
   if not attr.has("JOINTS_0") or not attr.has("WEIGHTS_0") or not CustomMapLocalAssets._index(attr.JOINTS_0,accessors.size()):return "蒙皮缺少合法顶点骨骼与权重"
   var joints:Dictionary=accessors[int(attr.JOINTS_0)]
   if joints.type!="VEC4" or int(joints.componentType) not in [5121,5123] or int(joints.count)!=int(accessors[int(attr.POSITION)].count):return "顶点骨骼访问器不合法"
   if not CustomMapLocalAssets._index(attr.WEIGHTS_0,accessors.size()):return "权重访问器引用不合法"
   var weights:Dictionary=accessors[int(attr.WEIGHTS_0)]
   if weights.type!="VEC4" or int(weights.componentType)!=5126 or int(weights.count)!=int(joints.count):return "仅支持浮点四权重且数量匹配"
   var weight_view:Dictionary=doc.bufferViews[int(weights.bufferView)];var weight_offset:=int(weight_view.get("byteOffset",0))+int(weights.get("byteOffset",0));var weight_stride:=int(weight_view.get("byteStride",16))
   var view:Dictionary=doc.bufferViews[int(joints.bufferView)];var component:int=1 if int(joints.componentType)==5121 else 2;var stride:=int(view.get("byteStride",component*4));var offset:=int(view.get("byteOffset",0))+int(joints.get("byteOffset",0))
   for i in int(joints.count):
    var total:=0.0
    for c in 4:
     var at:=offset+i*stride+c*component;var joint:int=binary[at] if component==1 else binary.decode_u16(at)
     var weight:=binary.decode_float(weight_offset+i*weight_stride+c*4)
     if joint>=joint_count or not is_finite(weight) or weight<0 or weight>1:return "实际骨骼索引或权重越界"
     total+=weight
    if absf(total-1.0)>0.01:return "顶点权重之和不为1"
 for mesh_index in doc.meshes.size():
  for primitive in doc.meshes[mesh_index].primitives:
   if (primitive.attributes.has("JOINTS_0") or primitive.attributes.has("WEIGHTS_0")) and not bound_meshes.has(mesh_index):return "蒙皮属性没有合法骨架绑定"
 var profiles:=_weight_profiles(doc,binary) if not animations.is_empty() else {"ok":true,"groups":[]}
 if not profiles.ok:return profiles.message
 var keyframes_total:=0
 var channels_total:=0
 var animation_names:Dictionary={}
 for animation in animations:
  if not animation is Dictionary or not animation.get("channels") is Array or not animation.get("samplers") is Array or animation.channels.size()>192 or animation.samplers.size()>192:return "动画 channels/samplers 不合法"
  if not animation.get("name","") is String or str(animation.get("name","")).length()>80:return "动画名称不合法"
  var clip_name:String=str(animation.get("name",""))
  if clip_name!="" and animation_names.has(clip_name):return "动画名称重复"
  animation_names[clip_name]=true
  channels_total+=animation.channels.size()
  if channels_total>512:return "总动画通道超过512"
  var used_samplers:Dictionary={};var used_targets:Dictionary={}
  for sampler in animation.samplers:
   if not sampler is Dictionary or sampler.get("interpolation","LINEAR") not in ["LINEAR","STEP"] or not CustomMapLocalAssets._index(sampler.get("input"),accessors.size()) or not CustomMapLocalAssets._index(sampler.get("output"),accessors.size()):return "动画采样器字段不合法"
  var global_motion:=_global_translation_targets(doc,binary,animation,profiles.groups,parents)
  for channel in animation.channels:
   if not channel is Dictionary or not channel.get("target") is Dictionary or not CustomMapLocalAssets._index(channel.get("sampler"),animation.samplers.size()):return "动画通道引用不合法"
   used_samplers[int(channel.sampler)]=true
   var target:Dictionary=channel.target
   if not CustomMapLocalAssets._index(target.get("node"),nodes.size()) or not reachable.has(int(target.node)) or target.get("path") not in ["translation","rotation","scale"]:return "动画目标节点或属性不合法"
   var identity:=str(target.node)+":"+str(target.path)
   if used_targets.has(identity):return "动画目标通道重复"
   used_targets[identity]=true
   var sampler:Variant=animation.samplers[int(channel.sampler)]
   if not sampler is Dictionary or sampler.get("interpolation","LINEAR") not in ["LINEAR","STEP"]:return "仅支持已有 LINEAR/STEP 动画，不支持重定向或 morph"
   var times:=_values(doc,binary,sampler.get("input"),"SCALAR");var values:=_values(doc,binary,sampler.get("output"),"VEC4" if target.path=="rotation" else "VEC3")
   if times.is_empty() or times.size()>18000 or values.size()!=times.size():return "动画访问器类型或关键帧数量不合法"
   keyframes_total+=times.size()
   if keyframes_total>100000:return "总动画关键帧超过100000"
   var previous:=-1.0
   for i in times.size():
    var time:float=times[i][0]
    if time<0 or time<=previous or time>120:return "动画时间须递增且最长120秒"
    previous=time
    for number in values[i]:
     if absf(number)>10000:return "动画数值超限"
    if target.path=="rotation":
     var q:=Quaternion(values[i][0],values[i][1],values[i][2],values[i][3])
     if absf(q.length_squared()-1.0)>0.05:return "动画旋转四元数不合法"
    if target.path=="translation":
     var rest:Array=nodes[int(target.node)].get("translation",[0,0,0]);var delta:=Vector3(values[i][0]-rest[0],values[i][1]-rest[1],values[i][2]-rest[2])
     var parent_basis:Basis=(worlds[parents[int(target.node)]] as Transform3D).basis if parents.has(int(target.node)) else Basis.IDENTITY
     var world_delta:Vector3=parent_basis*delta
     if not all_joints.has(int(target.node)) or (global_motion.has(int(target.node)) and Vector2(world_delta.x,world_delta.z).length()>0.00001):return "不支持整体根位移；请使用原地骨骼动画"
     if global_motion.has(int(target.node)):
      if absf(world_delta.y)>root_vertical_limit or ((i==0 or i==times.size()-1) and world_delta.length()>0.00001):return "根骨仅支持有限往返垂直动作；请使用原地动画"
     if delta.length()>displacement_limit:return "动画位移超过模型范围；请使用原地动画"
    if target.path=="scale":
     for number in values[i]:
      if number<0.05 or number>4:return "动画缩放须为0.05–4"
  if used_samplers.size()!=animation.samplers.size():return "动画包含未使用采样器"
 return ""
static func animation_players(node:Node)->Array:
 var out:Array=[]
 if node is AnimationPlayer:out.append(node)
 for child in node.get_children():out.append_array(animation_players(child))
 return out
static func _actual_error(root:Node)->String:
 var stack:Array=[root];var count:=0;var bones:=0;var triangles:=0
 while not stack.is_empty():
  var node:Node=stack.pop_back();count+=1
  if count>134 or node.get_script()!=null or node.get_class() not in ["Node3D","MeshInstance3D","Skeleton3D","AnimationPlayer"]:return "实际角色场景节点类型或预算不合法"
  if node is Skeleton3D:
   bones+=node.get_bone_count()
   if bones>64:return "实际骨骼超过64"
  if node is MeshInstance3D:
   if node.mesh==null:return "实际网格缺失"
   for surface in node.mesh.get_surface_count():
    if node.mesh.surface_get_primitive_type(surface)!=Mesh.PRIMITIVE_TRIANGLES:return "实际角色不是三角形"
    var arrays:Array=node.mesh.surface_get_arrays(surface);var indices:PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array();triangles+=(indices.size() if not indices.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())/3
    if triangles>250000:return "实际角色三角形超过250000"
  if node is AnimationPlayer:
   if node.get_animation_list().size()>17:return "实际动画数量超限"
   for clip in node.get_animation_list():
    var animation:Animation=node.get_animation(clip)
    if animation.length>120 or animation.get_track_count()>384:return "实际动画时长或轨道超限"
    for track in animation.get_track_count():
     if animation.track_get_type(track) not in [Animation.TYPE_POSITION_3D,Animation.TYPE_ROTATION_3D,Animation.TYPE_SCALE_3D]:return "实际动画包含不支持的轨道"
  stack.append_array(node.get_children())
 return ""

# Compute actual weighted glTF rest positions before decoding. Raw mesh AABBs do
# not include skin inverse binds; using them would normalize a displaced rig.
static func _node_transform(node:Dictionary)->Transform3D:
 if node.has("matrix"):
  var m:Array=node.matrix
  return Transform3D(Basis(Vector3(m[0],m[1],m[2]),Vector3(m[4],m[5],m[6]),Vector3(m[8],m[9],m[10])),Vector3(m[12],m[13],m[14]))
 var t:Array=node.get("translation",[0,0,0]);var r:Array=node.get("rotation",[0,0,0,1]);var scale:Array=node.get("scale",[1,1,1])
 return Transform3D(Basis(Quaternion(r[0],r[1],r[2],r[3]))*Basis.from_scale(Vector3(scale[0],scale[1],scale[2])),Vector3(t[0],t[1],t[2]))
static func _world_transforms(doc:Dictionary)->Dictionary:
 var out:Dictionary={};var stack:Array=[]
 for root in doc.scenes[int(doc.get("scene",0))].get("nodes",[]):stack.append([int(root),Transform3D.IDENTITY])
 while not stack.is_empty():
  var item:Array=stack.pop_back();var id:int=item[0];var world:Transform3D=item[1]*_node_transform(doc.nodes[id]);out[id]=world
  for child in doc.nodes[id].get("children",[]):stack.append([int(child),world])
 return out
static func _accessor_row(doc:Dictionary,binary:PackedByteArray,id:int,index:int,width:int)->Array:
 var ac:Dictionary=doc.accessors[id];var view:Dictionary=doc.bufferViews[int(ac.bufferView)];var bytes:int={5121:1,5123:2,5126:4}[int(ac.componentType)];var at:int=int(view.get("byteOffset",0))+int(ac.get("byteOffset",0))+index*int(view.get("byteStride",width*bytes));var out:Array=[]
 for c in width:out.append(binary.decode_float(at+c*bytes) if bytes==4 else (binary.decode_u16(at+c*bytes) if bytes==2 else binary[at+c]))
 return out
static func _effective_rest_bounds(doc:Dictionary,binary:PackedByteArray,raw:AABB)->Dictionary:
 var worlds:=_world_transforms(doc);var first:=true;var box:=AABB();var budget:=0
 var margin:=maxf(raw.size.length()*2.0,0.001)
 var permitted:=raw.grow(margin)
 for id in worlds:
  var node:Dictionary=doc.nodes[int(id)]
  if not node.has("mesh"):continue
  var skin:Dictionary=doc.skins[int(node.skin)] if node.has("skin") else {}
  var binds:Array=_values(doc,binary,skin.inverseBindMatrices,"MAT4") if skin.has("inverseBindMatrices") else []
  var matrices:Array=[]
  for joint_index in skin.get("joints",[]).size():
   var inverse:=Transform3D.IDENTITY
   if not binds.is_empty():
    var m:Array=binds[joint_index];inverse=Transform3D(Basis(Vector3(m[0],m[1],m[2]),Vector3(m[4],m[5],m[6]),Vector3(m[8],m[9],m[10])),Vector3(m[12],m[13],m[14]))
   matrices.append(worlds[int(skin.joints[joint_index])]*inverse)
  for primitive in doc.meshes[int(node.mesh)].primitives:
   var attrs:Dictionary=primitive.attributes;var count:int=int(doc.accessors[int(attrs.POSITION)].count);budget+=count
   if budget>750000:return fail("蒙皮静姿顶点预算超限")
   for vertex in count:
    var row:=_accessor_row(doc,binary,int(attrs.POSITION),vertex,3);var position:=Vector3(row[0],row[1],row[2]);var actual:Vector3=worlds[id]*position
    if not skin.is_empty():
     var joints:=_accessor_row(doc,binary,int(attrs.JOINTS_0),vertex,4);var weights:=_accessor_row(doc,binary,int(attrs.WEIGHTS_0),vertex,4);actual=Vector3.ZERO
     for influence in 4:
      if float(weights[influence])==0:continue
      var influenced:Vector3=matrices[int(joints[influence])]*position
      var pivot:Vector3=(worlds[int(skin.joints[int(joints[influence])])] as Transform3D).origin
      if not influenced.is_finite() or not permitted.has_point(influenced) or not permitted.has_point(pivot):return fail("有效蒙皮单骨影响或骨骼支点超出范围")
      actual+=influenced*float(weights[influence])
    if not actual.is_finite() or not permitted.has_point(actual):return fail("有效蒙皮静姿超出模型范围；逆绑定或权重异常")
    if first:box=AABB(actual,Vector3.ZERO);first=false
    else:box=box.expand(actual)
 if first:return fail("棋子没有有效静姿顶点")
 return {"ok":true,"bounds":box}

# Conservative existing-animation subset. Determine displacement coverage using
# real positive vertex weights, including zero-weight/dummy ancestors. Combined
# translation targets covering every skinned vertex get the global-motion gate.
static func _weight_profiles(doc:Dictionary,binary:PackedByteArray)->Dictionary:
 var groups:Dictionary={};var scanned:=0
 for node_id in _world_transforms(doc):
  var node:Dictionary=doc.nodes[int(node_id)]
  if not node.has("skin"):continue
  var skin:Dictionary=doc.skins[int(node.skin)]
  for primitive in doc.meshes[int(node.mesh)].primitives:
   var attrs:Dictionary=primitive.attributes;var count:int=int(doc.accessors[int(attrs.POSITION)].count);scanned+=count
   if scanned>750000:return fail("实际蒙皮权重扫描预算超限")
   for vertex in count:
    var ids:=_accessor_row(doc,binary,int(attrs.JOINTS_0),vertex,4);var weights:=_accessor_row(doc,binary,int(attrs.WEIGHTS_0),vertex,4);var joints:Array=[]
    for i in 4:
     var joint:int=int(skin.joints[int(ids[i])])
     if float(weights[i])>0.0 and not joints.has(joint):joints.append(joint)
    joints.sort();var key:=str(joints)
    if not groups.has(key):groups[key]=joints
    if groups.size()>4096:return fail("原地动画MVP最多4096种实际权重影响组合")
 return {"ok":true,"groups":groups.values()}
static func _global_translation_targets(doc:Dictionary,binary:PackedByteArray,animation:Dictionary,groups:Array,parents:Dictionary)->Dictionary:
 var moving:Dictionary={}
 for channel in animation.channels:
  if not channel is Dictionary or not channel.get("target") is Dictionary or not CustomMapLocalAssets._index(channel.get("sampler"),animation.samplers.size()):continue
  var target:Dictionary=channel.target
  if target.get("path")!="translation" or not CustomMapLocalAssets._index(target.get("node"),doc.nodes.size()):continue
  var sampler:Dictionary=animation.samplers[int(channel.sampler)]
  var values:=_values(doc,binary,sampler.get("output"),"VEC3");var rest:Array=doc.nodes[int(target.node)].get("translation",[0,0,0])
  for value in values:
   if Vector3(value[0]-rest[0],value[1]-rest[1],value[2]-rest[2]).length()>0.00001:moving[int(target.node)]=true;break
 if groups.is_empty() or moving.is_empty():return {}
 for group:Array in groups:
  var affected:=false
  for joint in group:
   var id:int=int(joint)
   while true:
    if moving.has(id):affected=true;break
    if not parents.has(id):break
    id=int(parents[id])
   if affected:break
  if not affected:return {}
 return moving
