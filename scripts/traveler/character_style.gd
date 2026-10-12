extends RefCounted
## Character-only appearance. Original model, texture, skin and animations stay intact.
var settings:Dictionary
var surfaces:Array[Dictionary]=[]
var shells:Array[MeshInstance3D]=[]
var enabled:=true

func configure(model:Node3D) -> void:
	settings=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/character_style.json"))
	var sources:=model.find_children("*","MeshInstance3D",true,false)
	for node in sources:
		var source:=node as MeshInstance3D
		if source.mesh==null:continue
		for surface in source.mesh.get_surface_count():
			var original:=source.get_active_material(surface) as StandardMaterial3D
			if original==null:
				push_error("Character style requires the existing StandardMaterial3D")
				continue
			var material:=original.duplicate() as StandardMaterial3D
			material.diffuse_mode=BaseMaterial3D.DIFFUSE_TOON
			material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
			material.metallic=float(settings.material.metallic)
			material.roughness=float(settings.material.roughness)
			surfaces.append({"source":source,"surface":surface,"original":source.get_surface_override_material(surface),"styled":material,"texture":original.albedo_texture})
			source.set_surface_override_material(surface,material)
		var outline:=StandardMaterial3D.new()
		outline.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
		outline.cull_mode=BaseMaterial3D.CULL_FRONT
		outline.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
		outline.metallic=0.0
		outline.albedo_color=Color(settings.outline.albedo[0],settings.outline.albedo[1],settings.outline.albedo[2])
		outline.grow=true
		outline.grow_amount=float(settings.outline.grow_amount_model_u)
		var shell:=MeshInstance3D.new()
		shell.name="CharacterOutline_"+String(source.name)
		# This copy keeps source vertices/weights; only the glasses' outline indices are omitted.
		shell.mesh=load(str(settings.outline.mesh_resource)) as Mesh
		shell.skeleton=source.skeleton
		shell.skin=source.skin
		shell.layers=source.layers
		shell.material_override=outline
		shell.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Keep the same parent so the copied relative skeleton path resolves identically.
		source.get_parent().add_child(shell)
		shell.transform=source.transform
		shells.append(shell)

func set_enabled(value:bool) -> void:
	# Used by same-process before/after evidence; production starts enabled.
	enabled=value
	for surface in surfaces:
		surface.source.set_surface_override_material(surface.surface,surface.styled if value else surface.original)
	for shell in shells:shell.visible=value

func evidence() -> Dictionary:
	var textures_preserved:=true
	var skinned_shells:=true
	var materials:Array=[]
	for surface in surfaces:
		var material:StandardMaterial3D=surface.source.get_active_material(surface.surface)
		textures_preserved=textures_preserved and material.albedo_texture==surface.texture
		materials.append({"class":material.get_class(),"diffuse_mode":material.diffuse_mode,"specular_mode":material.specular_mode,"metallic":material.metallic,"roughness":material.roughness,"albedo_texture":surface.texture.resource_path if surface.texture!=null else ""})
	for shell in shells:
		skinned_shells=skinned_shells and shell.skin!=null and shell.get_node_or_null(shell.skeleton) is Skeleton3D
	return {"enabled":enabled,"settings":settings,"materials":materials,"textures_preserved":textures_preserved,"shell_count":shells.size(),"shells_resolve_skeleton":skinned_shells,"scope":"current character only"}
