shader_type spatial;
// 营火火舌（由 Codex 的 baghdad_ambient_flame.gdshader 改写，uniform 名保持一致，ambient_motion 照常驱动 motion_time）。
// Codex 复盘：「火焰轮廓偏硬、像橙黄尖片」。原版是不透明 unshaded 色块，亮度 ≈1.2 永远过不了泛光阈值。
// 这里：侧面（掠射角）变透明 → 轮廓柔；焰尖渐隐；内芯（黄）写 HDR 亮度 → 过泛光阈值出光晕；外焰保持橙色。
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

uniform float motion_time = 0.0;
uniform vec4 base_tint : source_color = vec4(1.0);
uniform bool vertex_color_srgb = false;
uniform vec3 source_emission : source_color = vec3(1.0, 0.3, 0.05);
uniform float source_emission_energy = 0.025;
uniform float flame_bottom = 0.0;
uniform float flame_height = 0.3;
uniform float flame_width = 0.2;
uniform float core_gain = 2.4;      // 内芯 HDR 倍数
uniform float outer_gain = 1.25;    // 外焰倍数
uniform float edge_soft = 0.55;     // 越大轮廓越软
uniform float tip_start = 0.55;     // 焰尖从这里开始渐隐（相对高度）
uniform float alpha_max = 0.95;
varying float flame_brightness;
varying float flame_h;

vec3 srgb_to_linear(vec3 color) {
	return mix(color / 12.92, pow((color + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), color));
}

void vertex() {
	float h = clamp((VERTEX.y - flame_bottom) / max(flame_height, 0.001), 0.0, 1.0);
	flame_h = h;
	float tip_weight = h * h;
	float phase = (VERTEX.x * 3.1 + VERTEX.z * 2.3) / max(flame_width, 0.001);
	float primary = sin(motion_time * 3.1 + phase);
	float detail = sin(motion_time * 5.7 + phase * 1.7 + 0.8);
	VERTEX.x += flame_width * (0.15 * primary + 0.035 * detail) * tip_weight;
	VERTEX.z += flame_width * 0.075 * cos(motion_time * 3.8 + phase) * tip_weight;
	VERTEX.y += flame_height * (0.105 * primary + 0.035 * detail) * h;
	flame_brightness = 1.0 + 0.08 * sin(motion_time * 4.2 + phase) + 0.04 * detail;
}

void fragment() {
	vec3 tint = base_tint.rgb * (vertex_color_srgb ? srgb_to_linear(COLOR.rgb) : COLOR.rgb);
	float core = smoothstep(0.25, 0.50, tint.g);
	float ndv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float edge = smoothstep(0.0, edge_soft, ndv);
	float tip = 1.0 - smoothstep(tip_start, 1.0, flame_h);
	float base_fade = smoothstep(0.0, 0.06, flame_h);
	ALBEDO = tint * flame_brightness * mix(outer_gain, core_gain, core);
	ALPHA = clamp(edge * tip * mix(0.85, 1.0, core) * base_fade * alpha_max, 0.0, 1.0);
}
