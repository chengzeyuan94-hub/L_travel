shader_type spatial;
// 远城窗灯（由 Codex 的 baghdad_city_lights.gdshader 改写，uniform 名保持一致）。
// 原版 unshaded 下 EMISSION 不生效，窗面只有 warm×0.2 的暗橙，读到的"亮点"其实是泛光灯打在门拱上的热斑。
// 这里把亮度直接写进 ALBEDO（HDR），energy 当作亮度倍数用；门洞（面积是全部窗面的 2.7 倍）单独压暗。
render_mode unshaded, cull_disabled;

uniform vec4 warm_color : source_color = vec4(1.0, 0.49, 0.14, 1.0);
uniform float energy = 1.3;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float clock = 0.0;
uniform vec3 door_min = vec3(-0.40, -0.10, 0.70);   // 城市模型局部坐标里的门洞范围
uniform vec3 door_max = vec3(0.40, 1.32, 1.10);
uniform float door_level = 0.40;
varying vec3 source_position;

void vertex() {
	source_position = VERTEX;
}

void fragment() {
	float subtle_flicker = 0.97 + 0.03 * sin(clock * 1.6 + source_position.x * 1.9 + source_position.z * 0.8);
	vec3 inside = step(door_min, source_position) * step(source_position, door_max);
	float is_door = inside.x * inside.y * inside.z;
	ALBEDO = warm_color.rgb * energy * amount * subtle_flicker * mix(1.0, door_level, is_door);
}
