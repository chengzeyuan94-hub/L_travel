shader_type spatial;
// 雪堆积（2026-09-20，盘橐雪景）。**新文件，不改任何已有 shader。**
//
// 为什么需要它：概念图-1 与两张排布图里，城墙每道横檐、每个塔顶、每块石头的朝上面
// 都压着一层雪。这不是贴图能给的——同一个资产在夏天场景也要用。所以按**世界法线朝上度**
// 在运行时混一层雪。石头因此自动变成排布图里画的那种「顶白、侧面蓝灰」，
// 城堡因此自动变成雪后的城堡。
//
// 用法：把资产原本 StandardMaterial3D 的 albedo_texture / albedo_color 灌进 base_tex / base_tint。
// 没贴图的资产把 use_tex 关掉即可。

render_mode cull_back, diffuse_lambert_wrap, specular_disabled;

uniform sampler2D base_tex : source_color, hint_default_white;
uniform bool use_tex = true;
uniform bool use_vertex_color = false;
uniform vec4 base_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float base_brightness : hint_range(0.0, 2.0) = 1.0;

// 雪本体：三档近白，跟地表用的是同一组值，保证城/石/地是同一种雪
uniform vec3 snow_lit : source_color = vec3(0.965, 0.972, 0.988);
uniform vec3 snow_shade : source_color = vec3(0.780, 0.822, 0.902);

// snow_start / snow_full：世界法线 y 的两个阈值。0.28→0.62 意味着
// 缓于约 51° 的面开始积雪、缓于约 39° 的面全覆盖，陡壁保持裸露。
uniform float snow_start : hint_range(-1.0, 1.0) = 0.28;
uniform float snow_full : hint_range(-1.0, 1.0) = 0.62;
// 把雪线打碎，否则每道檐口都是一条数学等高线，一眼假
uniform float snow_noise : hint_range(0.0, 1.0) = 0.34;
uniform float noise_scale : hint_range(0.1, 40.0) = 6.0;
// 朝上面额外提亮一点，模拟雪层本身的次表面散射
uniform float snow_rough : hint_range(0.0, 1.0) = 0.95;
uniform float base_rough : hint_range(0.0, 1.0) = 0.88;

varying vec3 w_nrm;
varying vec3 w_pos;

void vertex() {
	w_nrm = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float h31(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = h31(i);
	float n100 = h31(i + vec3(1.0, 0.0, 0.0));
	float n010 = h31(i + vec3(0.0, 1.0, 0.0));
	float n110 = h31(i + vec3(1.0, 1.0, 0.0));
	float n001 = h31(i + vec3(0.0, 0.0, 1.0));
	float n101 = h31(i + vec3(1.0, 0.0, 1.0));
	float n011 = h31(i + vec3(0.0, 1.0, 1.0));
	float n111 = h31(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
	           mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

void fragment() {
	vec3 base = base_tint.rgb * base_brightness;
	if (use_tex) {
		base *= texture(base_tex, UV).rgb;
	}
	if (use_vertex_color) {
		base *= max(COLOR.rgb, vec3(0.0));
	}

	vec3 n = normalize(w_nrm);
	// 两个尺度的噪声：大的决定哪片檐口积得厚，小的做边缘的碎口
	float nz = (vnoise(w_pos * noise_scale) - 0.5) * 0.72
	         + (vnoise(w_pos * noise_scale * 3.3) - 0.5) * 0.28;
	float cov = smoothstep(snow_start, snow_full, n.y + nz * snow_noise);

	// 雪自身也分档：朝上纯白，接近临界角的偏冷蓝，跟地表的三档白同源
	vec3 snow = mix(snow_shade, snow_lit, smoothstep(0.55, 0.95, n.y));

	ALBEDO = mix(base, snow, cov);
	ROUGHNESS = mix(base_rough, snow_rough, cov);
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
