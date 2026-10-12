shader_type spatial;
// 生命树金边 next_pass（探针 key: tree）：lookdev_fresnel_rim.gdshader 的副本，
// 加上与 lookdev_tree_wind.gdshader 逐字相同的风动顶点变形（参数由 lookdev_extra_tree.gd 同步），
// 否则金边会和摆动的树分离。片元部分与原金边完全相同。
// 另：两个 shader 各自编译，形变后的深度不保证逐位相等，加色 pass 可能和主 pass 打架（z-fighting）；
// 所以顶点沿视线朝相机拉近 depth_pull_u（几毫米，屏幕位置不变），保证金边稳定通过深度测试。
render_mode blend_add, unshaded, cull_back, depth_draw_never, fog_disabled, world_vertex_coords;

uniform vec3 rim_color : source_color = vec3(1.0, 0.78, 0.40);
uniform float rim_power = 3.0;
uniform float rim_intensity = 1.3;
uniform vec3 light_dir = vec3(-0.2, 0.1, 0.97);
uniform float dir_weight = 0.6;
uniform float dir_softness = 0.35;
uniform float depth_pull_u = 0.003;

// ---- 风（与 lookdev_tree_wind.gdshader 完全一致） ----
uniform bool wind_enabled = true;
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);
uniform vec3 root_world = vec3(0.0);
uniform float tree_height = 7.65;
uniform float sway_tip_u = 0.055;
uniform float sway_rest = 0.2;
uniform float bend_exponent = 1.5;
uniform float root_lock = 0.03;
uniform vec3 sway_phase = vec3(0.0);
uniform vec3 sway_weight = vec3(0.6, 0.25, 0.15);
uniform float gust_wave_k = 0.12;
uniform float flutter_u = 0.02;
uniform vec3 flutter_phase = vec3(0.0);
uniform float flutter_k = 5.5;
uniform float flutter_gust_coupling = 0.5;
uniform vec2 crown_band = vec2(0.14, 0.30);
uniform float normal_response = 0.6;
uniform float fd_eps = 0.035;
uniform float shadow_flutter_scale = 0.3;         // 平行光阴影 pass（正交投影）里叶簇抖动的比例：
                                                  // 长影子的 PCF 半影噪声会被逐帧重采样成细碎闪点，阴影只跟整体摆动、少跟叶簇抖

vec3 wind_offset(vec3 p, float fl_gain) {
	vec3 rel = p - root_world;
	float h = clamp(rel.y / tree_height, 0.0, 1.0);
	float u = clamp((h - root_lock) / (1.0 - root_lock), 0.0, 1.0);
	float lag = dot(rel, wind_dir) * gust_wave_k;
	float g = dot(sin(sway_phase - vec3(lag)), sway_weight) / max(sway_weight.x + sway_weight.y + sway_weight.z, 0.0001);
	float g01 = 0.5 + 0.5 * g;
	float bend = sway_tip_u * (sway_rest + (1.0 - sway_rest) * g01) * pow(u, bend_exponent);
	vec3 off = wind_dir * bend;
	float crown = smoothstep(crown_band.x, crown_band.y, h);
	vec3 q = rel * flutter_k;
	float w = sin(dot(q, vec3(0.31, 0.53, -0.47)) + 1.7);
	float f1 = sin(flutter_phase.x + dot(q, vec3(0.83, 0.37, -0.41)) + 1.3 * w);
	float f2 = sin(flutter_phase.y + dot(q, vec3(-0.33, 0.79, 0.52)) - 1.1 * w);
	float f3 = sin(flutter_phase.z + dot(q, vec3(0.49, -0.46, 0.74)) + 0.9 * w);
	vec3 side = vec3(-wind_dir.z, 0.0, wind_dir.x);
	vec3 fl = wind_dir * (0.55 * f1 + 0.35 * f2) + vec3(0.0, 1.0, 0.0) * (0.45 * f2 + 0.35 * f3) + side * (0.5 * f3 + 0.3 * f1);
	float amp = flutter_u * fl_gain * crown * (1.0 - flutter_gust_coupling + flutter_gust_coupling * g01);
	return off + fl * amp;
}

void vertex() {
	if (wind_enabled) {
		vec3 p = VERTEX;
		vec3 n = normalize(NORMAL);
		float fl_gain = PROJECTION_MATRIX[3][3] > 0.5 ? shadow_flutter_scale : 1.0;
		vec3 d0 = wind_offset(p, fl_gain);
		vec3 ddx = (wind_offset(p + vec3(fd_eps, 0.0, 0.0), fl_gain) - d0) / fd_eps;
		vec3 ddy = (wind_offset(p + vec3(0.0, fd_eps, 0.0), fl_gain) - d0) / fd_eps;
		vec3 ddz = (wind_offset(p + vec3(0.0, 0.0, fd_eps), fl_gain) - d0) / fd_eps;
		NORMAL = normalize(n - normal_response * vec3(dot(ddx, n), dot(ddy, n), dot(ddz, n)));
		VERTEX = p + d0;
	}
	VERTEX += normalize(CAMERA_POSITION_WORLD - VERTEX) * depth_pull_u;
}

void fragment() {
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fres = pow(1.0 - ndv, rim_power);
	vec3 n_world = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float toward = smoothstep(-dir_softness, dir_softness, dot(n_world, normalize(light_dir)));
	float w = mix(1.0, toward, dir_weight);
	ALBEDO = rim_color * rim_intensity * fres * w;
	ALPHA = 1.0;
}
