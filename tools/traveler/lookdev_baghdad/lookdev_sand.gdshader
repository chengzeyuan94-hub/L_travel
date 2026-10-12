shader_type spatial;
// 导演探针：巴格达沙地材质（2026-09-23）。几何不动，只换地面材质。
// Carlos：「中景的沙漠的地形有点光秃秃的，没有沙子的颗粒感」。
// 四层，都在世界 XZ 上程序生成：
//   1. macro：低频色斑（凹处偏红、凸处偏亮），打破大面积单色；
//   2. grain：细颗粒亮度噪声（两档尺度），远处按像素覆盖衰减到一个底值；
//   3. ripples：风成沙纹（缓迎风坡 + 陡背风坡的不对称剖面，方向被低频噪声扭曲），
//      只扰动法线，让低太阳在沙纹上刮出明暗；一个周期小于 ripple_fade_px 像素时淡出，防摩尔纹；
//   4. glints：极稀疏的晶粒反光（逆光时朝相机的半角方向），可选。
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled;

uniform vec3 sand_color : source_color = vec3(0.84, 0.67, 0.45);
uniform float roughness_v = 0.9;
// 地面三角绕序（stage→世界 X 镜像后）从上方看是背面；cull_disabled 时 Godot 在用户 fragment 之前
// 就把背面的 NORMAL 取反，平沙法线朝下、几乎吃不到太阳。=1 时把朝下的法线翻回朝上（诊断/修复用）。
uniform float fix_backface_normal = 0.0;
uniform float debug_mode = 0.0;
uniform float specular_v = 0.5;
uniform vec3 sun_dir_world = vec3(0.2, 0.1, 0.97);

uniform float macro_scale = 0.22;
uniform float macro_strength = 0.35;
uniform vec3 trough_tint : source_color = vec3(0.78, 0.52, 0.36);
uniform vec3 crest_tint : source_color = vec3(0.92, 0.76, 0.54);

uniform vec2 grain_scale = vec2(60.0, 4.0);   // 每 u 的格数（x 横向，z 纵深）；机位低，纵深方向格子要拉长
uniform float grain_strength = 0.18;
uniform float grain_far_floor = 1.0;           // 机位固定不动，远处的像素级杂点是稳定的，可以不衰减
uniform vec2 fleck_scale = vec2(28.0, 2.2);
uniform float fleck_density = 0.05;
uniform float fleck_dark = 0.35;
uniform vec3 fleck_color : source_color = vec3(0.45, 0.34, 0.26);

uniform float ripple_enabled = 1.0;
uniform float ripple_wavelength = 0.32;
uniform float ripple_angle_deg = 20.0;
uniform float ripple_warp = 0.9;
uniform float ripple_warp_scale = 0.30;
uniform float ripple_lee = 0.28;
uniform float ripple_strength = 0.9;
uniform float ripple_albedo = 0.05;
uniform float ripple_fade_px = 4.0;
uniform float ripple_start_z = 2.0;
uniform float ripple_patch_scale = 0.12;
uniform float ripple_patch_cover = 0.75;

uniform float glint_strength = 0.0;
uniform vec2 glint_scale = vec2(25.0, 2.5);
uniform float glint_density = 0.02;
uniform float glint_sharpness = 0.985;
uniform float glint_jitter = 1.0;
// glint_mode 1：前向散射闪点（风格化）——与视角无关的随机晶粒，亮度按"看向太阳的程度"和受光加权。
// 逆光机位下镜面半角偏离竖直约 59°，物理镜面模型几乎不触发（t_sand6/7 实测为零），所以默认用它。
uniform float glint_mode = 1.0;
uniform float glint_forward_pow = 3.0;
uniform vec3 glint_color : source_color = vec3(1.0, 0.86, 0.62);

varying vec3 wpos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
vec2 hash22(vec2 p) {
	float a = hash21(p);
	return vec2(a, hash21(p + a + 17.1));
}
float noise21(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0)), f.x), f.y);
}
float fbm3(vec2 p) {
	return noise21(p) * 0.57 + noise21(p * 2.07 + 11.3) * 0.29 + noise21(p * 4.13 + 5.7) * 0.14;
}

float ripple_height(vec2 p) {
	float a = radians(ripple_angle_deg);
	vec2 q = vec2(cos(a) * p.x - sin(a) * p.y, sin(a) * p.x + cos(a) * p.y);
	q.y += (fbm3(p * ripple_warp_scale) - 0.5) * ripple_warp * 2.0;
	float s = fract(q.y / ripple_wavelength);
	float lee = clamp(ripple_lee, 0.05, 0.95);
	float h = s < 1.0 - lee ? s / (1.0 - lee) : (1.0 - s) / lee;
	return h * h * (3.0 - 2.0 * h);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz;
	float stage_z = wpos.z;
	vec3 n_world = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	if (fix_backface_normal > 0.5 && n_world.y < 0.0) {
		n_world = -n_world;
	}
	float debug_facing = FRONT_FACING ? 1.0 : 0.0;

	// 1. macro 色斑
	float m = fbm3(p * macro_scale);
	vec3 base = mix(trough_tint, crest_tint, smoothstep(0.25, 0.75, m));
	vec3 albedo = mix(sand_color, base, macro_strength);

	// 2. 颗粒
	vec2 gp = p * grain_scale;
	float g_cov = length(fwidth(gp));
	float g_fade = mix(1.0, grain_far_floor, smoothstep(0.4, 1.5, g_cov));
	float g = hash21(floor(gp)) * 0.6 + hash21(floor(gp * vec2(2.3, 1.7) + 7.0)) * 0.4;
	albedo *= 1.0 + (g - 0.5) * grain_strength * g_fade;
	// 深色碎屑（小石子/粗砂）
	vec2 fp = p * fleck_scale;
	vec2 fcell = floor(fp);
	if (hash21(fcell + 3.7) < fleck_density) {
		float r = length((fract(fp) - 0.5) * vec2(1.0, 1.0));
		float fm = 1.0 - smoothstep(0.18, 0.38, r);
		albedo = mix(albedo, fleck_color, fm * fleck_dark);
	}

	// 3. 沙纹（法线扰动）
	vec3 n = n_world;
	if (ripple_enabled > 0.5) {
		float a_r = radians(ripple_angle_deg);
		float phase_coord = sin(a_r) * p.x + cos(a_r) * p.y;
		float cyc = fwidth(phase_coord) / max(ripple_wavelength, 1e-4);
		float fade = 1.0 - smoothstep(0.5 / ripple_fade_px, 1.0 / ripple_fade_px, cyc);
		fade *= smoothstep(ripple_start_z, ripple_start_z + 2.0, stage_z);
		float patch = smoothstep(1.0 - ripple_patch_cover, 1.0 - ripple_patch_cover + 0.25, noise21(p * ripple_patch_scale + 3.3));
		fade *= patch;
		if (fade > 0.001) {
			float e = ripple_wavelength * 0.06;
			float h0 = ripple_height(p);
			float hx = ripple_height(p + vec2(e, 0.0));
			float hz = ripple_height(p + vec2(0.0, e));
			vec2 grad = vec2(hx - h0, hz - h0) / e * ripple_wavelength * 0.25;
			n = normalize(n_world - vec3(grad.x, 0.0, grad.y) * ripple_strength * fade);
			albedo *= 1.0 + (h0 - 0.5) * ripple_albedo * fade;
		}
	}

	// 4. 晶粒反光
	vec3 emit = vec3(0.0);
	if (glint_strength > 0.0) {
		vec2 cp = p * glint_scale;
		vec2 cell = floor(cp);
		float pick = hash21(cell + 91.7);
		if (pick < glint_density) {
			// 逆光（太阳在前、相机在后）时 L+V 几乎抵消，半角向量偏向太阳一侧约 45°，
			// 晶面要大角度随机取向才会有一部分对上；所以法线抖动取到 ±1（约 ±45°）。
			vec2 r = hash22(cell) * 2.0 - 1.0;
			vec3 jn = normalize(n_world + vec3(r.x, 0.0, r.y) * glint_jitter);
			vec3 v = normalize(CAMERA_POSITION_WORLD - wpos);
			vec3 hv = normalize(normalize(sun_dir_world) + v);
			float d = dot(jn, hv);
			float spark = smoothstep(glint_sharpness, 1.0, d);
			if (glint_mode > 0.5) {
				float forward = pow(max(dot(-v, normalize(sun_dir_world)), 0.0), glint_forward_pow);
				float lit = smoothstep(0.0, 0.25, dot(n_world, normalize(sun_dir_world)));
				float twinkle = hash21(cell + 13.3);
				spark = forward * lit * (0.35 + 0.65 * twinkle);
			}
			vec2 f = fract(cp) - 0.5;
			spark *= 1.0 - smoothstep(0.15, 0.45, length(f));
			emit = glint_color * spark * glint_strength;
		}
	}

	if (debug_mode > 0.5) {
		albedo = debug_mode < 1.5 ? vec3(debug_facing) : vec3(n_world.y * 0.5 + 0.5);
		emit = albedo;
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness_v;
	SPECULAR = specular_v;
	METALLIC = 0.0;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	EMISSION = emit;
}
