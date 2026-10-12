@tool
extends EditorScenePostImport
## 地图编辑器导入模型的后处理：凡是带顶点色的表面，把材质的
## vertex_color_use_as_albedo 打开，让顶点色真正当成颜色用。
##
## 为什么需要它（2026-09-22 实测，Godot 4.7.1）：Carlos 导入的 baghdad.glb
## 没有贴图、全靠 COLOR_0 顶点色上色。Godot 的 glTF 导入器只给其中两种材质
## 打开了这个开关，主体所用的第一种材质（surf 0，51k 顶点）是关的，
## 于是整座城的主体按 albedo=白 渲染 —— 就是他看到的「白模」。
##
## 只在导入时跑一次，结果写进 .godot/imported 的 .scn；不碰任何场景脚本。

func _post_import(scene: Node) -> Object:
	var fixed := _walk(scene)
	print("[post_import_vertex_color] %s: 打开顶点色的表面 %d 个" % [get_source_file(), fixed])
	return scene

func _walk(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				var fmt: int = mesh.surface_get_format(i)
				if (fmt & Mesh.ARRAY_FORMAT_COLOR) == 0:
					continue
				var mat := mesh.surface_get_material(i) as BaseMaterial3D
				if mat == null:
					continue
				if not mat.vertex_color_use_as_albedo:
					mat.vertex_color_use_as_albedo = true
					count += 1
	for child in node.get_children():
		count += _walk(child)
	return count
