// r3 copy of a_rim_edge.gdshader (A line) with one change: light() gated to the main light only.
shader_type spatial;
// A 线（光与轮廓）· 盘橐 · 屏幕空间深度差轮廓光 pass（城堡 / 岩石 / 营地道具）。挂在原材质 next_pass 上，加色混合。
// 思路（参考 tools/traveler/lookdev_changan/rim_edge_pass.gdshader）：每个像素朝"主光（太阳 / 月亮）在屏幕上的方向"
// 挪几个像素取深度；那边明显更远（天空、背后的树林、背后的雪地）→ 这个像素是朝光一侧的轮廓边 → 加一条细边。
// 宽度按像素算，所以低多边形刻面不会整片发亮，只描轮廓。
// 只认平行光（盘橐只有一盏：Daylight，清晨是太阳、深夜是月亮），乘 ATTENUATION：阴影里的轮廓不出边。
// 颜色 = 主光色相 × rim_tint，亮度 = rim_strength（不乘光能量）：过渡时太阳颜色在变，边的颜色跟着平滑走；rim_tint / rim_strength 由 variant 按时段插值。
// ALBEDO=0 + ambient_light_disabled + SPECULAR=0：不吃环境光 / 反射，只有 light() 写的 SPECULAR_LIGHT 被加上去。
render_mode blend_add, cull_back, depth_draw_never, fog_disabled, ambient_light_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear, repeat_disable;

// —— 随时段变化（variant 的 morning / midnight 两节写，watcher 插值）——
uniform vec3 rim_tint : source_color = vec3(1.0, 0.9, 0.7);
uniform float rim_strength = 1.5;
uniform float back_min = -0.4;           // dot(L, 视线)：越逆光越亮；清晨侧光要放宽，深夜月亮在相机身后要更宽
uniform float back_max = 0.6;
uniform float back_floor = 0.25;         // 顺光处保留的比例（0 = 纯逆光才有边）
uniform float side_min = -0.35;          // dot(N, L)：轮廓边常是掠射面，允许侧背面也亮一点
uniform float side_max = 0.25;
uniform float screen_up_mix = 0.0;       // 0 = 朝主光的屏幕方向找边，1 = 朝屏幕上方找边（深夜：月光落在树尖 / 垛口 / 石顶）
uniform float period_w = 0.0;            // 0 = 清晨，1 = 深夜（watcher 插值），用来在 gain_day / gain_night 之间混合
uniform float up_boost = 0.0;            // 朝上的面（垛口顶、岩石顶）额外加亮（深夜"月光落在顶上"）

// —— 每个材质固定（extra 脚本按物体类别设置）——
uniform vec3 sun_dir_world = vec3(-0.8, 0.3, 0.5);   // 指向主光（a_rim_sync 每帧从 Daylight 同步）
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

varying float v_edge;

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
	for (int i = 1; i <= 3; i++) {
		vec2 uv = (FRAGCOORD.xy + dir * w * float(i) / 3.0) / VIEWPORT_SIZE;
		if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) continue;
		gap = max(gap, (lin_depth(uv, INV_PROJECTION_MATRIX) - my) / my);
	}
	float edge = smoothstep(gap_lo, gap_hi, gap) * fade * mix(gain_day, gain_night, period_w);
	v_edge = edge;
	if (edge < 0.001) {
		discard;
	}
}

void light() {
	// r3 gate: only the main light (Daylight, whose direction is synced into sun_dir_world) draws the rim.
	// C's extra DirectionalLight3D bounces (C_BounceCamp / C_BounceCastle) otherwise add a second full-strength rim,
	// because the rim is hue-only and ignores the light's energy.
	vec3 sun_v = normalize((VIEW_MATRIX * vec4(sun_dir_world, 0.0)).xyz);
	if (v_edge > 0.001 && LIGHT_IS_DIRECTIONAL && dot(LIGHT, sun_v) > 0.995) {
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
