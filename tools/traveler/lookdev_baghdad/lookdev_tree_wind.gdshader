shader_type spatial;
// 生命树风动（探针 key: tree，2026-09-23）。
// 外观：逐项复刻 _apply_lowpoly_materials 之后的 StandardMaterial3D
//   （albedo 贴图 × albedo_color(×1.05) × COLOR、per-pixel、burley、GGX、roughness 0.9、specular 0.5、
//     metallic 0、emission 为黑 → 不输出）。
// 动态：顶点里加风。树干根部锁死、按高度幂次弯曲的整体阵风摆动（3 个不可公约周期叠加，
//   阵风从上风侧向下风侧传过树冠），树冠叶簇再叠一层小幅、较快、按空间相位错开的抖动。
// 法线：原模型 73% 三角是平滑法线，直接换 dFdx 面法线会把树的明暗改掉；
//   所以用位移场的雅可比（有限差分）把"原法线"跟着形变转过去：静止时与原材质逐像素一致，
//   叶簇抖动时小平面会跟着轻微转向，逆光下有叶子翻动的明暗闪动。
// 金边 next_pass（lookdev_tree_rim.gdshader）里的 wind_offset / vertex 与本文件逐字相同，参数同步。
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, world_vertex_coords;

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform float roughness = 0.9;
uniform float specular = 0.5;

// ---- 风（与 lookdev_tree_rim.gdshader 完全一致） ----
uniform bool wind_enabled = true;
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);      // 世界空间、水平、单位向量（画面右 → 左）
uniform vec3 root_world = vec3(0.0);              // 树根（网格底面中心）世界坐标
uniform float tree_height = 7.65;                 // 世界高度
uniform float sway_tip_u = 0.055;                 // 阵风最强时树梢位移（世界 u）
uniform float sway_rest = 0.2;                    // 阵风最弱时仍保留的弯曲比例
uniform float bend_exponent = 1.5;
uniform float root_lock = 0.03;                   // 这一段高度以下完全不动
uniform vec3 sway_phase = vec3(0.0);              // 三个阵风分量的相位（GDScript 用双精度累加并取模 2π）
uniform vec3 sway_weight = vec3(0.6, 0.25, 0.15);
uniform float gust_wave_k = 0.12;                 // rad/u：阵风沿风向传播，下风侧稍晚
uniform float flutter_u = 0.02;                   // 叶簇抖动幅度（世界 u）
uniform vec3 flutter_phase = vec3(0.0);
uniform float flutter_k = 5.5;                    // rad/u：叶簇抖动的空间频率（约 1u 一个相位周期）
uniform float flutter_gust_coupling = 0.5;        // 阵风强时叶簇抖得更明显
uniform vec2 crown_band = vec2(0.14, 0.30);       // 高度比例：此区间内从树干过渡到树冠
uniform float normal_response = 0.6;              // 形变对法线的影响（1 = 按几何真实转动）
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
	UV = UV * uv_scale + uv_offset;
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
}

void fragment() {
	vec4 albedo_tex = texture(texture_albedo, UV);
	albedo_tex *= COLOR;
	ALBEDO = albedo_color.rgb * albedo_tex.rgb;
	METALLIC = 0.0;
	SPECULAR = specular;
	ROUGHNESS = roughness;
}
