class_name CustomMapDefaultTeamMaterials
extends RefCounted
const SHADER:=preload("res://shaders/merchant_board_claude/default_team_cloth.gdshader")
const CAMEL_ASSET:="f5bed14fee8b13d4dbdb92da18a5aef812de52362bc9a377c2a808d571626b1a.glb"
const OLD_CAMEL_ASSET:="67ad4054a876ca46b0885221ef33348ef096b315d0a468d3c90ecae2a1f829c6.glb"
const BOAT_ASSET:="1a2c4eb310d0a1a0d51aa017269d7e151f34917e618a252bf7bee096db8de876.glb"
const REGIONS:={"camel_blanket_team_region":1,"boat_markers_team_region":1}
static func supports(asset:String)->bool:return asset in [CAMEL_ASSET,OLD_CAMEL_ASSET,BOAT_ASSET,CustomMapLiaoningVisual.ASSET]
static func apply(root:Node,asset:String,color:Color)->Dictionary:
 if asset==CustomMapLiaoningVisual.ASSET:return CustomMapLiaoningVisual.apply_color(root,color)
 if not supports(asset):return {"ok":false,"message":"模型未注册局部配色"}
 var materials:Array=[];var stack:Array=[root]
 while not stack.is_empty():
  var node:Node=stack.pop_back();stack.append_array(node.get_children())
  if not node is MeshInstance3D:continue
  var mesh:Mesh=node.mesh
  for surface in mesh.get_surface_count():
   var original:=mesh.surface_get_material(surface)
   if not original is StandardMaterial3D or not REGIONS.has(original.resource_name):continue
   if original.albedo_texture==null or original.normal_texture==null or original.roughness_texture==null:return {"ok":false,"message":"原PBR三图缺失"}
   var material:=ShaderMaterial.new();material.shader=SHADER
   material.resource_name=original.resource_name+"_player_instance"
   material.set_shader_parameter("base_tex",original.albedo_texture)
   material.set_shader_parameter("rm_tex",original.roughness_texture)
   material.set_shader_parameter("normal_tex",original.normal_texture)
   material.set_shader_parameter("normal_scale",original.normal_scale)
   material.set_shader_parameter("metallic_factor",original.metallic)
   material.set_shader_parameter("roughness_factor",original.roughness)
   material.set_shader_parameter("team_color",color)
   node.set_surface_override_material(surface,material);materials.append(material)
 return {"ok":materials.size()==1,"materials":materials}
