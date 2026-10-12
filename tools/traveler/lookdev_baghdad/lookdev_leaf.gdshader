shader_type spatial;
// 落叶：顶点色（粒子 COLOR）当颜色，逆光时轻微自发光，让叶片读成"透光的叶子"而不是白点。
render_mode cull_disabled, diffuse_lambert_wrap;

uniform float emission_boost = 0.35;
uniform float leaf_roughness = 1.0;

void fragment() {
	NORMAL = normalize(NORMAL) * (FRONT_FACING ? 1.0 : -1.0);
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * emission_boost;
	ROUGHNESS = leaf_roughness;
	SPECULAR = 0.0;
	METALLIC = 0.0;
}
