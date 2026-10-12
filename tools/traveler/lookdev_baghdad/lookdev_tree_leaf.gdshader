shader_type spatial;
// 落叶绘制（探针 key: tree）：lookdev_leaf.gdshader 的副本，加 BACKLIGHT 让太阳在叶子背后时透亮。
// 颜色仍取粒子 COLOR（黄绿→橙四色），emission_boost 与原来一致。
render_mode cull_disabled, diffuse_lambert_wrap;

uniform float emission_boost = 0.35;
uniform float leaf_roughness = 1.0;
uniform float backlight_strength = 0.2;

void fragment() {
	NORMAL = normalize(NORMAL) * (FRONT_FACING ? 1.0 : -1.0);
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * emission_boost;
	BACKLIGHT = COLOR.rgb * backlight_strength;
	ROUGHNESS = leaf_roughness;
	SPECULAR = 0.0;
	METALLIC = 0.0;
}
