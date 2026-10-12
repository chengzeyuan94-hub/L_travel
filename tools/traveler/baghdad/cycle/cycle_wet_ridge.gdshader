shader_type spatial;
// 雨世界里的中景沙脊 / 沙斑（tools/traveler/baghdad/cycle/cycle_midground.gd 使用）。
// 颜色取沙脊自带的顶点色（晚霞世界里认可的明暗层次），换算到雨世界的沙色，
// 湿润公式照抄 Codex 的 baghdad_rain_wet_ground.gdshader（近处 z<12.5 变湿变暗），不做水洼。
render_mode diffuse_burley, specular_schlick_ggx, cull_back;

uniform vec3 sand_ratio = vec3(0.869, 0.940, 1.067);   // 雨世界沙色 (0.73,0.63,0.48) ÷ 晚霞世界沙色 (0.84,0.67,0.45)
uniform float wetness : hint_range(0.0, 1.0) = 0.92;
uniform bool vertex_color_is_srgb = true;
varying vec3 world_position;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float noise2(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}
void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (vertex_color_is_srgb) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
}
void fragment() {
	vec2 p = world_position.xz;
	float front = 1.0 - smoothstep(7.5, 12.5, world_position.z);
	float fine = noise2(p * 145.0);
	float worn = noise2(p * 12.0);
	vec3 dry = COLOR.rgb * sand_ratio * (0.90 + worn * 0.10) * (0.90 + fine * 0.15);
	ALBEDO = dry * mix(1.0, 0.55, wetness * front);
	ROUGHNESS = mix(0.94, 0.67, wetness * front);
	SPECULAR = 0.23;
	METALLIC = 0.0;
}
