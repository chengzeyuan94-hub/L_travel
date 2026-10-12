shader_type spatial;
// A 线（光与轮廓）· 盘橐雪松 · 屏幕空间深度差轮廓光 pass。挂在 panti_tree_wind 材质（SnowCedars_*）的 next_pass 上，加色混合。
// 风动：vertex() 前半段逐字复制自 shaders/traveler/panti/panti_tree_wind.gdshader（原样保留），风参数由 a_extra_rim.gd
// 在挂载时从主材质拷贝，anim_t / wind_enabled 由 a_rim_sync.gd 每帧同步 → 金边与树梢同步摆动，不会与主 pass 错位。
// 之后多一步：视空间朝相机推 depth_push，保证与主 pass 同一表面稳定通过深度测试、不 z-fight。
// 其余同 a_rim_edge.gdshader：朝主光方向挪几个像素比深度，背后更远 → 轮廓边；只认平行光、乘 ATTENUATION。
render_mode world_vertex_coords, cull_disabled, blend_add, depth_draw_never, fog_disabled, ambient_light_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear, repeat_disable;

// —— 风动（与 panti_tree_wind.gdshader 同名同默认，挂载时从主材质拷贝）——
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform bool wind_enabled = true;
uniform float anim_t = 0.0;
uniform vec3 wind_world = vec3(-1.0, 0.0, 0.0);
uniform float mesh_bottom_y = 0.0;
uniform float mesh_height = 1.0;
uniform float tip_displacement_ratio = 0.011;
uniform float gust_period_s = 10.0;
uniform float sway_period_s = 9.6;
uniform float gust_weight = 0.72;
uniform float rest_bend_ratio = 0.18;
uniform float bend_exponent = 1.8;
uniform float root_lock_fraction = 0.02;
uniform float crown_ripple_ratio = 0.12;
uniform float crown_layers = 3.0;

// —— 随时段变化（variant 的 morning / midnight 两节写，watcher 插值）——
uniform vec3 rim_tint : source_color = vec3(1.0, 0.9, 0.7);
uniform float rim_strength = 1.5;
uniform float back_min = -0.4;
uniform float back_max = 0.6;
uniform float back_floor = 0.25;
uniform float side_min = -0.35;
uniform float side_max = 0.25;
uniform float screen_up_mix = 0.0;       // 0 = 朝主光的屏幕方向找边，1 = 朝屏幕上方找边（深夜：月光落在树尖 / 垛口 / 石顶）
uniform float period_w = 0.0;            // 0 = 清晨，1 = 深夜（watcher 插值），用来在 gain_day / gain_night 之间混合
uniform float up_boost = 0.0;            // 朝上的面（雪松枝层上的积雪、树尖）额外加亮

// —— 每个材质固定（extra 脚本按树的层级设置）——
uniform vec3 sun_dir_world = vec3(-0.8, 0.3, 0.5);
uniform float gain_day = 1.0;            // 物体类别增益（清晨 / 深夜各一个）
uniform float gain_night = 1.0;
uniform float rim_width_px = 3.0;
uniform float width_ref_dist = 14.0;
uniform float width_min_scale = 0.6;
uniform float width_max_scale = 1.6;
uniform float gap_lo = 0.06;
uniform float gap_hi = 0.25;
uniform float depth_push = 0.002;
uniform float fade_start = 22.0;
uniform float fade_end = 60.0;
uniform float fade_min = 0.25;

varying float v_edge;

float lin_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

void vertex() {
	// ==== 以下逐字复制自 panti_tree_wind.gdshader 的 vertex() ====
	UV = UV * uv_scale + uv_offset;
	if (wind_enabled) {
		// MODEL_MATRIX includes the MultiMesh instance. World-space motion keeps
		// separately scaled heights/crowns and arbitrary tree yaw from changing
		// the shared screen-right-to-left wind direction.
		vec3 axis_y = MODEL_MATRIX[1].xyz;
		float axis_scale = max(length(axis_y), 0.000001);
		vec3 tree_up = axis_y / axis_scale;
		vec3 root = (MODEL_MATRIX * vec4(0.0, mesh_bottom_y, 0.0, 1.0)).xyz;
		float height_world = max(mesh_height * axis_scale, 0.000001);
		float h = clamp(dot(VERTEX - root, tree_up) / height_world, 0.0, 1.0);
		float u = clamp((h - root_lock_fraction) / (1.0 - root_lock_fraction), 0.0, 1.0);
		float strength = max(INSTANCE_CUSTOM.g, 0.0);
		float rate = max(INSTANCE_CUSTOM.b, 0.01);
		float phase = INSTANCE_CUSTOM.r * 6.28318530718 + dot(root.xz, vec2(0.17, 0.11));
		float shared_gust = 0.5 + 0.5 * sin(anim_t * 6.28318530718 / gust_period_s);
		float local_angle = anim_t * 6.28318530718 * rate / sway_period_s;
		float individual_sway = 0.5 + 0.5 * sin(local_angle + phase);
		float wind_strength = rest_bend_ratio + (1.0 - rest_bend_ratio) *
			mix(individual_sway, shared_gust, gust_weight);
		float trunk_bend = pow(u, bend_exponent) * wind_strength;
		// A small smooth wave through successive canopy levels. Its envelope is
		// zero at both root and tip, keeping the configured tip budget explicit.
		float crown_envelope = 4.0 * u * u * (1.0 - u) * (1.0 - u);
		float crown_bend = crown_ripple_ratio * crown_envelope *
			sin(local_angle * 0.73 + phase + u * crown_layers * 6.28318530718);
		float displacement = height_world * tip_displacement_ratio * strength * (trunk_bend + crown_bend);
		VERTEX += wind_world * displacement;
	}
	// ==== 复制结束。A 线新增：朝相机推一点，防 z-fight ====
	vec4 vpos = VIEW_MATRIX * vec4(VERTEX, 1.0);
	vpos.xyz *= (1.0 - depth_push);
	POSITION = PROJECTION_MATRIX * vpos;
}

void fragment() {
	// 与主 shader 相同：用视空间位置的导数重算刻面法线（风动后刻面不被抹平）
	vec3 face_normal = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (dot(face_normal, NORMAL) < 0.0) {
		face_normal = -face_normal;
	}
	NORMAL = face_normal;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
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
	if (v_edge > 0.001 && LIGHT_IS_DIRECTIONAL) {
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
