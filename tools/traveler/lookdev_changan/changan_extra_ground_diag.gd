extends RefCounted
## ground 线 · 诊断用（不进 final）：只调太阳阴影偏移，验证地面「等高纹」是不是阴影粉刺（shadow acne）。
## cfg: {"shadow_bias": float, "shadow_normal_bias": float}
func build(host: Node3D, cfg: Dictionary) -> Dictionary:
	var sun := host.get("sun") as DirectionalLight3D
	var before := {"shadow_bias": sun.shadow_bias, "shadow_normal_bias": sun.shadow_normal_bias,
		"angular": sun.light_angular_distance, "blur": sun.shadow_blur, "split1": sun.directional_shadow_split_1, "max": sun.directional_shadow_max_distance}
	if cfg.has("shadow_bias"):
		sun.shadow_bias = float(cfg.shadow_bias)
	if cfg.has("shadow_normal_bias"):
		sun.shadow_normal_bias = float(cfg.shadow_normal_bias)
	return {"before": before, "after": {"shadow_bias": sun.shadow_bias, "shadow_normal_bias": sun.shadow_normal_bias}}
