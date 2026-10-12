shader_type spatial;
// [ground key 副本 2026-09-23] 由 atlas_surface_dusk.gdshader 复制；只新增「地面细节 v2」一块（搜 "[ground key"），
// 其余代码（rim_* / bounce_* / 原 ground_*）一字未改。合并时把三段 [ground key] 标记之间的内容搬进合并版即可。
// 长安日暮探针版地表着色器：由 shaders/traveler/atlas_surface.gdshader 复制（uniform 全兼容，风动顶点代码原样），
// 另加三个默认关闭的口子：
//   1. 轮廓光（rim_*）：写在 light() 里，乘 ATTENUATION，所以被山、房子挡住的地方不会亮边。
//   2. 暗部反光（bounce_*）：背光面、朝下 / 朝侧的面接一点地面暖反光和天光冷反光（间接光，不受阴影）。
//   3. 地面细节（ground_*）：只作用在朝上的平面（地面），世界坐标噪声做色斑和颗粒，近处强、远处淡。
// 因为定义了 light()，漫反射由这里按 Godot 的 lambert_wrap 公式复刻（LIGHT_COLOR 已含 π，除回去）。
render_mode cull_disabled;

uniform vec4 base_color : source_color = vec4(1.0);
uniform float night_amount : hint_range(0.0, 1.0) = 0.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 0.0;
uniform float brightness : hint_range(0.0, 3.0) = 1.02;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform float rock_tint_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 rock_tint_color : source_color = vec3(0.62, 0.55, 0.44);
uniform float wind_amp   : hint_range(0.0, 0.30) = 0.0;
uniform float wind_stiff : hint_range(0.5, 3.0)  = 1.6;
uniform float wind_gust                          = 1.0;
uniform vec2  wind_dir                           = vec2(1.0, 0.38);
uniform float anim_t                             = -1.0;

// ---- 探针新增 ----
uniform vec3 sun_dir_world = vec3(-0.91, 0.24, -0.33);   // 指向太阳（overlay 设置）
uniform float wrap = 0.95;                // lambert wrap 系数；原版等于 roughness
uniform bool wrap_follows_roughness = true;
// 1. 轮廓光
uniform float rim_strength = 0.0;
uniform float rim_power = 3.0;
uniform float rim_back_min = -0.2;        // 视线与光线夹角：背光时 dot(L,-V)>0 更亮
uniform float rim_back_max = 0.6;
uniform float rim_side_min = -0.1;        // 法线朝光的程度，避免整面亮
uniform float rim_side_max = 0.45;
uniform vec3 rim_tint : source_color = vec3(1.0, 0.78, 0.5);
uniform float rim_albedo_mix = 0.35;      // 0 = 纯光色边，1 = 乘物体颜色
uniform float rim_directional_only = 1.0; // 1 = 只有平行光（太阳）产生轮廓光
// 2. 暗部反光
uniform float bounce_strength = 0.0;
uniform vec3 bounce_ground_color : source_color = vec3(1.0, 0.62, 0.36);
uniform vec3 bounce_sky_color : source_color = vec3(0.45, 0.5, 0.85);
uniform float bounce_sky_mix = 0.35;
// 3. 地面细节
uniform float ground_detail = 0.0;
uniform float ground_up_min = 0.72;
uniform float ground_fade_start = 18.0;   // 离相机的距离（u）
uniform float ground_fade_end = 60.0;
uniform float ground_macro_scale = 0.35;
uniform float ground_macro_amount = 0.22;
uniform vec3 ground_warm : source_color = vec3(1.06, 0.95, 0.80);
uniform vec3 ground_cool : source_color = vec3(0.86, 0.90, 1.00);
uniform float ground_grain_scale = 9.0;
uniform float ground_grain_amount = 0.10;
uniform float ground_streak_amount = 0.0;
uniform vec2 ground_streak_dir = vec2(1.0, 0.38);
uniform float ground_streak_scale = 2.5;
// ==== [ground key 2026-09-23] 地面细节 v2（秋天土地）——新增 uniform，默认 0 = 关，与原版逐像素一致 ====
// 只应该打开在 Atlas_terrain 材质上（changan_extra_ground.gd 只给地形材质设值；其他材质保持 0）。
// 颜色倍率都是普通 vec3（不带 source_color），直接乘在线性反照率上。
uniform float ground_v2 = 0.0;                    // 总强度
uniform float ground_v2_up_min = 0.55;            // 法线 y 低于此值（陡坡 / 崖壁）不做
uniform float ground_v2_fade_start = 14.0;        // 色斑开始淡出（离相机，u）
uniform float ground_v2_fade_end = 40.0;
uniform float ground_v2_far_keep = 0.3;           // 远处色斑保留比例（颗粒完全淡出，色斑留一点）
uniform float ground_patch_scale = 0.30;          // 色斑频率（1/u）
uniform float ground_patch_amount = 0.75;
uniform float ground_patch_warp = 1.2;            // 域扭曲：让色斑边缘不规则
uniform vec3 ground_ochre = vec3(1.28, 1.02, 0.62);   // 枯草土黄
uniform vec3 ground_green = vec3(0.80, 0.98, 0.95);   // 灰绿
uniform vec3 ground_rust = vec3(1.18, 0.74, 0.52);    // 赭石 / 落叶堆
uniform float ground_rust_amount = 0.8;
uniform vec3 ground_warm_mul = vec3(1.06, 1.0, 0.92); // 大尺度暖冷交替
uniform vec3 ground_cool_mul = vec3(0.90, 0.95, 1.08);
uniform float ground_facet_jitter = 0.06;         // 每个低多边形面的明度抖动
uniform float ground_fine_fade_start = 9.0;       // 颗粒 / 碎叶斑开始淡出
uniform float ground_fine_fade_end = 22.0;
uniform float ground_clod_scale = 6.5;            // 土块（Voronoi 多边形，1/u）
uniform float ground_clod_amount = 0.10;
uniform float ground_clod_edge = 0.10;            // 土块缝隙压暗
uniform float ground_grain2_scale = 21.0;         // 细颗粒（Voronoi，1/u）
uniform float ground_grain2_amount = 0.07;
uniform float ground_leaf_density = 0.10;         // 土块里被染成落叶色的比例（赭石斑里加倍）
uniform float ground_leaf_mix = 0.75;
uniform vec3 ground_leaf_a = vec3(0.56, 0.12, 0.03);  // 线性反照率：红
uniform vec3 ground_leaf_b = vec3(0.72, 0.45, 0.07);  // 线性反照率：金
uniform vec4 ground_clear_rect = vec4(0.0);       // 院子留白：世界 xz 矩形 (xmin, zmin, xmax, zmax)；全 0 = 不启用
uniform float ground_clear_soft = 0.12;           // 留白边缘过渡（u）
// ==== [ground key] 新增 uniform 结束 ====

varying vec3 v_world;
varying float v_upness;
varying float v_cam_dist;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float noise21(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0)), f.x), f.y);
}
float fbm3(vec2 p) {
	return noise21(p) * 0.57 + noise21(p * 2.07 + 11.3) * 0.29 + noise21(p * 4.13 + 5.7) * 0.14;
}
// [ground key] Voronoi：返回 (最近点距离 F1, F2-F1, 格子 id 的 hash)，格子 id 另存 cell
vec3 voronoi2(vec2 p, out vec2 cell) {
	vec2 i = floor(p), f = fract(p);
	float d1 = 8.0, d2 = 8.0;
	vec2 best = vec2(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = vec2(hash21(i + g), hash21(i + g + 17.17));
			vec2 r = g + o * 0.85 + 0.075 - f;
			float d = dot(r, r);
			if (d < d1) { d2 = d1; d1 = d; best = i + g; }
			else if (d < d2) { d2 = d; }
		}
	}
	cell = best;
	d1 = sqrt(d1); d2 = sqrt(d2);
	return vec3(d1, d2 - d1, hash21(best + 3.7));
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
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_cam_dist = length(v_world - CAMERA_POSITION_WORLD);
}

void fragment() {
	NORMAL = normalize(NORMAL) * (FRONT_FACING ? 1.0 : -1.0);
	vec3 albedo = max(COLOR.rgb, vec3(0.0)) * base_color.rgb * brightness;
	float luma = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	float sat = max(max(albedo.r, albedo.g), albedo.b) - min(min(albedo.r, albedo.g), albedo.b);
	float pale = smoothstep(0.26, 0.60, luma) * (1.0 - smoothstep(0.03, 0.20, sat));
	albedo = mix(albedo, rock_tint_color * (0.72 + 0.5 * luma), pale * rock_tint_amount);

	vec3 n_world = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// 3. 地面细节
	if (ground_detail > 0.0) {
		float up = smoothstep(ground_up_min, ground_up_min + 0.12, n_world.y);
		float fade = 1.0 - smoothstep(ground_fade_start, ground_fade_end, v_cam_dist);
		float w = up * fade * ground_detail;
		if (w > 0.001) {
			vec2 p = v_world.xz;
			float macro = fbm3(p * ground_macro_scale);
			vec3 tint = mix(ground_cool, ground_warm, smoothstep(0.3, 0.7, macro));
			vec3 a2 = albedo * mix(vec3(1.0), tint, ground_macro_amount);
			vec2 gp = p * ground_grain_scale;
			float g = hash21(floor(gp)) * 0.6 + hash21(floor(gp * 2.3 + 7.0)) * 0.4;
			a2 *= 1.0 + (g - 0.5) * 2.0 * ground_grain_amount;
			if (ground_streak_amount > 0.0) {
				vec2 d = normalize(ground_streak_dir);
				float along = dot(p, d), across = dot(p, vec2(-d.y, d.x));
				float st = fbm3(vec2(along * 0.25, across * ground_streak_scale));
				a2 *= 1.0 + (st - 0.5) * 2.0 * ground_streak_amount;
			}
			albedo = mix(albedo, a2, w);
		}
	}
	// ==== [ground key 2026-09-23] 地面细节 v2：秋天色斑 + 低多边形面抖动 + 土块 / 细颗粒 / 碎叶斑 ====
	if (ground_v2 > 0.0) {
		float up2 = smoothstep(ground_v2_up_min, ground_v2_up_min + 0.15, n_world.y);
		float fade2 = 1.0 - smoothstep(ground_v2_fade_start, ground_v2_fade_end, v_cam_dist);
		float clear2 = 1.0;
		if (ground_clear_rect.z > ground_clear_rect.x) {
			// 长安城底板在寺庙台阶前有一条露出地形的缺口（灯下院子）：这里不做色斑 / 颗粒，保持干净
			vec2 dlo = v_world.xz - ground_clear_rect.xy;
			vec2 dhi = ground_clear_rect.zw - v_world.xz;
			float inside = min(min(dlo.x, dlo.y), min(dhi.x, dhi.y));
			clear2 = 1.0 - smoothstep(-ground_clear_soft, 0.0, inside);
		}
		float w_patch = up2 * ground_v2 * clear2 * mix(ground_v2_far_keep, 1.0, fade2);
		float w_fine = up2 * ground_v2 * clear2 * (1.0 - smoothstep(ground_fine_fade_start, ground_fine_fade_end, v_cam_dist));
		if (w_patch > 0.001) {
			vec2 p2 = v_world.xz;
			vec2 q = p2 * ground_patch_scale;
			q += (vec2(fbm3(q * 0.7 + 3.1), fbm3(q * 0.7 + 8.7)) - 0.5) * 2.0 * ground_patch_warp;
			float m1 = fbm3(q);                       // 枯草土黄 ↔ 灰绿
			float m2 = fbm3(q * 1.7 + 21.3);          // 赭石落叶堆
			vec3 tint = mix(ground_green, ground_ochre, smoothstep(0.36, 0.62, m1));
			float rust_w = smoothstep(0.52, 0.70, m2) * ground_rust_amount;
			tint = mix(tint, ground_rust, rust_w);
			float wc = fbm3(p2 * ground_patch_scale * 0.42 + 40.0);
			tint *= mix(ground_cool_mul, ground_warm_mul, smoothstep(0.34, 0.66, wc));
			// 平面法线 → 每个面一个随机数（地形是平面着色，同一面法线恒定）
			float fh = hash21(floor(n_world.xz * 331.0) + floor(n_world.y * 173.0));
			tint *= 1.0 + (fh - 0.5) * 2.0 * ground_facet_jitter;
			vec3 a3 = albedo * mix(vec3(1.0), tint, ground_patch_amount);
			albedo = mix(albedo, a3, w_patch);
			if (w_fine > 0.001) {
				vec2 cid;
				vec3 vc = voronoi2(p2 * ground_clod_scale, cid);
				float hb = vc.z;
				vec3 fine = albedo * (1.0 + (hb - 0.5) * 2.0 * ground_clod_amount);
				fine *= 1.0 - ground_clod_edge * (1.0 - smoothstep(0.0, 0.07, vc.y));
				vec2 cid2;
				vec3 vg = voronoi2(p2 * ground_grain2_scale + 5.3, cid2);
				fine *= 1.0 + (vg.z - 0.5) * 2.0 * ground_grain2_amount;
				// 碎叶斑：稀疏的细颗粒格染成落叶色（格子小 = 碎叶，不是色块），赭石斑里更多
				float leaf_p = ground_leaf_density * (0.5 + 1.5 * rust_w);
				if (hash21(cid2 + 41.3) < leaf_p) {
					vec3 lc = mix(ground_leaf_a, ground_leaf_b, hash21(cid2 + 7.9));
					float lm = ground_leaf_mix * smoothstep(0.02, 0.18, vg.y) * (1.0 - smoothstep(0.25, 0.45, vg.x));
					fine = mix(fine, lc * (0.85 + 0.3 * hb), lm);
				}
				albedo = mix(albedo, fine, w_fine);
			}
		}
	}
	// ==== [ground key] 地面细节 v2 结束 ====

	vec3 night_tint = mix(vec3(1.0), vec3(0.72, 0.82, 1.18), night_amount * 0.38);
	ALBEDO = albedo * night_tint;
	vec3 emit = ALBEDO * emission_strength * (1.0 + night_amount * 3.8);
	// 2. 暗部反光：背光面 + 朝下 / 朝侧面接地面暖反光；朝上的背光面接天光冷反光
	if (bounce_strength > 0.0) {
		float away = clamp(-dot(n_world, normalize(sun_dir_world)) * 0.5 + 0.5, 0.0, 1.0);
		away = smoothstep(0.45, 1.0, away);
		float down = clamp(0.5 - 0.5 * n_world.y, 0.0, 1.0);
		vec3 b = mix(bounce_ground_color * (0.35 + 0.65 * down), bounce_sky_color * clamp(n_world.y, 0.0, 1.0), bounce_sky_mix);
		emit += ALBEDO * b * away * bounce_strength;
	}
	EMISSION = emit;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.18;
}

void light() {
	float r = wrap_follows_roughness ? roughness : wrap;
	float ndl = dot(NORMAL, LIGHT);
	float wrapped = max(0.0, (ndl + r) / ((1.0 + r) * (1.0 + r)));
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * wrapped / PI;
	if (rim_strength > 0.0 && (rim_directional_only < 0.5 || LIGHT_IS_DIRECTIONAL)) {
		float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
		float back = smoothstep(rim_back_min, rim_back_max, dot(LIGHT, -VIEW));
		float side = smoothstep(rim_side_min, rim_side_max, ndl);
		vec3 rim_col = mix(rim_tint, rim_tint * ALBEDO * 2.0, rim_albedo_mix);
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * rim_col * fres * back * side * rim_strength / PI;
	}
}
