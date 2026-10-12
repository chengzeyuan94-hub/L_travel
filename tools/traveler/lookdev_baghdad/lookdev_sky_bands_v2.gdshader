shader_type sky;

// c_bands v2（2026-09-23，导演在 Carlos 看中的 c_bands 版本上加：更多带 + 半透明远层）
// 原：c_bands（2026-09-23）：对着 Carlos 参考图做的"横向絮状分带云 + 近日橙黄/远日蔚蓝"天空。
// 由 lookdev_sunset_sky.gdshader 复制而来：日盘 / 光晕 / 地面代码原样保留，
// 天空渐变改成"以到太阳角距离为主变量"，云改成 4–6 条显式水平云带。
// 依旧只用 EYEDIR，无 TIME，无额外 pass。每像素噪声采样：每条带 10 次（起伏 1 + 断裂 1 + fbm4×2），
// 一个像素最多落在 3 条带的范围内，≤ 30 次。

// ---- 基线保留的 uniform（日盘 / 光晕 / 地面） ----
uniform vec3 zenith_color : source_color = vec3(0.30, 0.50, 0.84);   // 远日、高仰角的蔚蓝
uniform vec3 horizon_color : source_color = vec3(1.0, 0.66, 0.30);   // 近日地平线暖霾
uniform vec3 ground_bottom_color : source_color = vec3(0.478, 0.373, 0.294);
uniform vec3 ground_horizon_color : source_color = vec3(0.827, 0.612, 0.396);
uniform float horizon_falloff = 0.14;
uniform float sky_energy = 1.0;
uniform vec3 sun_direction = vec3(-0.26, 0.12, 0.96);
uniform vec3 sun_disc_color : source_color = vec3(1.0, 0.96, 0.76);
uniform float sun_disc_energy = 2.6;
uniform float sun_radius_deg = 1.08;
uniform float sun_edge_deg = 0.025;
uniform float sun_halo_radius_deg = 5.2;
uniform float sun_halo_strength = 0.24;
// 基线兼容键（配方 / 旧 variant 会设到，这里不参与计算）
uniform vec3 cloud_color : source_color = vec3(0.93, 0.73, 0.52);
uniform float cloud_opacity = 0.0;
uniform float cloud_seed = 29.0;
uniform float cloud_coverage = 0.42;
uniform vec3 mid_color : source_color = vec3(0.86, 0.44, 0.40);
uniform float mid_height = 0.18;

// ---- 天空：到太阳的角距离（度）为主变量，仰角加权 ----
uniform vec3 sky_glow_color : source_color = vec3(1.0, 0.88, 0.60);   // 贴近太阳：偏黄白
uniform float sky_glow_deg = 9.0;
uniform float sky_glow_strength = 0.75;
uniform vec3 sky_near_color : source_color = vec3(1.0, 0.66, 0.28);   // 近日半边：橙黄
uniform vec3 sky_mid_color : source_color = vec3(0.94, 0.68, 0.58);   // 过渡：淡桃粉（避免橙蓝直混发灰）
uniform vec3 sky_far_low_color : source_color = vec3(0.60, 0.72, 0.90); // 远日、低仰角：淡蓝
uniform float sky_near_deg = 15.0;   // t <= near：全橙黄
uniform float sky_mid_deg = 26.0;    // near→mid：橙黄→桃粉；mid→far：桃粉→蔚蓝
uniform float sky_far_deg = 36.0;    // t >= far：全蔚蓝
uniform float sky_el_boost = 0.35;   // t = 角距离 + boost × 仰角(度)，越高越偏蓝
uniform vec3 haze_far_color : source_color = vec3(0.97, 0.66, 0.50); // 远日一侧的地平线薄霾：橙粉
uniform float haze_strength = 0.85;
uniform float haze_far_scale = 0.6;  // 远日一侧薄霾强度比例

// ---- 云：显式水平云带 ----
uniform float bands_enabled = 1.0;
uniform float band_count = 6.0;          // 1..8
uniform float band_lo_el = 0.055;        // 最低带中心仰角（rad）
uniform float band_hi_el = 0.46;         // 最高带中心仰角（rad）
uniform float band_spacing_pow = 1.6;    // >1：低处带挤得更密
uniform float band_half_lo = 0.010;      // 最低带半厚（rad）
uniform float band_half_hi = 0.050;      // 最高带半厚（rad）
uniform float band_freq_k = 0.15;        // 方位向噪声频率 = k / 半厚（透视：越薄的带越碎）
uniform float band_vfreq = 1.2;          // 带厚度内的噪声周期数（>1 越碎）
uniform float band_vfreq_max = 40.0;     // 垂直噪声频率上限（cycles/rad），防低仰角颗粒
uniform float band_undulate = 0.8;       // 带中心随方位起伏（× 半厚）
uniform float band_bottom_soft = 0.35;   // 平底的软硬（× 半厚）
uniform float band_bottom_tear = 0.35;   // 底边被噪声撕开的程度
uniform float band_top_start = 0.2;      // 顶边开始消散的位置（× 半厚）
uniform float band_top_end = 1.3;
uniform float band_top_tear = 1.6;       // 顶边被噪声撕开的程度（絮状毛边）
uniform float band_gate_freq = 0.35;     // 横向断裂噪声频率（× 方位频率）
uniform float band_gate_lo = 0.30;       // 断裂阈值：低带
uniform float band_gate_lo_hi = 0.48;    // 断裂阈值：高带（越高越稀）
uniform float band_gate_soft = 0.30;
uniform float band_contrast = 2.2;       // fbm 值域拉伸
uniform float band_cov_lo = 0.70;        // 低带 coverage（越大云越实）
uniform float band_cov_hi = 0.50;        // 高带 coverage
uniform float band_edge_soft = 0.18;
uniform float band_alpha_lo = 0.80;
uniform float band_alpha_hi = 0.85;
uniform float band_seed = 17.0;
uniform float band_horizon_fade_lo = 0.015;
uniform float band_horizon_fade_hi = 0.045;

// ---- v2（Carlos 2026-09-23：保留 c_bands 的云层和蓝天，云更多，用半透明加层次）----
// 第二组"远层"云带：与主带错开半个间距、更薄、纹理更细、半透明、颜色往天空色靠（大气透视），先画在主带后面。
uniform float far_set_enabled = 1.0;
uniform float far_alpha_scale = 0.45;    // 远层 alpha 比例（半透明）
uniform float far_thick_scale = 0.75;    // 远层厚度比例
uniform float far_center_shift = 0.5;    // 远层中心相对主带错开的比例（× 带间距）
uniform float far_cov_scale = 0.92;      // 远层 coverage 比例
uniform float far_freq_scale = 1.4;      // 远层纹理频率比例（更碎 = 更远）
uniform float far_sky_fade = 0.30;       // 远层颜色往当前天空色靠的比例
uniform float band_alpha_top_fade = 0.35; // 主带越高越透明的额外衰减（0 = 不变）

// ---- 云明暗 ----
uniform vec3 cloud_lit_near : source_color = vec3(1.0, 0.80, 0.46);    // 近日：金黄底
uniform vec3 cloud_lit_far : source_color = vec3(0.98, 0.70, 0.66);    // 远日：粉
uniform vec3 cloud_shadow_near : source_color = vec3(0.60, 0.32, 0.20); // 近日：暗橙棕
uniform vec3 cloud_shadow_far : source_color = vec3(0.50, 0.36, 0.52);  // 远日：紫灰
uniform vec3 cloud_rim_color : source_color = vec3(1.0, 0.82, 0.42);
uniform float cloud_rim_strength = 1.6;
uniform float cloud_rim_step = 0.10;
uniform float cloud_sun_sigma_deg = 32.0;
uniform float cloud_prox_floor = 0.15;
uniform float cloud_underglow = 0.30;
uniform float cloud_shade_softness = 1.2;
uniform float cloud_core_darkening = 0.40;
uniform float cloud_low_lit_bias = 0.6;   // 低带整体偏亮（薄、逆光透光）
uniform float cloud_sun_clear_deg = 3.5;  // 日盘周围留空隙
uniform float cloud_sun_clear = 0.7;

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

float fbm4(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * noise21(p);
		p = p * 2.02 + vec2(13.7, 5.9);
		a *= 0.5;
	}
	return v / 0.9375;
}

// 一条云带。返回 rgb + alpha。
// 结构：平底（被低太阳从下面照亮）+ fbm 撕碎的絮状顶边；横向被低频噪声断成几团；
// 朝太阳方向再采一次密度：密度朝太阳下降的一面是朝阳面（亮/金边），上升的一面是背阳面（暗）。
vec4 band_layer(int i, float set_id, vec3 sky_col, float az, float el, float sun_az, float sun_el, float sun_prox, float underglow_w, float extra_fade) {
	float n = max(band_count - 1.0, 1.0);
	float f = float(i) / n;
	float f_next = min(float(i + 1), n) / n;
	float center = band_lo_el + (band_hi_el - band_lo_el) * pow(f, band_spacing_pow);
	float center_next = band_lo_el + (band_hi_el - band_lo_el) * pow(f_next, band_spacing_pow);
	center += set_id * far_center_shift * max(center_next - center, band_half_lo * 2.0);
	float half_t = mix(band_half_lo, band_half_hi, pow(f, 1.2)) * mix(1.0, far_thick_scale, set_id);
	float freq = band_freq_k / half_t * mix(1.0, far_freq_scale, set_id);
	float seed = band_seed + float(i) * 7.31 + set_id * 41.7;
	float reach = half_t * (1.0 + band_undulate + band_top_end + band_top_tear * 0.5);
	if (el < center - reach || el > center + reach) {
		return vec4(0.0);
	}
	// 中心起伏：带不是直线
	float und = noise21(vec2(az * freq * 0.35 + seed, seed * 0.37)) - 0.5;
	float c = center + und * band_undulate * half_t * 2.0;
	// 横向断裂：每条带断成几团
	float g = noise21(vec2(az * freq * band_gate_freq + seed * 1.7, seed * 0.91 + 4.2));
	float gate_lo = mix(band_gate_lo, band_gate_lo_hi, f);
	float gate = smoothstep(gate_lo, gate_lo + band_gate_soft, g);
	if (gate <= 0.001) {
		return vec4(0.0);
	}
	// 纹理：方位向按 freq，仰角向按 vscale（横向拉长的絮）
	float vscale = min(band_vfreq / half_t, band_vfreq_max);
	vec2 p = vec2(az * freq + seed * 3.1, (el - c) * vscale + seed * 0.5);
	float d = clamp((fbm4(p) - 0.5) * band_contrast + 0.5, 0.0, 1.0);
	float rel = (el - c) / half_t;
	float bottom = smoothstep(-1.0, -1.0 + band_bottom_soft, rel + (d - 0.5) * band_bottom_tear);
	float top = 1.0 - smoothstep(band_top_start, band_top_end, rel - (d - 0.5) * band_top_tear);
	float dens_field = d * bottom * top * gate;
	float lo = 1.0 - mix(band_cov_lo, band_cov_hi, f) * mix(1.0, far_cov_scale, set_id);
	float dens = smoothstep(lo, lo + band_edge_soft, dens_field) * extra_fade;
	if (dens <= 0.002) {
		return vec4(0.0);
	}
	// 朝太阳采样得到明暗面
	vec2 to_sun = vec2((sun_az - az) * freq, (sun_el - el) * vscale);
	to_sun = normalize(to_sun + vec2(1e-4, 0.0)) * cloud_rim_step;
	float d_s = clamp((fbm4(p + to_sun) - 0.5) * band_contrast + 0.5, 0.0, 1.0);
	float rel_s = rel + to_sun.y / max(vscale * half_t, 1e-4);
	float bottom_s = smoothstep(-1.0, -1.0 + band_bottom_soft, rel_s + (d_s - 0.5) * band_bottom_tear);
	float top_s = 1.0 - smoothstep(band_top_start, band_top_end, rel_s - (d_s - 0.5) * band_top_tear);
	float dens_field_s = d_s * bottom_s * top_s * gate;
	float slope = (dens_field - dens_field_s) / max(cloud_rim_step, 0.001);
	float sun_side = smoothstep(-cloud_shade_softness, cloud_shade_softness, slope);
	float low_bias = cloud_low_lit_bias * (1.0 - f);
	sun_side = mix(sun_side, 1.0, low_bias);
	vec3 lit = mix(cloud_lit_far, cloud_lit_near, sun_prox);
	vec3 shadow = mix(cloud_shadow_far, cloud_shadow_near, sun_prox);
	float core = smoothstep(lo + 0.06, lo + 0.34, dens_field);
	vec3 body = mix(shadow, lit, sun_side);
	body = mix(body, shadow, core * cloud_core_darkening * (1.0 - low_bias));
	body = mix(body, horizon_color, underglow_w);
	float thin = 1.0 - smoothstep(0.10, 0.80, dens);
	float rim = thin * sun_side * sun_prox;
	vec3 col = body + cloud_rim_color * rim * cloud_rim_strength;
	// 大气透视：远层往天空色靠一点
	col = mix(col, sky_col, far_sky_fade * set_id);
	float alpha = mix(band_alpha_lo, band_alpha_hi, f) * (1.0 - band_alpha_top_fade * f);
	alpha *= mix(1.0, far_alpha_scale, set_id);
	return vec4(col, dens * alpha);
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	float elevation = asin(clamp(direction.y, -1.0, 1.0));
	float azimuth = atan(direction.x, direction.z);
	float y_up = max(direction.y, 0.0);
	vec3 sun_n = normalize(sun_direction);
	float sun_dot = clamp(dot(direction, sun_n), -1.0, 1.0);
	float angle = acos(sun_dot);
	float angle_deg = degrees(angle);
	float el_deg = degrees(max(elevation, 0.0));

	// ---- 天空渐变：近日橙黄 → 桃粉 → 远日蔚蓝，仰角加权 ----
	float t = angle_deg + sky_el_boost * el_deg;
	float w_near = 1.0 - smoothstep(sky_near_deg, sky_mid_deg, t);
	float w_far = smoothstep(sky_mid_deg, sky_far_deg, t);
	vec3 far_col = mix(sky_far_low_color, zenith_color, smoothstep(0.03, 0.45, y_up));
	vec3 color = sky_near_color * w_near + sky_mid_color * (1.0 - w_near - w_far) + far_col * w_far;
	float glow = exp(-pow(angle_deg / max(sky_glow_deg, 0.1), 2.0));
	color = mix(color, sky_glow_color, glow * sky_glow_strength);
	// 地平线暖霾：整圈；近日更橙更强，远日偏橙粉且弱一点
	float near_w = 1.0 - smoothstep(sky_near_deg, sky_far_deg, angle_deg);
	float haze_w = haze_strength * exp(-y_up / max(horizon_falloff, 0.01)) * mix(haze_far_scale, 1.0, near_w);
	vec3 haze_col = mix(haze_far_color, horizon_color, near_w);
	color = mix(color, haze_col, haze_w);
	vec3 ground = mix(ground_horizon_color, ground_bottom_color, smoothstep(0.0, 0.7, -direction.y));
	color = mix(ground, color, smoothstep(-0.035, 0.015, direction.y));

	// ---- 太阳盘 + 光晕（先画，云再盖上去，薄云处透光）----
	float radius = radians(sun_radius_deg);
	float edge = radians(sun_edge_deg);
	float disk = smoothstep(cos(radius + edge), cos(max(radius - edge, 0.00001)), sun_dot);
	float halo = exp(-pow(angle / radians(max(sun_halo_radius_deg, 0.01)), 2.0));
	color += sun_disc_color * halo * sun_halo_strength;
	color = mix(color, sun_disc_color * sun_disc_energy, disk);

	// ---- 云带：高带先画（远），低带后画（近）----
	if (bands_enabled > 0.5) {
		float sun_prox = cloud_prox_floor + (1.0 - cloud_prox_floor) * exp(-pow(angle_deg / max(cloud_sun_sigma_deg, 1.0), 2.0));
		float underglow_w = cloud_underglow * (1.0 - smoothstep(0.05, 0.40, direction.y));
		float sun_el = asin(clamp(sun_n.y, -1.0, 1.0));
		float sun_az = atan(sun_n.x, sun_n.z);
		float sun_clear = 1.0 - cloud_sun_clear * exp(-pow(angle_deg / max(cloud_sun_clear_deg, 0.1), 2.0));
		float hfade = smoothstep(band_horizon_fade_lo, band_horizon_fade_hi, elevation);
		float extra_fade = sun_clear * hfade;
		int n = int(clamp(band_count, 1.0, 12.0));
		vec3 sky_col = color;
		if (far_set_enabled > 0.5) {
			for (int i = 11; i >= 0; i--) {
				if (i >= n) {
					continue;
				}
				vec4 b = band_layer(i, 1.0, sky_col, azimuth, elevation, sun_az, sun_el, sun_prox, underglow_w, extra_fade);
				color = mix(color, b.rgb, b.a);
			}
		}
		for (int i = 11; i >= 0; i--) {
			if (i >= n) {
				continue;
			}
			vec4 b = band_layer(i, 0.0, sky_col, azimuth, elevation, sun_az, sun_el, sun_prox, underglow_w, extra_fade);
			color = mix(color, b.rgb, b.a);
		}
	}
	COLOR = color * sky_energy;
}
