shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

// 骰子 v2（L叔玩具骰）：顶点色就是反照率（glTF COLOR_0 本身是线性值，直接用）。
// 三种表面共用这一个 shader，只差参数：粘土（骰体、橄榄环、叶子）/ 釉面（点、眼镜）/ 微光（土豆花）。
uniform float roughness_value : hint_range(0.0, 1.0) = 0.62;
uniform float specular_value : hint_range(0.0, 1.0) = 0.35;
uniform float emission_strength : hint_range(0.0, 3.0) = 0.0;
// 粘土玩具的柔和轮廓光：掠射处提一点暖色，暗面不发灰。
uniform vec3 rim_tint : source_color = vec3(1.0, 0.93, 0.80);
uniform float rim_strength : hint_range(0.0, 1.0) = 0.10;

void fragment() {
	vec3 base = COLOR.rgb;
	ALBEDO = base;
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	EMISSION = base * emission_strength + rim_tint * pow(1.0 - ndv, 3.0) * rim_strength;
}
