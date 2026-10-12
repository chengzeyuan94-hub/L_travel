shader_type spatial;
// sand / 沙脊扬沙 的绘制：一缕很淡的金色薄纱（look-dev 探针，不是交付代码）。
// 面片沿风向（UV.x：0 上风/脊上源头 → 1 下风），UV.y：0 上 → 1 下。
// 纱的内部是沿风向拉长的各向异性噪声，按世界坐标顺风滚动（纱里的丝跟着空气跑，不跟面片死贴）；
// 外形：源头浓、往下风变薄，越往下风越往上翘（被风掀起）。
// 光照同流沙：前向散射 light()，ATTENUATION 带阴影。depth_draw_never + 软粒子；雾、景深走引擎默认。
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);
uniform vec3 spray_color : source_color = vec3(1.0, 0.85, 0.62);
uniform float tex_speed = 0.75;       // u/s
uniform float freq_s = 2.2;           // 沿风向每 u 多少段
uniform float freq_y = 9.0;           // 竖直每 u 多少段
uniform float wisp_lo = 0.40;
uniform float wisp_hi = 0.82;
uniform float scatter = 1.2;
uniform float scatter_power = 8.0;
uniform float wrap_diffuse = 0.08;
uniform float ambient_ao = 0.4;
uniform float soft_fade_u = 0.35;
uniform vec4 trunk_tan = vec4(0.0);
uniform vec4 crown_tan = vec4(0.0);
uniform float tree_depth = 11.0;
uniform float mask_soft_tan = 0.008;
uniform float along_in = 0.15;          // 上风端（脊上）淡入宽度
uniform float along_out = 0.45;         // 从这里起往下风淡出
uniform float center_lo = 0.28;         // 竖直重心：上风端
uniform float center_hi = 0.62;         // 竖直重心：下风端（往上翘）

varying float v_seed;
varying vec3 v_world;

float h21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = h21(i);
	float b = h21(i + vec2(1.0, 0.0));
	float c = h21(i + vec2(0.0, 1.0));
	float d = h21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.55;
	for (int i = 0; i < 3; i++) {
		v += amp * vnoise2(p);
		p = p * vec2(2.03, 1.97) + vec2(7.1, 3.3);
		amp *= 0.5;
	}
	return v / 0.9625;
}

float in_rect(vec2 t, vec4 r, float soft) {
	float ix = smoothstep(r.x - soft, r.x, t.x) * (1.0 - smoothstep(r.z, r.z + soft, t.x));
	float iy = smoothstep(r.y - soft, r.y, t.y) * (1.0 - smoothstep(r.w, r.w + soft, t.y));
	return ix * iy;
}

float in_ellipse(vec2 t, vec4 r, float soft) {
	vec2 c = (r.xy + r.zw) * 0.5;
	vec2 hr = max((r.zw - r.xy) * 0.5, vec2(1e-4));
	float e = length((t - c) / hr);
	float rel = soft / min(hr.x, hr.y);
	return 1.0 - smoothstep(1.0, 1.0 + rel, e);
}

void vertex() {
	v_seed = INSTANCE_CUSTOM.z;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 wp = v_world;
	float depth = -VERTEX.z;
	vec2 tn = VERTEX.xy / max(depth, 1e-4);
	float s = dot(wp.xz, wind_dir.xz);
	vec2 q = vec2((s - TIME * tex_speed) * freq_s, wp.y * freq_y) + vec2(v_seed * 37.0, v_seed * 11.0);
	float n = fbm(q);
	float wisp = smoothstep(wisp_lo, wisp_hi, n);
	float u = UV.x;
	float vv = 1.0 - UV.y;                               // 0 底 → 1 顶
	float along = smoothstep(0.0, along_in, u) * (1.0 - smoothstep(along_out, 1.0, u));
	float center = mix(center_lo, center_hi, u);         // 越往下风越往上翘
	float halfw = 0.16 + 0.14 * u;
	float dv = (vv - center) / halfw;
	float across = exp(-dv * dv);
	float a = wisp * along * across;
	float tree_front = 1.0 - smoothstep(tree_depth - 0.5, tree_depth + 0.5, depth);
	float tree_in = max(in_rect(tn, trunk_tan, mask_soft_tan), in_ellipse(tn, crown_tan, mask_soft_tan));
	float zs = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, zs, 1.0);
	float scene_d = -vp.z / vp.w;
	float soft = clamp((scene_d - depth) / soft_fade_u, 0.0, 1.0);
	ALBEDO = spray_color;
	ALPHA = clamp(a * COLOR.a * (1.0 - tree_front * tree_in) * soft, 0.0, 1.0);
	AO = ambient_ao;
	AO_LIGHT_AFFECT = 0.0;
}

void light() {
	float c = dot(-VIEW, LIGHT);
	float ph = pow(clamp(0.5 + 0.5 * c, 0.0, 1.0), scatter_power);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (ph * scatter + wrap_diffuse) / PI;
}
