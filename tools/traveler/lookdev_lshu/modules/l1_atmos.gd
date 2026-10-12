extends RefCounted
## L1 lighting & atmosphere module (look line L1). Global pipeline only: nothing here reads a tile id.
## It owns what the viewer's variant keys cannot express:
##   1. renderer quality that every tile shares (directional shadow atlas, soft-shadow filter, DOF quality,
##      debanding) - RenderingServer / viewport state, set once in build();
##   2. the visible backdrop: swaps the stage-floor shader for shaders/l1_floor.gdshader (same uniform names,
##      so the viewer's own floor/sky keys keep working) and feeds its extra uniforms from cfg.atmos.floor;
##   3. fog modes the viewer does not expose (depth fog relative to the camera-fit distance, height mist
##      relative to the tile plinth, fog colour derived from the backdrop so haze melts into it);
##   4. glow extras (luminance cap, normalized, mix) and SSIL sharpness.
## Per-light values live in the variant under the section "atmos" (common + lights.<name>.atmos), read from
## host.cfg on every light change; module-level cfg only holds the one-off renderer settings.
var host: Node3D
var cfg: Dictionary = {}
var floor_shader: Shader
var report: Dictionary = {}
var backdrop_lin: Array = []

const FLOOR_SHADER := "res://tools/traveler/lookdev_lshu/shaders/l1_floor.gdshader"

func build(h: Node3D, c: Dictionary) -> Dictionary:
	host = h
	cfg = c
	# ---- 1. shared renderer quality
	var atlas: int = int(cfg.get("shadow_atlas", 8192))
	RenderingServer.directional_shadow_atlas_set_size(atlas, true)
	var soft_q: int = int(cfg.get("soft_shadow_quality", 4))
	RenderingServer.directional_soft_shadow_filter_set_quality(soft_q as RenderingServer.ShadowQuality)
	RenderingServer.positional_soft_shadow_filter_set_quality(int(cfg.get("positional_soft_shadow_quality", 3)) as RenderingServer.ShadowQuality)
	var dof_q: Dictionary = {"very_low": RenderingServer.DOF_BLUR_QUALITY_VERY_LOW, "low": RenderingServer.DOF_BLUR_QUALITY_LOW, "medium": RenderingServer.DOF_BLUR_QUALITY_MEDIUM, "high": RenderingServer.DOF_BLUR_QUALITY_HIGH}
	RenderingServer.camera_attributes_set_dof_blur_quality(dof_q.get(str(cfg.get("dof_quality", "high")), RenderingServer.DOF_BLUR_QUALITY_HIGH), bool(cfg.get("dof_jitter", false)))
	var shapes: Dictionary = {"box": RenderingServer.DOF_BOKEH_BOX, "hexagon": RenderingServer.DOF_BOKEH_HEXAGON, "circle": RenderingServer.DOF_BOKEH_CIRCLE}
	RenderingServer.camera_attributes_set_dof_blur_bokeh_shape(shapes.get(str(cfg.get("dof_bokeh", "circle")), RenderingServer.DOF_BOKEH_CIRCLE))
	var vp: Viewport = host.get_viewport()
	vp.use_debanding = bool(cfg.get("debanding", true))
	vp.use_taa = bool(cfg.get("taa", false))
	var pos_atlas: int = int(cfg.get("positional_shadow_atlas", 4096))
	vp.positional_shadow_atlas_size = pos_atlas
	# ---- 2. backdrop shader swap (uniform names are a superset of lshu_floor.gdshader)
	floor_shader = load(FLOOR_SHADER) as Shader
	var floor_mat: ShaderMaterial = host.get("floor_material") as ShaderMaterial
	if floor_mat != null and floor_shader != null:
		floor_mat.shader = floor_shader
	host.call("register_light_callback", _on_light)
	host.call("register_tick", _on_tick)
	# Re-apply the preset so the viewer rebinds its floor uniforms on the new shader, then our callback runs.
	host.call("set_light", str(host.get("light_name")))
	report["renderer"] = {"shadow_atlas": atlas, "soft_shadow_quality": soft_q, "dof_quality": str(cfg.get("dof_quality", "high")), "debanding": vp.use_debanding, "taa": vp.use_taa, "positional_shadow_atlas": pos_atlas}
	host.call("add_report", "l1_atmos", report)
	return {"ok": floor_shader != null, "light": host.get("light_name")}

func _atmos() -> Dictionary:
	var hc: Dictionary = host.get("cfg")
	return hc.get("atmos", {})

static func _lin(v: Variant, fallback: Color) -> Vector3:
	var c: Color = fallback
	if v is String:
		c = Color.html(str(v))
	elif v is Array and (v as Array).size() >= 3:
		var a: Array = v
		c = Color(float(a[0]), float(a[1]), float(a[2]))
	c = c.srgb_to_linear()
	return Vector3(c.r, c.g, c.b)

func _on_light(light: String) -> void:
	var a: Dictionary = _atmos()
	var env: Environment = host.get("environment") as Environment
	var camera_fit: Dictionary = host.get("camera_fit")
	var focus: float = float(camera_fit.get("focus_distance", 28.0))
	# ---- floor / backdrop extras
	var fl: Dictionary = a.get("floor", {})
	var floor_mat: ShaderMaterial = host.get("floor_material") as ShaderMaterial
	var sky_mat: ShaderMaterial = host.get("sky_material") as ShaderMaterial
	# Robust backdrop compensation (replaces the viewer's multiplicative ACES inverse, which diverges for
	# dark saturated colours such as #15294a): per-channel bisection through the full display transform
	# (exposure -> ACES -> sRGB -> brightness/contrast/saturation), Gauss-Seidel sweeps, clamped at 0.
	var hc: Dictionary = host.get("cfg")
	var sk: Dictionary = hc.get("sky", {})
	var bd_display: Color = host.get("backdrop_display")
	var top_target: Color = _mul(bd_display, float(sk.get("top_mult", 1.0)), fl.get("top_tint", null))
	var bottom_target: Color = _mul(bd_display, float(sk.get("bottom_mult", 1.0)), fl.get("bottom_tint", null))
	var top_lin: Vector3 = _solve_display(top_target, env)
	var bottom_lin: Vector3 = _solve_display(bottom_target, env)
	backdrop_lin = [top_lin, bottom_lin]
	if floor_mat != null:
		floor_mat.set_shader_parameter("backdrop_top", top_lin)
		floor_mat.set_shader_parameter("backdrop_bottom", bottom_lin)
	if sky_mat != null:
		sky_mat.set_shader_parameter("backdrop_top", Color(top_lin.x, top_lin.y, top_lin.z).linear_to_srgb())
		sky_mat.set_shader_parameter("backdrop_bottom", Color(bottom_lin.x, bottom_lin.y, bottom_lin.z).linear_to_srgb())
	report["backdrop"] = {"display_top": top_target.to_html(false), "display_bottom": bottom_target.to_html(false), "predicted_top": _display(top_lin, env).to_html(false), "predicted_bottom": _display(bottom_lin, env).to_html(false)}
	if floor_mat != null:
		floor_mat.set_shader_parameter("gradient_curve", float(fl.get("gradient_curve", 1.0)))
		floor_mat.set_shader_parameter("glow_tint", _lin(fl.get("glow_tint", "#ffffff"), Color.WHITE))
		var gr: Array = fl.get("glow_radius", [1.4, 2.0])
		floor_mat.set_shader_parameter("glow_radius", Vector2(float(gr[0]), float(gr[1])))
		var gc: Array = fl.get("glow_center", [0.5, 0.45])
		floor_mat.set_shader_parameter("glow_center", Vector2(float(gc[0]), float(gc[1])))
		floor_mat.set_shader_parameter("vignette_inner", float(fl.get("vignette_inner", 0.25)))
		floor_mat.set_shader_parameter("vignette_outer", float(fl.get("vignette_outer", 0.8)))
		floor_mat.set_shader_parameter("contact_ao", float(fl.get("contact_ao", 0.0)))
		floor_mat.set_shader_parameter("contact_ao_radius", float(fl.get("contact_ao_radius", 1.0)))
		floor_mat.set_shader_parameter("shadow_fade_distance", float(fl.get("shadow_fade_distance", 60.0)))
		floor_mat.set_shader_parameter("stars_amount", float(fl.get("stars_amount", 0.0)))
		floor_mat.set_shader_parameter("stars_density", float(fl.get("stars_density", 0.004)))
		floor_mat.set_shader_parameter("stars_tint", _lin(fl.get("stars_tint", "#ffffff"), Color.WHITE))
		floor_mat.set_shader_parameter("stars_top_bias", float(fl.get("stars_top_bias", 1.4)))
	# the sky's own visible branch sits behind the floor; keep its glow centre in step anyway
	if sky_mat != null and fl.has("glow_center"):
		var gc2: Array = fl.get("glow_center")
		sky_mat.set_shader_parameter("glow_center", Vector2(float(gc2[0]), float(gc2[1])))
	# ---- fog: colour from the backdrop (so haze melts into it), depth fog relative to the camera fit,
	# height mist relative to the ground (y = 0 is the web ground datum on every tile)
	var fog: Dictionary = a.get("fog", {})
	if env != null:
		env.fog_enabled = bool(fog.get("enabled", false))
		if env.fog_enabled:
			var mode: String = str(fog.get("mode", "depth"))
			env.fog_mode = Environment.FOG_MODE_DEPTH if mode == "depth" else Environment.FOG_MODE_EXPONENTIAL
			env.fog_depth_begin = maxf(0.0, focus + float(fog.get("depth_begin_offset", 0.0)))
			env.fog_depth_end = maxf(env.fog_depth_begin + 0.1, focus + float(fog.get("depth_end_offset", 40.0)))
			env.fog_depth_curve = float(fog.get("depth_curve", 1.0))
			env.fog_density = float(fog.get("density", 0.0))
			env.fog_height = float(fog.get("height", -0.2))
			env.fog_height_density = float(fog.get("height_density", 0.0))
			env.fog_sun_scatter = float(fog.get("sun_scatter", 0.0))
			env.fog_aerial_perspective = float(fog.get("aerial_perspective", 0.0))
			env.fog_sky_affect = float(fog.get("sky_affect", 0.0))
			env.fog_light_energy = float(fog.get("light_energy", 1.0))
			# fog colour = the backdrop where the tile's lower half sits, so haze and mist melt into it
			var fm: float = float(fog.get("backdrop_mix", 0.6))
			var fl_lin: Vector3 = top_lin.lerp(bottom_lin, fm)
			var fog_col: Color = Color(fl_lin.x, fl_lin.y, fl_lin.z).linear_to_srgb()
			if fog.has("color"):
				var fc: Variant = fog.get("color")
				var custom: Color = Color.html(str(fc)) if fc is String else Color(float(fc[0]), float(fc[1]), float(fc[2]))
				fog_col = fog_col.lerp(custom, float(fog.get("color_mix", 1.0)))
			env.fog_light_color = fog_col
		# glow extras
		var gl: Dictionary = a.get("glow", {})
		env.glow_hdr_luminance_cap = float(gl.get("luminance_cap", 12.0))
		env.glow_normalized = bool(gl.get("normalized", false))
		env.glow_mix = float(gl.get("mix", 0.05))
		# ssil extras
		var si: Dictionary = a.get("ssil", {})
		env.ssil_sharpness = float(si.get("sharpness", 0.98))
		env.ssil_normal_rejection = float(si.get("normal_rejection", 1.0))
	report["light"] = light
	report["fog"] = {"enabled": env.fog_enabled if env != null else false, "depth_begin": env.fog_depth_begin if env != null else 0.0, "depth_end": env.fog_depth_end if env != null else 0.0, "color": (env.fog_light_color.to_html(false) if env != null else "")}
	host.call("add_report", "l1_atmos", report)

static func _mul(c: Color, k: float, tint: Variant) -> Color:
	var out: Color = Color(c.r * k, c.g * k, c.b * k)
	if tint is Array and (tint as Array).size() >= 3:
		var t: Array = tint
		out = Color(out.r * float(t[0]), out.g * float(t[1]), out.b * float(t[2]))
	elif tint is String:
		var tc: Color = Color.html(str(tint))
		out = Color(out.r * tc.r, out.g * tc.g, out.b * tc.b)
	return Color(clampf(out.r, 0.0, 1.0), clampf(out.g, 0.0, 1.0), clampf(out.b, 0.0, 1.0))

## Forward display model of a linear scene colour (what the floor outputs before tonemapping).
func _display(x: Vector3, env: Environment) -> Color:
	var y: Vector3 = x * env.tonemap_exposure
	if env.tonemap_mode == Environment.TONE_MAPPER_ACES:
		y = host.call("_aces", y, env.tonemap_white)
	y = y.clamp(Vector3.ZERO, Vector3.ONE)
	var c: Color = Color(y.x, y.y, y.z).linear_to_srgb()
	if env.adjustment_enabled:
		var v: Vector3 = Vector3(c.r, c.g, c.b) * env.adjustment_brightness
		v = Vector3(0.5, 0.5, 0.5).lerp(v, env.adjustment_contrast)
		var g: float = (v.x + v.y + v.z) / 3.0
		v = Vector3(g, g, g).lerp(v, env.adjustment_saturation)
		c = Color(v.x, v.y, v.z)
	return c

func _solve_display(target: Color, env: Environment) -> Vector3:
	var x: Vector3 = Vector3(target.r, target.g, target.b)
	var lin: Color = target.srgb_to_linear()
	x = Vector3(lin.r, lin.g, lin.b)
	for _sweep: int in 6:
		for ch: int in 3:
			var lo: float = 0.0
			var hi: float = 16.0
			for _it: int in 22:
				var mid: float = (lo + hi) * 0.5
				var probe: Vector3 = x
				probe[ch] = mid
				var d: Color = _display(probe, env)
				var got: float = d.r if ch == 0 else (d.g if ch == 1 else d.b)
				var want: float = target.r if ch == 0 else (target.g if ch == 1 else target.b)
				if got < want:
					lo = mid
				else:
					hi = mid
			x[ch] = (lo + hi) * 0.5
	return x

func _on_tick(t: float, _delta: float) -> void:
	var floor_mat: ShaderMaterial = host.get("floor_material") as ShaderMaterial
	if floor_mat != null:
		floor_mat.set_shader_parameter("anim_time", t)
