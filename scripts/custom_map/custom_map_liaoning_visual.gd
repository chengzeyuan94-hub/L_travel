class_name CustomMapLiaoningVisual
extends Node3D
## Trusted decoration for this accepted carrier. Source PBR material stays intact.
const ASSET := "623bbc695a56ff7d64b8760673c3f8caebb460a8f5cb3bb2516d9d96cdafcbd8.glb"
var moving := false
var elapsed := 0.0
static func decorate(model:Node3D)->void:
 var pole:=MeshInstance3D.new();pole.name="LiaoningFlagPole"
 var cylinder:=CylinderMesh.new();cylinder.top_radius=0.002;cylinder.bottom_radius=0.002;cylinder.height=0.105;cylinder.radial_segments=8
 pole.mesh=cylinder;pole.position=Vector3(-0.12,0.395,-0.08)
 var metal:=StandardMaterial3D.new();metal.albedo_color=Color("bfc4c8");metal.metallic=0.6;metal.roughness=0.5;pole.material_override=metal;model.add_child(pole)
 var flag:=MeshInstance3D.new();flag.name="LiaoningPlayerFlag"
 var cloth:=BoxMesh.new();cloth.size=Vector3(0.003,0.040,0.080);flag.mesh=cloth;flag.position=Vector3(-0.12,0.423,-0.039)
 var material:=StandardMaterial3D.new();material.resource_name="liaoning_player_flag_instance";material.albedo_color=Color8(205,72,58);material.roughness=1.0
 flag.material_override=material;model.add_child(flag)
static func apply_color(root:Node,color:Color)->Dictionary:
 var flag:=root.find_child("LiaoningPlayerFlag",true,false) as MeshInstance3D
 if flag==null:return {"ok":false,"message":"辽宁号玩家小旗缺失"}
 # One material per instance; only the small added flag receives player color.
 var material:=flag.material_override as StandardMaterial3D
 if material==null:return {"ok":false,"message":"辽宁号玩家小旗材质缺失"}
 material.albedo_color=color
 return {"ok":true,"materials":[material]}
static func attach_preview(root:Node3D,normalizer:Node3D)->void:
 var floating:=CustomMapLiaoningVisual.new();floating.name="LiaoningPreviewFloat"
 root.remove_child(normalizer);root.add_child(floating);floating.add_child(normalizer)
static func preview_motion(root:Node,motion:bool)->void:
 var floating:=root.find_child("LiaoningPreviewFloat",true,false) as CustomMapLiaoningVisual
 if floating!=null:floating.moving=motion
func _process(delta:float)->void:
 elapsed+=delta
 position.y=sin(elapsed*2.0)*0.020
 rotation=Vector3(sin(elapsed*1.3)*(0.040 if moving else 0.020),0,sin(elapsed*1.7)*(0.030 if moving else 0.015))
