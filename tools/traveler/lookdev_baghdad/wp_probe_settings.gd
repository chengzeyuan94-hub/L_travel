extends SceneTree
## wp_probe_settings.gd（2026-09-23，动态壁纸试验）：只读打印几个与"无缝循环 / 长时间运行"有关的引擎设置。
func _initialize() -> void:
	var out := {
		"time_rollover_secs": ProjectSettings.get_setting("rendering/limits/time/time_rollover_secs"),
		"anti_aliasing_taa": ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_taa"),
		"scaling_3d_mode": ProjectSettings.get_setting("rendering/scaling_3d/mode"),
		"scaling_3d_scale": ProjectSettings.get_setting("rendering/scaling_3d/scale"),
		"window_size": [ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height")],
		"gpu_particles_has_use_fixed_seed": ClassDB.class_has_method("GPUParticles3D", "set_use_fixed_seed"),
	}
	print("WP_PROBE ", JSON.stringify(out))
	quit()
