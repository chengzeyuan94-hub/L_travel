extends RefCounted
## Panti-only treatment: same-rig animated outline, with the static pose fallback.
var settings:Dictionary
var material_records:Array=[]
var shell:MeshInstance3D
var body:MeshInstance3D
var runtime_skinning:=false

func configure(model:Node3D,outline_width_multiplier:float=1.0) -> void:
	material_records.clear()
	shell=model.find_child("PantiSeatedOutline",true,false) as MeshInstance3D
	body=model.find_child("PantiSeatedBody",true,false) as MeshInstance3D
	runtime_skinning=body!=null and body.skin!=null
	settings=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/character_style.json"))
	settings.outline["panti_width_multiplier"]=outline_width_multiplier
	settings.outline.grow_amount_model_u=float(settings.outline.grow_amount_model_u)*outline_width_multiplier
	for node in model.find_children("*","MeshInstance3D",true,false):
		if node==shell:continue
		for surface in node.mesh.get_surface_count():
			var material:=node.get_active_material(surface).duplicate() as StandardMaterial3D
			if material==null:
				push_error("Panti seated body requires its original StandardMaterial3D")
				continue
			material.diffuse_mode=BaseMaterial3D.DIFFUSE_TOON
			material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
			material.metallic=float(settings.material.metallic)
			material.roughness=float(settings.material.roughness)
			node.set_surface_override_material(surface,material)
			material_records.append({"diffuse_mode":material.diffuse_mode,"roughness":material.roughness,"metallic":material.metallic,"original_texture_preserved":material.albedo_texture!=null})
	if shell==null:
		assert(not runtime_skinning,"Animated Panti body must bring its matching outline in the same GLB")
		var outline_scene:Node3D=load("res://assets/traveler/panti/camp/character/sitting-outline.glb").instantiate()
		model.add_child(outline_scene)
		shell=outline_scene.find_children("*","MeshInstance3D",true,false)[0]
	if runtime_skinning:
		assert(shell.skin!=null,"Panti animated outline is missing skin")
		assert(body.get_node_or_null(body.skeleton)==shell.get_node_or_null(shell.skeleton),"Panti body and outline must use the same Skeleton3D")
	var outline:=StandardMaterial3D.new()
	outline.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	outline.cull_mode=BaseMaterial3D.CULL_FRONT
	outline.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	outline.metallic=0.0
	outline.albedo_color=Color(settings.outline.albedo[0],settings.outline.albedo[1],settings.outline.albedo[2])
	outline.grow=true;outline.grow_amount=float(settings.outline.grow_amount_model_u)
	shell.material_override=outline
	shell.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func evidence() -> Dictionary:
	return {"settings":settings,"materials":material_records,"shell_count":1,"baked_matching_seated_outline":not runtime_skinning,"glasses_outline_excluded":true,"runtime_skinning":runtime_skinning,"body_outline_share_skeleton":not runtime_skinning or body.get_node_or_null(body.skeleton)==shell.get_node_or_null(shell.skeleton),"scope":"Panti seated character only"}
