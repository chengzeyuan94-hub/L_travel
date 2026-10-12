shader_type spatial;
// Panti light polish · screen-space depth-edge rim (castle / rocks / camp props).
// Ported 1:1 from the approved probe (tools/traveler/lookdev_panti/r1_rim_edge.gdshader, variant m4_final).
// Additive next_pass on the original material. Each fragment steps a few pixels toward the main light on screen and
// compares depth: a clearly farther neighbour means a light-facing silhouette edge. 3 samples averaged (1, 2/3, 1/3
// graded profile, profile_soft = 1). Non-edge fragments are discarded.
// Main-light gate: light() only accepts the directional light whose direction matches sun_dir_world (dot > main_gate),
// synced from Daylight by panti_rim_light.gd; the warm-bounce directional fills never draw an edge. Multiplied by
// ATTENUATION, so shadowed edges stay dark. Colour = main-light hue (max-channel normalised) x rim_tint; brightness =
// rim_strength (not light energy), so the transition can hold it on a straight line.
// ALBEDO 0 + ambient_light_disabled + SPECULAR 0: only SPECULAR_LIGHT from light() is added.
render_mode blend_add, cull_back, depth_draw_never, fog_disabled, ambient_light_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear, repeat_disable;

// —— 随时段变化（panti_light_polish.json 的 morning / midnight，按过渡权重插值）——
uniform vec3 rim_tint : source_color = vec3(1.0, 0.9, 0.7);
uniform float rim_strength = 1.5;
uniform float back_min = -0.4;           // dot(L, 视线)：越逆光越亮；清晨侧光要放宽，深夜月亮在相机身后要更宽
uniform float back_max = 0.6;
uniform float back_floor = 0.25;         // 顺光处保留的比例（0 = 纯逆光才有边）
uniform float side_min = -0.35;          // dot(N, L)：轮廓边常是掠射面，允许侧背面也亮一点
uniform float side_max = 0.25;
uniform float screen_up_mix = 0.0;       // 0 = 朝主光的屏幕方向找边，1 = 朝屏幕上方找边（深夜：月光落在树尖 / 垛口 / 石顶）
uniform float period_w = 0.0;            // 0 = 清晨，1 = 深夜（按过渡权重插值），用来在 gain_day / gain_night 之间混合
uniform float up_boost = 0.0;            // 朝上的面（垛口顶、岩石顶）额外加亮（深夜"月光落在顶上"）

// —— 每个材质固定（panti_rim_light.gd 按物体类别设置）——
uniform vec3 sun_dir_world = vec3(-0.8, 0.3, 0.5);   // 指向主光（panti_rim_light.gd 从 Daylight 同步）
uniform float gain_day = 1.0;            // 物体类别增益（清晨 / 深夜各一个）
uniform float gain_night = 1.0;
uniform float rim_width_px = 3.0;        // 1080p 下的像素宽度
uniform float width_ref_dist = 12.0;     // 这个距离上宽度 = rim_width_px；更近更粗、更远更细
uniform float width_min_scale = 0.6;
uniform float width_max_scale = 1.6;
uniform float gap_lo = 0.06;             // 相对深度差阈值（邻点比自己远多少算"边"）
uniform float gap_hi = 0.25;
uniform float depth_push = 0.002;        // 视空间朝相机推的比例（防 z-fight）
uniform float fade_start = 20.0;         // 离相机距离（u），跟着雾一起淡
uniform float fade_end = 60.0;
uniform float fade_min = 0.25;

uniform float profile_soft = 1.0;        // 0 = 取最大值硬边，1 = 命中数平均的渐变边
uniform float main_gate = 0.995;         // dot(LIGHT, 主光方向) 超过它才算主光
varying float v_edge;
varying vec3 v_main_dir;

float lin_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

void vertex() {
	vec4 vpos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vpos.xyz *= (1.0 - depth_push);
	POSITION = PROJECTION_MATRIX * vpos;
}

void fragment() {
	ALBEDO = vec3(0.0);
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	float my = -VERTEX.z;
	float fade = mix(1.0, fade_min, smoothstep(fade_start, fade_end, my));
	vec4 sc = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(sun_dir_world, 0.0));
	vec2 sun_px = (sc.xy / sc.w * 0.5 + 0.5) * VIEWPORT_SIZE;
	vec2 dir = normalize(sun_px - FRAGCOORD.xy) * sign(sc.w);
	if (screen_up_mix > 0.0) {
		vec4 su = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0));
		vec2 up_px = (su.xy / su.w * 0.5 + 0.5) * VIEWPORT_SIZE;
		vec2 dir_up = normalize(up_px - FRAGCOORD.xy) * sign(su.w);
		dir = normalize(mix(dir, dir_up, screen_up_mix));
	}
	float w = rim_width_px * (VIEWPORT_SIZE.y / 1080.0) * clamp(width_ref_dist / my, width_min_scale, width_max_scale);
	float gap = 0.0;
	float acc = 0.0;
	for (int i = 1; i <= 3; i++) {
		vec2 uv = (FRAGCOORD.xy + dir * w * float(i) / 3.0) / VIEWPORT_SIZE;
		if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) continue;
		float g = (lin_depth(uv, INV_PROJECTION_MATRIX) - my) / my;
		gap = max(gap, g);
		acc += smoothstep(gap_lo, gap_hi, g);
	}
	float prof = mix(smoothstep(gap_lo, gap_hi, gap), acc / 3.0, profile_soft);
	float edge = prof * fade * mix(gain_day, gain_night, period_w);
	v_edge = edge;
	v_main_dir = normalize((VIEW_MATRIX * vec4(sun_dir_world, 0.0)).xyz);
	if (edge < 0.001) {
		discard;
	}
}

void light() {
	if (v_edge > 0.001 && LIGHT_IS_DIRECTIONAL && dot(LIGHT, v_main_dir) > main_gate) {
		float back = mix(back_floor, 1.0, smoothstep(back_min, back_max, dot(LIGHT, -VIEW)));
		float ndl = dot(NORMAL, LIGHT);
		float side = smoothstep(side_min, side_max, ndl);
		float n_up = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y;
		float up = 1.0 + up_boost * smoothstep(0.3, 0.9, n_up);
		// 只取主光的色相（最大通道归一），亮度由 rim_strength 决定：过渡时 rim_strength 线性插值，边光不会因为
		// "强度 × 光能量" 两个线性量相乘而在中间帧鼓包 / 跳变。
		vec3 hue = LIGHT_COLOR / max(max(LIGHT_COLOR.r, LIGHT_COLOR.g), max(LIGHT_COLOR.b, 0.0001));
		SPECULAR_LIGHT += hue * rim_tint * rim_strength * v_edge * back * side * up * ATTENUATION;
	}
}
