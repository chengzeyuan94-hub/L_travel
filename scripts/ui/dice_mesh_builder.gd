class_name DiceMeshBuilder
extends RefCounted

## 骰子 v2（L叔玩具骰）的模型与 atlas 工具。
## 模型：Blender 建模导出的 GLB（tools/ui_icons/assets/dice.py → export_dice_game.py），
## 一个网格、三个表面（粘土 / 釉面 / 微光），顶点色即颜色，不用贴图。
## atlas：同一模型六个面的正交渲染（3×2，每格正好框住整面），供 2D 兜底与 headless 表现签名。

const MODEL_PATH := "res://assets/game/dice/dice_lshu_v2.glb"

## 局部法线：1↔EVENT，2↔5，3↔4（Blender 导出时 +Z→+Y，与 Dice3DView.FACE_NORMALS 一致）
const FACE_NORMALS := {
	1: Vector3(0, 1, 0),
	"EVENT": Vector3(0, -1, 0),
	2: Vector3(0, 0, 1),
	5: Vector3(0, 0, -1),
	3: Vector3(1, 0, 0),
	4: Vector3(-1, 0, 0),
}

const ATLAS_CELLS := {
	1: Vector2(0, 0),
	2: Vector2(1, 0),
	3: Vector2(2, 0),
	4: Vector2(0, 1),
	5: Vector2(1, 1),
	"EVENT": Vector2(2, 1),
}

const CELL_SIZE := Vector2(1.0 / 3.0, 0.5)
const UV_INSET := 0.02

## 表面角色：按 GLB 里的材质名（lp_dice_clay / lp_dice_gloss / lp_dice_glow）
const ROLE_CLAY := "clay"
const ROLE_GLOSS := "gloss"
const ROLE_GLOW := "glow"


## 读取 GLB 里的骰子网格；缺文件或未导入时返回 null（调用方走 2D 兜底）。
static func load_model_mesh(path: String = MODEL_PATH) -> Mesh:
	if not ResourceLoader.exists(path):
		return null
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var root := scene.instantiate()
	var mesh: Mesh = null
	if root is MeshInstance3D:
		mesh = (root as MeshInstance3D).mesh
	else:
		for node in root.find_children("*", "MeshInstance3D", true, false):
			mesh = (node as MeshInstance3D).mesh
			break
	root.free()
	return mesh


static func triangle_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for i in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(i)
		var indices = arrays[Mesh.ARRAY_INDEX]
		if indices != null and indices.size() > 0:
			total += int(indices.size() / 3)
		else:
			var verts = arrays[Mesh.ARRAY_VERTEX]
			if verts != null:
				total += int(verts.size() / 3)
	return total


static func surface_role(mesh: Mesh, surface: int) -> String:
	var mat := mesh.surface_get_material(surface) if mesh != null else null
	var name := mat.resource_name.to_lower() if mat != null else ""
	if name.contains("gloss"):
		return ROLE_GLOSS
	if name.contains("glow"):
		return ROLE_GLOW
	return ROLE_CLAY


static func has_vertex_colors(mesh: Mesh) -> bool:
	if mesh == null or mesh.get_surface_count() == 0:
		return false
	for i in mesh.get_surface_count():
		var cols = mesh.surface_get_arrays(i)[Mesh.ARRAY_COLOR]
		if cols == null or cols.size() == 0:
			return false
	return true


static func atlas_uv(face: Variant, local_uv: Vector2) -> Vector2:
	var cell: Vector2 = ATLAS_CELLS[face]
	var cell_origin := Vector2(cell.x * CELL_SIZE.x, cell.y * CELL_SIZE.y)
	var uv_in_cell := Vector2(
		lerpf(UV_INSET, 1.0 - UV_INSET, local_uv.x),
		lerpf(UV_INSET, 1.0 - UV_INSET, local_uv.y)
	)
	return cell_origin + uv_in_cell * CELL_SIZE


## CPU 采样 atlas 宫格（headless 可验证点数 / 徽章，无需 GPU 读回）。
static func sample_atlas_cell(atlas_img: Image, face: Variant, local_uv: Vector2 = Vector2(0.5, 0.5)) -> Color:
	if atlas_img == null:
		return Color(0, 0, 0, 0)
	var uv := atlas_uv(face, local_uv)
	var x := clampi(int(uv.x * float(atlas_img.get_width())), 0, atlas_img.get_width() - 1)
	var y := clampi(int(uv.y * float(atlas_img.get_height())), 0, atlas_img.get_height() - 1)
	return atlas_img.get_pixel(x, y)


static func atlas_cell_signature(atlas_img: Image, face: Variant, grid: int = 8) -> String:
	if atlas_img == null:
		return "null"
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for j in grid:
		for i in grid:
			var lu := Vector2((float(i) + 0.5) / float(grid), (float(j) + 0.5) / float(grid))
			var c := sample_atlas_cell(atlas_img, face, lu)
			ctx.update(PackedByteArray([
				int(clampf(c.r, 0.0, 1.0) * 255.0),
				int(clampf(c.g, 0.0, 1.0) * 255.0),
				int(clampf(c.b, 0.0, 1.0) * 255.0),
			]))
	return ctx.finish().hex_encode()


## 巧克力釉点 / 眼镜：很暗的暖褐色（#3A2A22 受光后约在 0.10–0.30 亮度）。
static func is_pip_ink(c: Color) -> bool:
	var lum := c.r * 0.3 + c.g * 0.59 + c.b * 0.11
	return c.a > 0.5 and lum < 0.30 and c.r >= c.b - 0.02


## 事件徽章的橄榄绿环（#8A8B5A，也会算进嫩芽绿叶子）。背光的奶油色倒角 R 明显高于 G，不会误判。
static func is_olive(c: Color) -> bool:
	var lum := c.r * 0.3 + c.g * 0.59 + c.b * 0.11
	var gb := c.g - c.b
	return c.a > 0.5 and gb > 0.12 and gb / maxf(c.g, 0.01) > 0.25 and c.r - c.g < 0.035 and lum > 0.2 and lum < 0.68


static func atlas_cell_color_stats(atlas_img: Image, face: Variant, grid: int = 32) -> Dictionary:
	var ink_n := 0
	var olive_n := 0
	var total := 0
	var center := sample_atlas_cell(atlas_img, face, Vector2(0.5, 0.5))
	for j in grid:
		for i in grid:
			var lu := Vector2((float(i) + 0.5) / float(grid), (float(j) + 0.5) / float(grid))
			var c := sample_atlas_cell(atlas_img, face, lu)
			total += 1
			if is_pip_ink(c):
				ink_n += 1
			elif is_olive(c):
				olive_n += 1
	return {
		"ink_n": ink_n,
		"olive_n": olive_n,
		"total": total,
		"ink_ratio": float(ink_n) / float(maxi(total, 1)),
		"olive_ratio": float(olive_n) / float(maxi(total, 1)),
		"center": center,
		"center_ink": is_pip_ink(center),
	}
