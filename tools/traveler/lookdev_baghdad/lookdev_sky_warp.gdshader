shader_type sky;

// c_warp 探针（2026-09-23）：
//   云 = 透视映射 (u, v) = (az·v, 1/(el+floor)) 上的域扭曲 fbm + billow 絮状细节 + 软排（row）加性调制，
//        往地平线方向自然变薄变密；朝太阳方向再采一次密度得到底部金光 / 顶部暗面 / 金边。
//   天空 = 取景窗内以到太阳的角距离为主变量：近日橙黄 → 桃粉过渡 → 远日蔚蓝，外加整圈地平线暖霾与天顶偏蓝；
//          取景窗外渐变回 v22 的三段暖天，保住场景环境光。
//   只用 EYEDIR，无 TIME，无额外 pass。日盘 / 光晕沿用基线代码；云盖在日盘之上，薄云处透光。
//   每像素噪声采样：每层 6(扭曲) + 7(主体) + 7(朝阳) = 20，两层 40。

// ---- 基线兼容键：v22 三段渐变（只用于取景窗以外的天球 → 保住场景的环境光 / 反射）、地面、日盘、光晕 ----
uniform vec3 zenith_color : source_color = vec3(0.30, 0.26, 0.54);
uniform vec3 mid_color : source_color = vec3(0.86, 0.44, 0.40);
uniform float mid_height = 0.18;
uniform vec3 horizon_color : source_color = vec3(1.0, 0.60, 0.24);
uniform float horizon_falloff = 0.20;
uniform vec3 ground_bottom_color : source_color = vec3(0.22, 0.14, 0.18);
uniform vec3 ground_horizon_color : source_color = vec3(0.80, 0.44, 0.24);
uniform float sky_energy = 1.0;
uniform vec3 sun_direction = vec3(-0.28, 0.15, 0.95);
uniform vec3 sun_disc_color : source_color = vec3(1.0, 0.92, 0.72);
uniform float sun_disc_energy = 3.4;
uniform float sun_radius_deg = 1.0;
uniform float sun_edge_deg = 0.025;
uniform float sun_halo_radius_deg = 14.0;
uniform float sun_halo_strength = 0.5;

// ---- 取景窗：窗内用新的近橙远蓝渐变，窗外（相机看不到的天球）渐变回 v22 的紫粉暖天，
//      这样天空辐射图对场景的环境光 / 反射几乎不变（c_warp3 实测：整球变蓝会把拱门和地面染成粉灰）----
uniform float view_center_az = 0.0;    // 相机朝向的方位角（弧度）
uniform float view_half_az = 0.42;     // 窗半宽（可见 ±0.32）
uniform float view_fade_az = 0.35;
uniform float view_top_el = 0.62;      // 窗顶（可见 0.53）
uniform float view_fade_el = 0.30;

// ---- 天空渐变：主变量 = 到太阳的角距离（度） ----
uniform vec3 sky_sun_color : source_color = vec3(1.0, 0.92, 0.66);   // 贴近太阳：黄白
uniform vec3 sky_warm_color : source_color = vec3(1.0, 0.72, 0.36);  // 近日半边：橙黄
uniform vec3 sky_mid_color : source_color = vec3(0.97, 0.66, 0.58);  // 过渡：桃粉
uniform vec3 sky_blue_color : source_color = vec3(0.40, 0.62, 0.90); // 远日半边：蔚蓝
uniform float sky_sun_deg = 7.0;    // 黄白圈半径
uniform float sky_warm_deg = 12.0;  // ≤ 此角距为橙黄
uniform float sky_mid_deg = 22.0;   // 过渡中点（桃粉）
uniform float sky_blue_deg = 32.0;  // ≥ 此角距为蔚蓝
uniform vec3 haze_near_color : source_color = vec3(1.0, 0.62, 0.30); // 近日侧地平线暖霾
uniform vec3 haze_far_color : source_color = vec3(0.94, 0.58, 0.50);  // 远日侧地平线暖霾（橙粉）
uniform float haze_strength = 0.9;
uniform float haze_falloff = 0.12;       // 暖霾随仰角衰减（弧度）
uniform float zenith_blue_boost = 0.30;  // 远日半边随仰角再往蓝推
uniform float zenith_el_start = 0.22;
uniform float zenith_el_end = 0.55;

// ---- 云：公共 ----
uniform float cumulus_enabled = 1.0;
uniform float cloud_el_floor = 0.20;       // 透视映射 v = 1/(el + floor)：floor 越小，地平线处压得越密
uniform float cloud_lod_px = 0.00065;      // 每像素弧度（0.53 rad / 812 px），按仰角淡出高频八度防颗粒
uniform float cloud_warp_freq = 0.7;       // 域扭曲噪声频率（相对主体）
uniform float cloud_warp_amp = 0.55;       // 域扭曲幅度（噪声单位）
uniform float cloud_detail_freq = 3.0;     // billow 絮状细节频率（第二档 ×2.3）
uniform float cloud_detail_amp = 0.22;
uniform float cloud_row_freq = 2.0;        // 每 v 单位几排（排间距在屏幕上随仰角透视变化）
uniform float cloud_row_strength = 0.45;   // 排调制强度（0 = 无排）
uniform float cloud_contrast = 2.2;        // fbm 值域拉伸
uniform float cloud_edge_soft = 0.16;      // 云边软硬
uniform float cloud_rim_step = 0.10;       // 朝太阳采样步长（噪声单位）
uniform float cloud_shade_softness = 1.2;  // 朝阳面 / 背阳面过渡
uniform float cloud_core_darkening = 0.45; // 云心压暗
uniform float cloud_sun_clear = 0.45;      // 日盘 ~3° 内云的最大不透明度比例
uniform float cloud_sun_sigma_deg = 30.0;  // 近日金橙 → 远日粉紫 的角距离尺度
uniform float cloud_prox_floor = 0.35;     // 远日云保留的金边比例
uniform float cloud_underglow = 0.30;      // 低仰角云整体染暖霾
uniform vec3 cloud_lit_near : source_color = vec3(1.0, 0.84, 0.54);   // 底部受光（近日：金黄）
uniform vec3 cloud_lit_far : source_color = vec3(0.96, 0.70, 0.66);   // 底部受光（远日：粉）
uniform vec3 cloud_shadow_near : source_color = vec3(0.62, 0.34, 0.28); // 顶部 / 云心（近日：暗橙棕）
uniform vec3 cloud_shadow_far : source_color = vec3(0.55, 0.42, 0.58);  // 顶部 / 云心（远日：紫灰）
uniform vec3 cloud_rim_color : source_color = vec3(1.0, 0.85, 0.42);
uniform float cloud_rim_strength = 2.0;

// ---- 云 B：主层，低、厚，仰角 0.05…0.45 ----
uniform vec2 cloud_b_scale = vec2(1.8, 3.0);      // (横向 u 缩放, 纵向 v 缩放)；v 大于 u = 横向拉长
uniform vec2 cloud_b_offset = vec2(11.3, 2.9);
uniform float cloud_b_coverage_low = 0.55;        // 低仰角覆盖率
uniform float cloud_b_coverage_high = 0.36;       // 高仰角覆盖率（越高越稀）
uniform float cloud_b_alpha = 0.95;
uniform float cloud_b_el_in0 = 0.05;
uniform float cloud_b_el_in1 = 0.10;
uniform float cloud_b_el_out0 = 0.40;
uniform float cloud_b_el_out1 = 0.56;

// ---- 云 A：高层，小、稀，仰角 0.22 以上 ----
uniform vec2 cloud_a_scale = vec2(2.6, 4.5);
uniform vec2 cloud_a_offset = vec2(3.1, 7.7);
uniform float cloud_a_coverage_low = 0.32;
uniform float cloud_a_coverage_high = 0.22;
uniform float cloud_a_alpha = 0.75;
uniform float cloud_a_el_in0 = 0.20;
uniform float cloud_a_el_in1 = 0.32;
uniform float cloud_a_el_out0 = 0.62;
uniform float cloud_a_el_out1 = 0.80;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise21(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0)), f.x), f.y);
}

// 3 八度：域扭曲用（低频）
float fbm3(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * noise21(p);
		p = p * 2.02 + vec2(13.7, 5.9);
		a *= 0.5;
	}
	return v;
}

// 5 八度，带像素足迹 LOD：某八度一周期小于 ~4 px 时淡出，低仰角不出颗粒
float fbm5_lod(vec2 p, float fp) {
	float v = 0.0;
	float a = 0.5;
	float f = 1.0;
	for (int i = 0; i < 5; i++) {
		float w = a * (1.0 - smoothstep(0.10, 0.28, f * fp));
		v += w * noise21(p);
		p = p * 2.02 + vec2(13.7, 5.9);
		a *= 0.5;
		f *= 2.02;
	}
	return v;
}

float billow(vec2 p) {
	return abs(2.0 * noise21(p) - 1.0);
}

// 云形：扭曲后的坐标 q → 主体 fbm + 两档 billow 絮状（圆鼓鼓的棉絮边）+ 软排（加性）调制，输出 0..1
float cloud_shape(vec2 q, float fp, float row_v) {
	float d = fbm5_lod(q, fp);
	float w1 = cloud_detail_amp * (1.0 - smoothstep(0.10, 0.28, cloud_detail_freq * fp));
	float w2 = cloud_detail_amp * 0.45 * (1.0 - smoothstep(0.10, 0.28, cloud_detail_freq * 2.3 * fp));
	d += (billow(q * cloud_detail_freq + vec2(4.2, 9.1)) - 0.5) * w1;
	d += (billow(q * cloud_detail_freq * 2.3 + vec2(1.7, 3.3)) - 0.5) * w2;
	d = clamp((d - 0.5) * cloud_contrast + 0.5, 0.0, 1.0);
	float rows = cos(row_v * cloud_row_freq * TAU);
	return clamp(d + rows * cloud_row_strength * 0.5, 0.0, 1.0);
}

// 一层云。az/el：该像素方位角 / 仰角；angle：到太阳角距离；返回 rgb + alpha
vec4 cloud_layer(float az, float el, float angle, vec2 scale, vec2 offset,
		float cov_lo, float cov_hi, float layer_alpha,
		float el_in0, float el_in1, float el_out0, float el_out1,
		float sun_az, float sun_el, float sun_prox, float underglow_w, vec3 under_col) {
	if (el < el_in0 || el > el_out1 + 0.10) {
		return vec4(0.0);
	}
	float v = 1.0 / (el + cloud_el_floor);
	float u = az * v;
	vec2 p = vec2(u * scale.x, v * scale.y) + offset;
	float fp = scale.y * v * v * cloud_lod_px;
	// 域扭曲：低频 fbm 推挤采样坐标 → 卷曲、棉絮毛边
	vec2 wp = p * cloud_warp_freq;
	vec2 warp = (vec2(fbm3(wp + vec2(3.1, 7.7)), fbm3(wp + vec2(-5.2, 1.9))) - 0.5) * cloud_warp_amp;
	vec2 q = p + warp;
	float row_v = (q.y - offset.y) / scale.y;
	float d = cloud_shape(q, fp, row_v);
	float t_el = smoothstep(el_in1, el_out0, el);
	float lo = 1.0 - mix(cov_lo, cov_hi, t_el);
	// 上下边界都用密度打散，避免直线接缝
	float fade_in = smoothstep(el_in0, el_in1, el + (d - 0.5) * 0.06);
	float fade_out = 1.0 - smoothstep(el_out0, el_out1, el - (d - 0.5) * 0.25);
	float dens = smoothstep(lo, lo + cloud_edge_soft, d) * fade_in * fade_out;
	// 日盘附近不让云盖死
	float clear = smoothstep(radians(4.0), radians(1.2), angle);
	dens *= 1.0 - clear * (1.0 - cloud_sun_clear);
	if (dens <= 0.002) {
		return vec4(0.0);
	}
	// 朝太阳再采一次：密度朝太阳下降的一面 = 受光面（底边金光、金边），上升的一面 = 背光面（顶部暗）
	float v_s = 1.0 / (sun_el + cloud_el_floor);
	float u_s = sun_az * v_s;
	vec2 to_sun = normalize(vec2((u_s - u) * scale.x, (v_s - v) * scale.y) + vec2(1e-4, 0.0));
	vec2 qs = q + to_sun * cloud_rim_step;
	float d_sun = cloud_shape(qs, fp, (qs.y - offset.y) / scale.y);
	float slope = (d - d_sun) / max(cloud_rim_step, 0.001);
	float sun_side = smoothstep(-cloud_shade_softness, cloud_shade_softness, slope);
	float core = smoothstep(lo + 0.06, lo + 0.34, d);
	vec3 lit = mix(cloud_lit_far, cloud_lit_near, sun_prox);
	vec3 shd = mix(cloud_shadow_far, cloud_shadow_near, sun_prox);
	vec3 body = mix(shd, lit, sun_side);
	body = mix(body, shd, core * cloud_core_darkening);
	body = mix(body, under_col, underglow_w);
	float thin = 1.0 - smoothstep(0.05, 0.50, dens);
	float rim = thin * sun_side * sun_side * (cloud_prox_floor + (1.0 - cloud_prox_floor) * sun_prox);
	vec3 col = body + cloud_rim_color * rim * cloud_rim_strength;
	return vec4(col, dens * layer_alpha);
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	float elevation = asin(clamp(direction.y, -1.0, 1.0));
	float azimuth = atan(direction.x, direction.z);
	float el_up = max(elevation, 0.0);
	vec3 sun_n = normalize(sun_direction);
	float sun_dot = clamp(dot(direction, sun_n), -1.0, 1.0);
	float angle = acos(sun_dot);
	float ang_deg = degrees(angle);

	// ---- 取景窗内：近日橙黄 → 桃粉 → 远日蔚蓝（按角距离），再加天顶偏蓝与地平线暖霾 ----
	float t_warm = smoothstep(sky_warm_deg, sky_mid_deg, ang_deg);
	float t_blue = smoothstep(sky_mid_deg, sky_blue_deg, ang_deg);
	vec3 vis = mix(sky_warm_color, sky_mid_color, t_warm);
	vis = mix(vis, sky_blue_color, t_blue);
	vis = mix(sky_sun_color, vis, smoothstep(sky_sun_deg * 0.4, sky_sun_deg * 1.6, ang_deg));
	float far_w = smoothstep(sky_warm_deg, sky_blue_deg, ang_deg);
	float zen = zenith_blue_boost * smoothstep(zenith_el_start, zenith_el_end, el_up) * far_w;
	vis = mix(vis, sky_blue_color, zen);
	vec3 haze_col = mix(haze_near_color, haze_far_color, far_w);
	float haze_w = haze_strength * exp(-el_up / max(haze_falloff, 0.01));
	vis = mix(vis, haze_col, haze_w);
	// ---- 取景窗外：v22 三段渐变（环境光来源） ----
	float warm_weight = exp(-el_up / max(horizon_falloff, 0.01));
	float upper = smoothstep(mid_height, mid_height + 0.45, el_up);
	vec3 amb = mix(mid_color, zenith_color, upper);
	amb = mix(amb, horizon_color, warm_weight);
	float daz = abs(azimuth - view_center_az);
	daz = min(daz, TAU - daz);
	float w_view = (1.0 - smoothstep(view_half_az, view_half_az + view_fade_az, daz))
		* (1.0 - smoothstep(view_top_el, view_top_el + view_fade_el, el_up));
	vec3 color = mix(amb, vis, w_view);
	vec3 ground = mix(ground_horizon_color, ground_bottom_color, smoothstep(0.0, 0.7, -direction.y));
	color = mix(ground, color, smoothstep(-0.035, 0.015, direction.y));

	// ---- 太阳盘 + 光晕（先画，云再盖上去，薄云处透光） ----
	float radius = radians(sun_radius_deg);
	float edge = radians(sun_edge_deg);
	float disk = smoothstep(cos(radius + edge), cos(max(radius - edge, 0.00001)), sun_dot);
	float halo = exp(-pow(angle / radians(max(sun_halo_radius_deg, 0.01)), 2.0));
	color += sun_disc_color * halo * sun_halo_strength;
	color = mix(color, sun_disc_color * sun_disc_energy, disk);

	// ---- 云 ----
	if (cumulus_enabled > 0.5) {
		float sun_prox = exp(-pow(angle / radians(max(cloud_sun_sigma_deg, 1.0)), 2.0));
		float underglow_w = cloud_underglow * (1.0 - smoothstep(0.05, 0.35, direction.y));
		float sun_el = asin(clamp(sun_n.y, -1.0, 1.0));
		float sun_az = atan(sun_n.x, sun_n.z);
		vec4 a = cloud_layer(azimuth, elevation, angle, cloud_a_scale, cloud_a_offset,
			cloud_a_coverage_low, cloud_a_coverage_high, cloud_a_alpha,
			cloud_a_el_in0, cloud_a_el_in1, cloud_a_el_out0, cloud_a_el_out1,
			sun_az, sun_el, sun_prox, underglow_w * 0.5, haze_col);
		color = mix(color, a.rgb, a.a);
		vec4 b = cloud_layer(azimuth, elevation, angle, cloud_b_scale, cloud_b_offset,
			cloud_b_coverage_low, cloud_b_coverage_high, cloud_b_alpha,
			cloud_b_el_in0, cloud_b_el_in1, cloud_b_el_out0, cloud_b_el_out1,
			sun_az, sun_el, sun_prox, underglow_w, haze_col);
		color = mix(color, b.rgb, b.a);
	}
	COLOR = color * sky_energy;
}
