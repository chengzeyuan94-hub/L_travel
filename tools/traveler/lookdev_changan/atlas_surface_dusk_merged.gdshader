shader_type spatial;
// 【合并版 2026-09-23】= 反光线副本 + 轮廓光线 [rim+] + 地面线 [ground key]，由导演合并。
// 长安日暮探针版地表着色器：由 shaders/traveler/atlas_surface.gdshader 复制（uniform 全兼容，风动顶点代码原样），
// 另加三个默认关闭的口子：
//   1. 轮廓光（rim_*）：写在 light() 里，乘 ATTENUATION，所以被山、房子挡住的地方不会亮边。
//   2. 暗部反光（bounce_*）：背光面、朝下 / 朝侧的面接一点地面暖反光和天光冷反光（间接光，不受阴影）。
//   3. 地面细节（ground_*）：只作用在朝上的平面（地面），世界坐标噪声做色斑和颗粒，近处强、远处淡。
// 因为定义了 light()，漫反射由这里按 Godot 的 lambert_wrap 公式复刻（LIGHT_COLOR 已含 π，除回去）。
// ==== [bounce] 反光线在此副本上新增（全部默认关闭，默认值下与 atlas_surface_dusk.gdshader 一致）====
//   2b. bounce_floor：不看朝向的一层冷天光反光，抬起落在阴影里的朝阳面。
//   2a'. bounce_up_cut：朝上的面（地面）不接 2 / 2b，反光只落在树冠侧面 / 底面、墙、石头、崖面上。
//   2c. lamp_bounce_*：寺庙院子被暖灯照亮的地面，把暖光反到附近的墙脚、台阶、灯柱、树冠底（按离院心的水平距离和离地高度衰减，朝上的面不接）。
//   4.  glaze_*：琉璃瓦（深蓝青顶点色）+ 金饰（金黄顶点色）高光。只在 glaze_enable=1 的材质（extra 脚本只给寺庙那块 Atlas_solid 打开）、
//       且 glaze_center 半径内生效：fragment 里加一层按反射方向取色的"天光/夕阳"反射（菲涅尔），light() 里加太阳的 Blinn 高光（乘 ATTENUATION）。
//   标了 [bounce] 的段落是新增，其余与母版一致。
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
// [rim+] 新增
uniform float sun_wrap = -1.0;            // [rim+] 太阳单独 wrap；<0 = 关
uniform float rim_up_start = 1.5;         // [rim+] 世界法线 y 超过它开始压金边；>1 = 关
uniform float rim_up_end = 1.6;           // [rim+] 到这里金边压到 0
uniform float rim_sun_only = 0.0;         // [rim+] 1 = 只有太阳出金边
uniform float rim_facet_sharp = 0.0;      // [rim+] 0 = 原样；0..1 = 原菲涅尔与阈值化菲涅尔的混合权重
uniform float rim_facet_lo = 0.15;        // [rim+] 阈值化下限
uniform float rim_facet_hi = 0.55;        // [rim+] 阈值化上限
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
// ---- [bounce] 新增 uniform ----
// 2b. 冷天光底
uniform float bounce_floor = 0.0;
// 2a'. 朝上的面（地面、树冠顶）不接 2 / 2b 的反光：地面自己不该被"地面反光"再抬一遍，也不和地面细节线抢地面明暗
uniform float bounce_up_cut = 0.0;
uniform float bounce_up_lo = 0.62;
uniform float bounce_up_hi = 0.85;
// 2c. 灯下暖反光
uniform float lamp_bounce_strength = 0.0;
uniform vec3 lamp_bounce_pos = vec3(0.0);          // 院心（世界坐标，extra 脚本按寺庙位置 + 朝相机方向算好写入）
uniform float lamp_bounce_radius = 2.2;           // 水平衰减半径（u）
uniform float lamp_bounce_height = 0.6;           // 离地多高以内接反光（u）
uniform vec3 lamp_bounce_color : source_color = vec3(1.0, 0.58, 0.28);
// 4. 琉璃瓦 / 金饰高光
uniform float glaze_enable = 0.0;                 // 只在寺庙材质上被 extra 脚本设 1
uniform vec3 glaze_center = vec3(0.0);
uniform float glaze_radius = 3.0;
uniform float glaze_roughness = 0.45;             // 引擎自身天空反射用的粗糙度（仅瓦面）
uniform float glaze_specular = 0.5;
uniform float glaze_sun_spec = 0.0;               // 太阳 Blinn 高光强度
uniform float glaze_shininess = 18.0;
uniform vec3 glaze_spec_tint : source_color = vec3(1.0, 0.82, 0.66);
uniform float glaze_sky_strength = 0.0;           // 反射天光强度（emission，不受阴影）
uniform float glaze_f0 = 0.12;
uniform float glaze_fresnel_power = 4.0;
uniform vec3 glaze_sky_horizon : source_color = vec3(0.95, 0.52, 0.46);
uniform vec3 glaze_sky_zenith : source_color = vec3(0.20, 0.24, 0.52);
uniform vec3 glaze_sky_sun : source_color = vec3(1.0, 0.66, 0.38);
uniform float glaze_sky_sun_power = 5.0;
uniform float glaze_sky_curve = 0.8;               // 反射方向仰角到多少时完全是天顶色（越大，地平线的粉紫越多）
uniform float glaze_gold_spec = 0.0;              // 金饰（屋脊、檐口金边）太阳高光
uniform float glaze_gold_shininess = 10.0;
varying float v_glaze;
varying float v_gold;
// ---- [bounce] 新增结束 ----

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
		// [bounce] 2a'. 朝上的面减掉
		float upcut = 1.0 - bounce_up_cut * smoothstep(bounce_up_lo, bounce_up_hi, n_world.y);
		emit += ALBEDO * b * away * bounce_strength * upcut;
	}
	// [bounce] 2b. 冷天光底：不看太阳朝向，朝上越多越多（抬阴影里的朝阳面）
	if (bounce_floor > 0.0) {
		float upcut2 = 1.0 - bounce_up_cut * smoothstep(bounce_up_lo, bounce_up_hi, n_world.y);
		emit += ALBEDO * bounce_sky_color * (0.4 + 0.6 * clamp(n_world.y, 0.0, 1.0)) * bounce_floor * upcut2;
	}
	// [bounce] 2c. 灯下暖反光
	if (lamp_bounce_strength > 0.0) {
		float dh = length(v_world.xz - lamp_bounce_pos.xz);
		float fall = 1.0 - smoothstep(0.0, lamp_bounce_radius, dh);
		fall *= fall;
		float hgt = 1.0 - smoothstep(0.0, lamp_bounce_height, v_world.y - lamp_bounce_pos.y);
		float notup = 1.0 - smoothstep(0.35, 0.85, n_world.y);
		emit += ALBEDO * lamp_bounce_color * fall * hgt * notup * lamp_bounce_strength;
	}
	// [bounce] 4. 琉璃瓦 / 金饰遮罩（按原始顶点色，不受 brightness / 地面细节影响）
	v_glaze = 0.0;
	v_gold = 0.0;
	float glaze_rough = roughness;
	float glaze_specamt = 0.18;
	if (glaze_enable > 0.5) {
		float inside = 1.0 - smoothstep(glaze_radius * 0.85, glaze_radius, length(v_world - glaze_center));
		vec3 c = max(COLOR.rgb, vec3(0.0));
		float mx = max(c.r, max(c.g, c.b));
		// 深蓝青瓦：b 明显大于 r、b 不小于 g、整体很暗
		float teal = smoothstep(0.36, 0.46, (c.b - c.r) / max(c.b, 1e-4)) * smoothstep(0.80, 0.92, c.b / max(c.g, 1e-4)) * (1.0 - smoothstep(0.20, 0.30, mx));
		// 金饰：g/r 0.55–0.72、b 很少、中等亮度
		float gr = c.g / max(c.r, 1e-4);
		float gold = smoothstep(0.53, 0.58, gr) * (1.0 - smoothstep(0.70, 0.75, gr)) * (1.0 - smoothstep(0.26, 0.32, c.b / max(c.r, 1e-4))) * smoothstep(0.36, 0.42, mx) * (1.0 - smoothstep(0.62, 0.70, mx));
		v_glaze = teal * inside;
		v_gold = gold * inside;
		glaze_rough = mix(roughness, glaze_roughness, v_glaze);
		glaze_specamt = mix(0.18, glaze_specular, v_glaze);
		if (glaze_sky_strength > 0.0 && v_glaze > 0.001) {
			vec3 vw = normalize(CAMERA_POSITION_WORLD - v_world);
			vec3 r = reflect(-vw, n_world);
			float up = clamp(r.y, 0.0, 1.0);
			vec3 sky = mix(glaze_sky_horizon, glaze_sky_zenith, smoothstep(0.0, glaze_sky_curve, up));
			vec2 sd = normalize(sun_dir_world.xz + vec2(1e-5));
			vec2 rd = normalize(r.xz + vec2(1e-5));
			float sunward = pow(max(dot(sd, rd), 0.0), glaze_sky_sun_power) * (1.0 - smoothstep(0.15, 0.85, up));
			sky += glaze_sky_sun * sunward;
			sky *= smoothstep(-0.25, 0.05, r.y);   // 反射到地面的方向不给天光
			float ndv = clamp(dot(n_world, vw), 0.0, 1.0);
			float fres = glaze_f0 + (1.0 - glaze_f0) * pow(1.0 - ndv, glaze_fresnel_power);
			emit += sky * fres * glaze_sky_strength * v_glaze;
		}
	}
	EMISSION = emit;
	ROUGHNESS = glaze_rough;
	METALLIC = 0.0;
	SPECULAR = glaze_specamt;
}

void light() {
	float r = wrap_follows_roughness ? roughness : wrap;
	// [rim+] 太阳单独 wrap（平行光）；点光（灯笼、佛窟背光）不受影响
	if (sun_wrap >= 0.0 && LIGHT_IS_DIRECTIONAL) {
		vec3 sun_vw = normalize((VIEW_MATRIX * vec4(sun_dir_world, 0.0)).xyz);
		if (dot(LIGHT, sun_vw) > 0.985) {
			r = sun_wrap;   // 只有太阳用硬一点的明暗交界；冷补光等其他平行光仍用原 wrap（软）
		}
	}
	float ndl = dot(NORMAL, LIGHT);
	float wrapped = max(0.0, (ndl + r) / ((1.0 + r) * (1.0 + r)));
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * wrapped / PI;
	if (rim_strength > 0.0 && (rim_directional_only < 0.5 || LIGHT_IS_DIRECTIONAL)) {
		// [rim+] 只认太阳
		float is_sun = 1.0;
		if (rim_sun_only > 0.5) {
			vec3 sun_v = normalize((VIEW_MATRIX * vec4(sun_dir_world, 0.0)).xyz);
			is_sun = step(0.985, dot(LIGHT, sun_v));
		}
		float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
		// [rim+] 低多边形边面阈值化
		if (rim_facet_sharp > 0.0) {
			fres = mix(fres, smoothstep(rim_facet_lo, rim_facet_hi, fres), clamp(rim_facet_sharp, 0.0, 1.0));
		}
		float back = smoothstep(rim_back_min, rim_back_max, dot(LIGHT, -VIEW));
		float side = smoothstep(rim_side_min, rim_side_max, ndl);
		// [rim+] 朝上的面（地面）压掉金边
		float up_w = 1.0;
		if (rim_up_start <= 1.0) {
			float n_up = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y;
			up_w = 1.0 - smoothstep(rim_up_start, rim_up_end, n_up);
		}
		vec3 rim_col = mix(rim_tint, rim_tint * ALBEDO * 2.0, rim_albedo_mix);
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * rim_col * fres * back * side * up_w * is_sun * rim_strength / PI;
	}
	// [bounce] 4. 琉璃瓦 / 金饰的太阳高光（只太阳；乘 ATTENUATION，阴影里不闪）
	if (LIGHT_IS_DIRECTIONAL && (v_glaze + v_gold) > 0.001) {
		vec3 h = normalize(LIGHT + VIEW);
		float ndh = max(dot(NORMAL, h), 0.0);
		float lit = smoothstep(-0.05, 0.25, ndl);
		vec3 s = glaze_spec_tint * pow(ndh, glaze_shininess) * glaze_sun_spec * v_glaze
			+ mix(vec3(1.0), ALBEDO * 2.2, 0.7) * pow(ndh, glaze_gold_shininess) * glaze_gold_spec * v_gold;
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * s * lit / PI;
	}
}
