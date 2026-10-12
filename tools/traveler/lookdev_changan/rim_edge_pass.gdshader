shader_type spatial;
// rim 线 · 屏幕空间深度差金边（长安日暮探针）。挂在 atlas_surface 材质 / 佛窟山崖 / 远景雪山的 next_pass 上，加色混合。
// 思路：每个像素朝"太阳在屏幕上的方向"挪 rim_width_px 个像素取深度；如果那边明显更远（天空、远山、背后的地面），
// 这个像素就是朝阳一侧的轮廓边 → 加一条细金边。宽度按像素算，所以低多边形的平面不会整片发亮，只描轮廓。
// 金边写在 light() 里、乘 ATTENUATION：处在太阳阴影里（佛窟山、房子背后）的轮廓不出金边；只认太阳，不认灯笼 / 冷补光。
// 这是透明队列里的加色 pass：保留硬件深度测试（被挡住的像素早剔除，省填充），顶点在视空间朝相机推 depth_push（默认 0.2%），
// 保证与主 pass 同一表面稳定通过深度测试、不 z-fight；风动代码与 atlas_surface 相同，参数由 changan_extra_rim.gd 每帧从主材质同步。
render_mode blend_add, cull_disabled, depth_draw_never, fog_disabled, ambient_light_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear, repeat_disable;   // 线性采样：轮廓处深度渐变，金边边缘不锯齿

// 与 atlas_surface 相同的风动（主材质同步过来）
uniform float wind_amp = 0.0;
uniform float wind_stiff = 1.6;
uniform float wind_gust = 1.0;
uniform vec2 wind_dir = vec2(1.0, 0.38);
uniform float anim_t = -1.0;
uniform vec4 base_color : source_color = vec4(1.0);
uniform float brightness = 1.02;
uniform bool use_vertex_color = true;

uniform vec3 sun_dir_world = vec3(-0.91, 0.24, -0.33);
uniform vec3 rim_tint : source_color = vec3(1.0, 0.95, 0.8);
uniform float rim_strength = 1.5;
uniform float rim_albedo_mix = 0.3;       // 0 = 纯光色，1 = 乘物体颜色（红叶描红金、黄叶描黄金）
uniform float rim_width_px = 3.0;         // 1080p 下的像素宽度（按 VIEWPORT_SIZE.y/1080 缩放）
uniform float width_ref_dist = 10.0;      // 这个距离上宽度 = rim_width_px；更近更粗、更远更细
uniform float width_min_scale = 0.6;
uniform float width_max_scale = 1.6;
uniform float gap_lo = 0.06;              // 相对深度差阈值（邻点比自己远多少算"边"）
uniform float gap_hi = 0.25;
uniform float depth_push = 0.002;         // 视空间朝相机推的比例（防 z-fight）
uniform float cull_dist = 1000000.0;     // 物体（实例）原点离相机超过它就整个退化掉不画（远处植被省顶点 / 光栅）；地形材质不要设
uniform float back_min = 0.0;             // dot(L, 视线)：越逆光越亮
uniform float back_max = 0.7;
uniform float side_min = -0.35;           // 法线与太阳夹角：允许侧背面也亮一点（轮廓边常是掠射面）
uniform float side_max = 0.25;
uniform float up_start = 1.5;             // 世界法线 y 超过它开始压（>1 = 关）
uniform float up_end = 1.6;
uniform float fade_start = 30.0;          // 离相机距离（u）
uniform float fade_end = 120.0;
uniform float fade_min = 0.35;

varying float v_edge;
varying vec3 v_alb;

float lin_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

void vertex() {
	if (wind_amp > 0.0) {
		float t = anim_t < 0.0 ? TIME : anim_t;
		vec3  o = MODEL_MATRIX[3].xyz;
		float phase = o.x * 0.72 + o.z * 0.63;
		float pj  = INSTANCE_CUSTOM.r * 6.2831853;
		float amp = wind_amp * (INSTANCE_CUSTOM.g <= 0.0 ? 1.0 : INSTANCE_CUSTOM.g);
		float gr  = (INSTANCE_CUSTOM.b <= 0.0 ? 1.0 : INSTANCE_CUSTOM.b);
		float gust = 1.0 + (wind_gust - 1.0) * gr;
		float lever = pow(max(VERTEX.y, 0.0), wind_stiff);
		float move  = (sin(t * 1.1 + phase + pj) + 0.4 * sin(t * 1.8 + (phase + pj) * 1.6)) * amp * gust * lever;
		VERTEX.x += move * wind_dir.x;
		VERTEX.z += move * wind_dir.y;
	}
	vec4 vpos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vpos.xyz *= (1.0 - depth_push);
	POSITION = PROJECTION_MATRIX * vpos;
	if (length(MODEL_MATRIX[3].xyz - CAMERA_POSITION_WORLD) > cull_dist) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);   // 同一实例的所有顶点落在同一点、裁剪体外 → 三角形退化，不进光栅
	}
}

void fragment() {
	NORMAL = normalize(NORMAL) * (FRONT_FACING ? 1.0 : -1.0);
	ALBEDO = vec3(0.0);
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	float my = -VERTEX.z;
	float fade = mix(1.0, fade_min, smoothstep(fade_start, fade_end, my));
	float edge = 0.0;
	if (fade > 0.001) {
		// 太阳在屏幕上的位置（方向向量投影；Godot 的 PROJECTION_MATRIX 已与 SCREEN_UV 对齐）
		vec4 sc = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(sun_dir_world, 0.0));
		vec2 sun_px = (sc.xy / sc.w * 0.5 + 0.5) * VIEWPORT_SIZE;
		vec2 dir = normalize(sun_px - FRAGCOORD.xy) * sign(sc.w);
		float w = rim_width_px * (VIEWPORT_SIZE.y / 1080.0) * clamp(width_ref_dist / my, width_min_scale, width_max_scale);
		float gap = 0.0;
		for (int i = 1; i <= 3; i++) {
			vec2 uv = (FRAGCOORD.xy + dir * w * float(i) / 3.0) / VIEWPORT_SIZE;
			if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) continue;
			gap = max(gap, (lin_depth(uv, INV_PROJECTION_MATRIX) - my) / my);
		}
		edge = smoothstep(gap_lo, gap_hi, gap);
		if (up_start <= 1.0) {
			float n_up = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y;
			edge *= 1.0 - smoothstep(up_start, up_end, n_up);
		}
		edge *= fade;
	}
	v_edge = edge;
	if (edge < 0.001) {
		discard;   // 不是轮廓的像素直接丢，省掉整套阴影 / 光照计算
	}
	vec3 alb = (use_vertex_color ? max(COLOR.rgb, vec3(0.0)) : vec3(1.0)) * base_color.rgb * brightness;
	v_alb = alb;
}

void light() {
	if (v_edge > 0.001 && LIGHT_IS_DIRECTIONAL) {
		vec3 sun_v = normalize((VIEW_MATRIX * vec4(sun_dir_world, 0.0)).xyz);
		if (dot(LIGHT, sun_v) > 0.985) {
			float back = smoothstep(back_min, back_max, dot(LIGHT, -VIEW));
			float side = smoothstep(side_min, side_max, dot(NORMAL, LIGHT));
			vec3 col = mix(rim_tint, rim_tint * v_alb * 2.0, rim_albedo_mix);
			SPECULAR_LIGHT += LIGHT_COLOR / PI * col * rim_strength * v_edge * back * side * ATTENUATION;
		}
	}
}
