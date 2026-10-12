extends SceneTree
## 生成「L叔地图工坊」的应用图标（DESIGN 5.1 WP4：游戏图标加现成的 icon_pencil.png 角标，不新建模）：
## 游戏图标 1024 → 右下角一枚奶油色圆牌（挎包棕描边）→ 圆牌上放铅笔图标。输出 scenes/map_workshop/map_workshop_icon_1024.png。
## 运行：Godot --headless --path . -s res://scripts/map_workshop/build_workshop_icon.gd

const APP_ICON := "res://assets/game/app/app_icon_1024.png"
const PENCIL := "res://assets/game/ui/lshu_setup/icon_pencil.png"
const OUT := "res://scenes/map_workshop/map_workshop_icon_1024.png"
const CREAM := Color("#FBF3E4")
const SATCHEL := Color("#8A5A3B")


func _init() -> void:
	var base := Image.load_from_file(ProjectSettings.globalize_path(APP_ICON))
	var pencil := Image.load_from_file(ProjectSettings.globalize_path(PENCIL))
	if base == null or pencil == null:
		push_error("找不到游戏图标或铅笔图标")
		quit(1)
		return
	base.convert(Image.FORMAT_RGBA8)
	pencil.convert(Image.FORMAT_RGBA8)
	var n := base.get_width()
	var r := n * 0.21                          # 角标半径
	var c := Vector2(n - r - n * 0.035, n - r - n * 0.035)
	var edge := n * 0.018
	for y in range(int(c.y - r - 2), mini(n, int(c.y + r + 2))):
		for x in range(int(c.x - r - 2), mini(n, int(c.x + r + 2))):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			if d > r + 1.0:
				continue
			var a := clampf(r + 0.5 - d, 0.0, 1.0)
			var col := SATCHEL if d > r - edge else CREAM
			var under := base.get_pixel(x, y)
			base.set_pixel(x, y, under.blend(Color(col.r, col.g, col.b, a)))
	var side := int(r * 1.35)
	pencil.resize(side, side, Image.INTERPOLATE_LANCZOS)
	base.blend_rect(pencil, Rect2i(0, 0, side, side), Vector2i(int(c.x - side * 0.5), int(c.y - side * 0.5)))
	var err := base.save_png(ProjectSettings.globalize_path(OUT))
	print("WORKSHOP_ICON ", OUT, " err=", err)
	quit(0 if err == OK else 1)
