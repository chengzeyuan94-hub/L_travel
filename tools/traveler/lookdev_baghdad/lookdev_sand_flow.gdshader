shader_type spatial;
// sand / 贴地流沙细丝 + 空中细沙闪光 的绘制（look-dev 探针，不是交付代码）。
// 面片沿风向（UV.x：0 上风 → 1 下风），UV.y：0 上 → 1 下。
// 流沙：面片里 1–2 根细丝 + 一层极淡的沙纱；丝上的"沙粒断续"按世界坐标沿风向滚动（比面片本身跑得快）。
// 闪光：胶囊形小点，按粒子种子错相位，偶尔亮一下。
// 光照：自定义 light() —— 前向散射相位（看向太阳时亮），ATTENUATION 带阴影（树影里的沙丝自然暗）。
// 透明、depth_draw_never；读深度做软粒子；雾、景深走引擎默认。
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);
uniform vec3 flow_color : source_color = vec3(1.0, 0.84, 0.6);
uniform vec3 glint_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float flow_quad_px = 10.0;
uniform float fil_width_px = 0.9;
uniform float fil_sep_px = 3.2;
uniform float fil_wiggle_px = 1.1;
uniform float sheet_alpha = 0.12;
uniform float tex_speed = 1.0;        // u/s：丝里的颗粒图案沿风向跑的速度
uniform float tex_freq = 4.0;         // 每 u 多少段
uniform float scatter_flow = 1.0;
uniform float scatter_glint = 3.0;
uniform float scatter_power = 8.0;
uniform float wrap_diffuse = 0.08;
uniform float ambient_ao = 0.45;
uniform float soft_fade_u = 0.12;
uniform float near_fade_depth = 4.5;
uniform vec4 corridor = vec4(-1.7, 1.7, -10.0, 7.2);  // 世界 x0, x1, z0, z1
uniform float corridor_soft = 0.5;
uniform vec4 trunk_tan = vec4(0.0);    // 视空间正切坐标 x0, y0, x1, y1（树干）
uniform vec4 crown_tan = vec4(0.0);    // 树冠包围盒 → 椭圆
uniform float tree_depth = 11.0;       // 比它近的片元才需要让开树
uniform float mask_soft_tan = 0.008;
uniform float twinkle_rate = 2.2;
uniform float twinkle_sharp = 14.0;
uniform float twinkle_floor = 0.12;
uniform float grain_freq = 11.0;       // 每 u 多少颗"沙团"——让丝断成颗粒，不像一道光
uniform float grain_amount = 0.6;
uniform vec2 glint_bg = vec2(1.5, 5.0);  // 闪光只在身后近处有沙面时出现（背后是远山/天空会被景深糊成光斑，直接不画）

varying float v_type;
varying float v_seed;
varying float v_aspect;
varying vec3 v_world;
varying float v_scatter;

float h11(float x) {
	return fract(sin(x * 127.1 + 11.7) * 43758.5453);
}

float vnoise(float x) {
	float i = floor(x);
	float f = fract(x);
	float u = f * f * (3.0 - 2.0 * f);
	return mix(h11(i), h11(i + 1.0), u);
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
	v_type = INSTANCE_CUSTOM.x;
	v_seed = INSTANCE_CUSTOM.z;
	float lu = length(MODEL_MATRIX[0].xyz);
	float hu = length(MODEL_MATRIX[1].xyz);
	v_aspect = lu / max(hu, 1e-5);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 wp = v_world;
	float depth = -VERTEX.z;
	vec2 tn = VERTEX.xy / max(depth, 1e-4);
	float a = 0.0;
	if (v_type < 0.5) {
		float s = dot(wp.xz, wind_dir.xz);
		float ph = (s - TIME * tex_speed) * tex_freq + v_seed * 91.0;
		float y_px = (0.5 - UV.y) * flow_quad_px;
		float wig = fil_wiggle_px * sin(ph * 0.9 + v_seed * 40.0);
		float aa = max(fwidth(y_px), 1e-3);
		float we = max(fil_width_px, aa * 0.9);
		float kw = fil_width_px / we;
		float d1 = (y_px - (-0.5 * fil_sep_px + wig)) / we;
		float d2 = (y_px - (0.5 * fil_sep_px + wig * 0.6)) / we;
		float f1 = exp(-d1 * d1) * kw;
		float f2 = exp(-d2 * d2) * kw;
		float g1 = smoothstep(0.35, 0.85, vnoise(ph));
		float g2 = smoothstep(0.45, 0.9, vnoise(ph * 1.37 + 17.0 + v_seed * 13.0));
		float sy = y_px / (flow_quad_px * 0.32);
		float sheet = exp(-sy * sy) * (0.5 + 0.5 * vnoise(ph * 0.35 + 5.0));
		float along = smoothstep(0.0, 0.3, UV.x) * (1.0 - smoothstep(0.7, 1.0, UV.x));
		float pg = (s - TIME * tex_speed * 1.25) * grain_freq + v_seed * 53.0;
		float grain = smoothstep(0.25, 0.75, vnoise(pg)) * (0.6 + 0.4 * vnoise(pg * 2.3 + 9.0));
		a = ((f1 * g1 + 0.7 * f2 * g2) * mix(1.0, grain, grain_amount) + sheet_alpha * sheet) * along;
		v_scatter = scatter_flow;
		ALBEDO = flow_color * COLOR.rgb;
	} else {
		vec2 q = (UV - 0.5) * vec2(v_aspect, 1.0);
		float half_len = max(v_aspect * 0.5 - 0.5, 0.0);
		q.x = max(abs(q.x) - half_len, 0.0);
		float d = length(q) * 2.0;
		float dot_a = exp(-d * d * 3.0);
		float tw = pow(max(sin(TIME * twinkle_rate * (0.7 + 0.6 * v_seed) + v_seed * 60.0), 0.0), twinkle_sharp);
		a = dot_a * (twinkle_floor + (1.0 - twinkle_floor) * tw);
		v_scatter = scatter_glint * (0.4 + 2.5 * tw);
		ALBEDO = glint_color;
	}
	// 让开：路/营地走廊、近景、树（只在树前面时）
	float corr = in_rect(wp.xz, corridor, corridor_soft);
	float near_ok = smoothstep(near_fade_depth, near_fade_depth + 0.8, depth);
	float tree_front = 1.0 - smoothstep(tree_depth - 0.5, tree_depth + 0.5, depth);
	float tree_in = max(in_rect(tn, trunk_tan, mask_soft_tan), in_ellipse(tn, crown_tan, mask_soft_tan));
	float mask = (1.0 - corr) * near_ok * (1.0 - tree_front * tree_in);
	// 软粒子
	float zs = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, zs, 1.0);
	float scene_d = -vp.z / vp.w;
	float soft = clamp((scene_d - depth) / soft_fade_u, 0.0, 1.0);
	if (v_type > 0.5) {
		soft *= 1.0 - smoothstep(glint_bg.x, glint_bg.y, scene_d - depth);
	}
	ALPHA = clamp(a * COLOR.a * mask * soft, 0.0, 1.0);
	AO = ambient_ao;
	AO_LIGHT_AFFECT = 0.0;
}

void light() {
	float c = dot(-VIEW, LIGHT);
	float ph = pow(clamp(0.5 + 0.5 * c, 0.0, 1.0), scatter_power);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (ph * v_scatter + wrap_diffuse) / PI;
}
