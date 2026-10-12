extends RefCounted
## 渲染器全局的几项画质设置（方向光阴影图集、软阴影质量、景深质量 / 光斑形状、体积雾格子、SSAO 质量）。
## Godot 4.7 里它们只有设置接口（RenderingServer.directional_shadow_atlas_set_size 等），没有读取接口；
## 一幕开在开场同一个窗口里（scripts/traveler/traveler_host.gd）时，回开场要能一项项还原，所以凡是改这几项的地方都走这里：
## 这里记下最后一次设的值，再原样转给 RenderingServer（画面和直接调一样）。没人设过的项按项目设置算（引擎启动时就是按项目设置建的）。
## 用到的地方：3D 棋盘（tools/merchant_board_claude_play_world.gd）、长安（traveler_lookdev.gd）、巴格达（baghdad_look.gd、
## baghdad_storm_look.gd）、找 L叔（lshu_look.gd）。traveler_globals.gd 的快照里是 state()，还原走 restore()。

static var _set: Dictionary = {}


## 当前渲染器有没有这项环境效果：Mobile 渲染器（安卓）没有 SDFGI / SSIL / SSAO / 体积雾，开了画面一样，
## 只会往 logcat 打引擎警告（安卓压力测试 TS-9）。Forward+（桌面）一律 true，画面不变
static func env_feature(name: String) -> bool:
	var m := RenderingServer.get_current_rendering_method()
	match name:
		"ssao":
			return m != "mobile"
		"sdfgi", "ssil", "volumetric_fog":
			return m == "forward_plus"
	return true


static func shadow_atlas(size: int, bits16: bool = true) -> void:
	_apply("shadow_atlas", [size, bits16])


static func directional_soft_shadow(quality: int) -> void:
	_apply("directional_soft_shadow", [quality])


static func positional_soft_shadow(quality: int) -> void:
	_apply("positional_soft_shadow", [quality])


static func dof_blur_quality(quality: int, jitter: bool) -> void:
	_apply("dof_blur", [quality, jitter])


static func dof_bokeh_shape(shape: int) -> void:
	_apply("dof_bokeh", [shape])


static func volumetric_fog_volume(size: int, depth: int) -> void:
	_apply("volumetric_fog_volume", [size, depth])


static func volumetric_fog_filter(active: bool) -> void:
	_apply("volumetric_fog_filter", [active])


static func ssao_quality(quality: int, half_size: bool, adaptive_target: float, blur_passes: int, fadeout_min: float, fadeout_max: float) -> void:
	_apply("ssao", [quality, half_size, adaptive_target, blur_passes, fadeout_min, fadeout_max])


## 项目设置里的起始值（引擎启动时按它建）
static func defaults() -> Dictionary:
	return {
		"shadow_atlas": [int(_ps("rendering/lights_and_shadows/directional_shadow/size", 4096)), bool(_ps("rendering/lights_and_shadows/directional_shadow/16_bits", true))],
		"directional_soft_shadow": [int(_ps("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 2))],
		"positional_soft_shadow": [int(_ps("rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality", 2))],
		"dof_blur": [int(_ps("rendering/camera/depth_of_field/depth_of_field_bokeh_quality", 1)), bool(_ps("rendering/camera/depth_of_field/depth_of_field_use_jitter", false))],
		"dof_bokeh": [int(_ps("rendering/camera/depth_of_field/depth_of_field_bokeh_shape", 1))],
		"volumetric_fog_volume": [int(_ps("rendering/environment/volumetric_fog/volume_size", 64)), int(_ps("rendering/environment/volumetric_fog/volume_depth", 64))],
		"volumetric_fog_filter": [bool(_ps("rendering/environment/volumetric_fog/use_filter", true))],
		"ssao": [int(_ps("rendering/environment/ssao/quality", 2)), bool(_ps("rendering/environment/ssao/half_size", true)),
			float(_ps("rendering/environment/ssao/adaptive_target", 0.5)), int(_ps("rendering/environment/ssao/blur_passes", 2)),
			float(_ps("rendering/environment/ssao/fadeout_from", 50.0)), float(_ps("rendering/environment/ssao/fadeout_to", 300.0))],
	}


## 现在生效的值：设过的按最后一次，没设过的按项目设置
static func state() -> Dictionary:
	var out := defaults()
	for k: String in _set:
		out[k] = (_set[k] as Array).duplicate()
	return out


## 把 snap（state() 的结果）里和现在不一样的项重新设回去；返回动过的项名
static func restore(snap: Dictionary) -> Array[String]:
	var now := state()
	var changed: Array[String] = []
	for k: String in snap:
		if not now.has(k) or not _same(now[k], snap[k]):
			_apply(k, (snap[k] as Array).duplicate())
			changed.append(k)
	return changed


static func _same(a: Variant, b: Variant) -> bool:
	return JSON.stringify(a) == JSON.stringify(b)


static func _ps(key: String, fallback: Variant) -> Variant:
	return ProjectSettings.get_setting(key, fallback)


static func _apply(key: String, v: Array) -> void:
	_set[key] = v.duplicate()
	match key:
		"shadow_atlas":
			RenderingServer.directional_shadow_atlas_set_size(int(v[0]), bool(v[1]))
		"directional_soft_shadow":
			RenderingServer.directional_soft_shadow_filter_set_quality(int(v[0]) as RenderingServer.ShadowQuality)
		"positional_soft_shadow":
			RenderingServer.positional_soft_shadow_filter_set_quality(int(v[0]) as RenderingServer.ShadowQuality)
		"dof_blur":
			RenderingServer.camera_attributes_set_dof_blur_quality(int(v[0]) as RenderingServer.DOFBlurQuality, bool(v[1]))
		"dof_bokeh":
			RenderingServer.camera_attributes_set_dof_blur_bokeh_shape(int(v[0]) as RenderingServer.DOFBokehShape)
		"volumetric_fog_volume":
			RenderingServer.environment_set_volumetric_fog_volume_size(int(v[0]), int(v[1]))
		"volumetric_fog_filter":
			RenderingServer.environment_set_volumetric_fog_filter_active(bool(v[0]))
		"ssao":
			RenderingServer.environment_set_ssao_quality(int(v[0]) as RenderingServer.EnvironmentSSAOQuality, bool(v[1]), float(v[2]), int(v[3]), float(v[4]), float(v[5]))
		_:
			push_warning("render_globals: unknown key " + key)
