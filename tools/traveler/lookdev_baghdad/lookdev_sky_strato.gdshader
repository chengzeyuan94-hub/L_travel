shader_type sky;

// 导演探针 strato（2026-09-23）：
//   云：对数仰角重映射 v = log(el + el0)（越靠近地平线越压缩 → 透视层叠），
//       在 (az*sx, v*sy) 的各向异性域采 fbm（x 倍频比 y 快 → 大形横向拉长、细节趋于各向同性 = 絮状）；
//       叠一层高频 fbm 做毛边/小絮团；正弦 + 噪声起伏做水平堆叠的层；
//       按屏幕频率做 LOD（低仰角自动淡出高倍频程 → 不出颗粒）；
//       朝太阳方向再采一次密度：密度朝太阳下降的一面 = 朝阳面（底边亮、金边），上升的一面 = 背阳面（暗）。
//   天空：以到太阳角距离为主变量三段渐变（黄白 → 橙 → 蔚蓝），高仰角蓝加深，再叠地平线暖霾。
//   反射/环境光：场景的 ambient 与 reflection 都取自天空辐射立方图（REFLECTION_SOURCE_SKY / AMBIENT_SOURCE_SKY），
//       蓝色半边会把地面/人物整体带冷、带灰。所以 AT_CUBEMAP_PASS 时输出 v22 同款的暖三段渐变（refl_*），
//       让地面/人物的环境光与反射保持 v22 已被接受的暖色，画面背景仍是新天空。
//   只用 EYEDIR，无 TIME，无额外 pass。日盘 + 光晕沿用基线（云盖在日盘之上，薄云透光）。
//   每像素噪声采样：2 × (1 warp + 5 fbm + 3 detail) = 18 次。

// ---- 基线兼容键（配方重设时不丢参数）----
uniform vec3 zenith_color : source_color = vec3(0.28, 0.48, 0.84);
uniform vec3 horizon_color : source_color = vec3(1.0, 0.66, 0.32);
uniform vec3 ground_bottom_color : source_color = vec3(0.22, 0.14, 0.18);
uniform vec3 ground_horizon_color : source_color = vec3(0.80, 0.44, 0.24);
uniform float horizon_falloff = 0.16;
uniform float sky_energy = 1.0;
uniform vec3 sun_direction = vec3(-0.26, 0.12, 0.96);
uniform vec3 sun_disc_color : source_color = vec3(1.0, 0.92, 0.72);
uniform float sun_disc_energy = 3.4;
uniform float sun_radius_deg = 1.0;
uniform float sun_edge_deg = 0.025;
uniform float sun_halo_radius_deg = 14.0;
uniform float sun_halo_strength = 0.5;
uniform vec3 cloud_color : source_color = vec3(0.93, 0.73, 0.52);
uniform float cloud_opacity = 0.0;
uniform float cloud_seed = 29.0;
uniform float cloud_coverage = 0.42;
uniform vec3 mid_color : source_color = vec3(0.86, 0.44, 0.40);
uniform float mid_height = 0.18;
uniform float cumulus_enabled = 1.0;
uniform float cloud_b_base_el = 0.05;
uniform float cloud_b_top_el = 0.30;
uniform vec2 cloud_b_scale = vec2(7.0, 6.0);
uniform vec2 cloud_b_offset = vec2(11.3, 2.9);
uniform float cloud_b_coverage = 0.45;
uniform float cloud_b_alpha = 0.97;
uniform float cloud_a_base_el = 0.28;
uniform float cloud_a_top_el = 0.62;
uniform vec2 cloud_a_scale = vec2(8.0, 7.0);
uniform vec2 cloud_a_offset = vec2(3.1, 7.7);
uniform float cloud_a_coverage = 0.40;
uniform float cloud_a_alpha = 0.88;
uniform vec3 cloud_lit_color : source_color = vec3(1.0, 0.80, 0.58);
uniform vec3 cloud_shadow_color : source_color = vec3(0.46, 0.28, 0.46);
uniform vec3 cloud_rim_color : source_color = vec3(1.0, 0.72, 0.30);
uniform float cloud_rim_strength = 2.5;
uniform float cloud_rim_step = 0.12;
uniform float cloud_sun_sigma_deg = 60.0;
uniform float cloud_prox_floor = 0.5;
uniform float cloud_underglow = 0.35;
uniform float cloud_contrast = 2.0;
uniform float cloud_edge_soft = 0.14;
uniform float cloud_shade_softness = 1.2;
uniform float cloud_core_darkening = 0.45;

// ---- 天空渐变：到太阳的角距离为主变量 ----
uniform vec3 sun_zone_color : source_color = vec3(1.0, 0.88, 0.58);   // 贴近太阳：黄白
uniform vec3 warm_zone_color : source_color = vec3(1.0, 0.66, 0.34);  // 近日半边：橙黄
uniform vec3 cool_zone_color : source_color = vec3(0.40, 0.62, 0.90); // 远日半边：蔚蓝
uniform float warm_peak_deg = 12.0;     // 0..warm_peak：黄白 → 橙
uniform float blue_start_deg = 13.0;    // 橙 → 蓝 的过渡起点
uniform float blue_end_deg = 32.0;      // 过渡终点（之后全蓝）
uniform float zenith_start_el = 0.20;   // 高仰角处蓝加深（cool → zenith）
uniform float zenith_end_el = 0.60;
uniform float haze_strength = 1.0;      // 地平线整圈暖霾
uniform float haze_falloff = 0.08;
uniform vec3 haze_far_color : source_color = vec3(0.98, 0.60, 0.44); // 远日侧暖霾偏粉橙
uniform float haze_sun_sigma_deg = 30.0;

// ---- 辐射立方图（环境光/反射）用的暖三段渐变：默认 = v22 的天空 ----
uniform vec3 refl_zenith_color : source_color = vec3(0.30, 0.26, 0.54);
uniform vec3 refl_mid_color : source_color = vec3(0.86, 0.44, 0.40);
uniform float refl_mid_height = 0.18;
uniform vec3 refl_horizon_color : source_color = vec3(1.0, 0.60, 0.24);
uniform float refl_horizon_falloff = 0.20;

// ---- 层云 ----
uniform float st_el0 = 0.05;                     // 对数重映射的地平线偏移（越小越压缩）
uniform vec2 st_scale = vec2(14.0, 16.0);        // (az 倍率, v 倍率)
uniform vec2 st_offset = vec2(7.3, 2.1);
uniform vec2 st_lacunarity = vec2(2.5, 2.0);     // x 倍频更快 → 细节更各向同性（絮状）
uniform float st_warp = 1.6;                     // 层的起伏（uv 单位）
uniform vec2 st_warp_scale = vec2(0.35, 0.25);
uniform float st_band_amp = 0.30;                // 水平堆叠带的强度
uniform float st_band_freq = 1.5;                // 带频率（uv.y 单位）
uniform float st_contrast = 2.1;                 // fbm 值域拉伸
uniform float st_detail = 0.45;                  // 毛边 / 小絮团强度
uniform vec2 st_detail_scale = vec2(40.0, 28.0);
uniform float st_cov_low = 0.46;                 // 低仰角覆盖率（密）
uniform float st_cov_high = 0.12;                // 高仰角覆盖率（稀）
uniform float st_cov_el_a = 0.10;
uniform float st_cov_el_b = 0.40;
uniform float st_soft = 0.22;                    // 密度阈值软硬
uniform float st_low_el = 0.02;
uniform float st_high_el = 0.50;
uniform float st_alpha = 0.93;
uniform float st_lod_freq = 150.0;               // 允许的最大屏幕频率（周期 / 仰角弧度）
uniform float st_rim_step = 0.12;                // 朝太阳偏移采样步长（uv 单位）
uniform float st_shade_soft = 2.0;
uniform float st_core_dark = 0.45;
uniform float st_lit_body = 0.35;                // 云身（非边缘）朝阳面吃到的亮色比例：亮色主要留在底边/毛边
uniform vec3 st_lit_near : source_color = vec3(1.0, 0.72, 0.30);      // 近日：金橙
uniform vec3 st_lit_far : source_color = vec3(0.96, 0.58, 0.44);      // 远日：粉橙
uniform vec3 st_shadow_near : source_color = vec3(0.52, 0.28, 0.13);  // 近日背阳：暗橙棕
uniform vec3 st_shadow_far : source_color = vec3(0.56, 0.36, 0.46);   // 远日背阳：粉紫灰
uniform vec3 st_rim_color : source_color = vec3(1.0, 0.80, 0.36);
uniform float st_rim_strength = 1.8;
uniform float st_prox_floor = 0.35;              // 远日云保留的金边比例
uniform float st_glow_strength = 0.9;            // 太阳附近薄云透光金
uniform float st_glow_sigma_deg = 12.0;
uniform float st_sun_sigma_deg = 30.0;           // 云色 近日/远日 混合宽度
uniform float st_underglow = 0.15;
uniform float st_sun_clear_deg = 5.0;            // 日盘周围留出的空隙
uniform float st_sun_clear = 0.55;

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

// 带 LOD 的各向异性 fbm：oct 为有效倍频程数（可为小数），超出的倍频程按权重淡出并重新归一，
// 均值保持 0.5 → 云密度不随仰角漂移。
float fbm5_lod(vec2 p, vec2 lac, float oct) {
	float v = 0.0;
	float a = 0.5;
	float wsum = 0.0;
	for (int i = 0; i < 5; i++) {
		float w = clamp(oct - float(i), 0.0, 1.0);
		v += a * w * noise21(p);
		wsum += a * w;
		p = p * lac + vec2(13.7, 5.9);
		a *= 0.5;
	}
	if (wsum < 1e-3) {
		return 0.5;
	}
	return v / wsum;
}

float fbm3_lod(vec2 p, vec2 lac, float oct) {
	float v = 0.0;
	float a = 0.5;
	float wsum = 0.0;
	for (int i = 0; i < 3; i++) {
		float w = clamp(oct - float(i), 0.0, 1.0);
		v += a * w * noise21(p);
		wsum += a * w;
		p = p * lac + vec2(7.1, 3.3);
		a *= 0.5;
	}
	if (wsum < 1e-3) {
		return 0.5;
	}
	return v / wsum;
}

// 层云密度场（阈值之前的值，均值 ~0.5）。uv = (az*sx, v*sy) + offset；uvd = 毛边域。
// oct / oct_d：按仰角算出的允许倍频程数。
float strato_field(vec2 uv, vec2 uvd, float oct, float oct_d) {
	float wn = noise21(uv * st_warp_scale + vec2(3.1, 9.4));
	vec2 q = uv + vec2(0.0, (wn - 0.5) * 2.0 * st_warp);
	float d = fbm5_lod(q, st_lacunarity, oct);
	float band = 0.5 + 0.5 * sin(q.y * st_band_freq);
	d += (band - 0.5) * st_band_amp;
	float det = fbm3_lod(uvd + vec2(0.0, (wn - 0.5) * 2.0 * st_warp * st_detail_scale.y / st_scale.y), vec2(2.2, 2.0), oct_d);
	d += (det - 0.5) * st_detail;
	return clamp((d - 0.5) * st_contrast + 0.5, 0.0, 1.0);
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	float elevation = asin(clamp(direction.y, -1.0, 1.0));
	float azimuth = atan(direction.x, direction.z);

	vec3 sun_n = normalize(sun_direction);
	float sun_dot = clamp(dot(direction, sun_n), -1.0, 1.0);
	float angle = acos(sun_dot);
	float angle_deg = degrees(angle);
	float sun_el = asin(clamp(sun_n.y, -1.0, 1.0));
	float sun_az = atan(sun_n.x, sun_n.z);

	// 日盘 + 光晕（两条路径共用）
	float radius = radians(sun_radius_deg);
	float edge = radians(sun_edge_deg);
	float disk = smoothstep(cos(radius + edge), cos(max(radius - edge, 0.00001)), sun_dot);
	float halo = exp(-pow(angle / radians(max(sun_halo_radius_deg, 0.01)), 2.0));
	vec3 ground = mix(ground_horizon_color, ground_bottom_color, smoothstep(0.0, 0.7, -direction.y));

	if (AT_CUBEMAP_PASS) {
		// 辐射立方图：v22 同款暖三段渐变，保住地面/人物的环境光与反射色
		float y_up = max(direction.y, 0.0);
		float warm_weight = exp(-y_up / max(refl_horizon_falloff, 0.01));
		float upper = smoothstep(refl_mid_height, refl_mid_height + 0.45, y_up);
		vec3 rc = mix(refl_mid_color, refl_zenith_color, upper);
		rc = mix(rc, refl_horizon_color, warm_weight);
		rc = mix(ground, rc, smoothstep(-0.035, 0.015, direction.y));
		rc += sun_disc_color * halo * sun_halo_strength;
		rc = mix(rc, sun_disc_color * sun_disc_energy, disk);
		COLOR = rc * sky_energy;
	} else {
	// ---- 天空渐变 ----
	vec3 cool = mix(cool_zone_color, zenith_color, smoothstep(zenith_start_el, zenith_end_el, elevation));
	vec3 color = mix(sun_zone_color, warm_zone_color, smoothstep(0.0, max(warm_peak_deg, 0.1), angle_deg));
	color = mix(color, cool, smoothstep(blue_start_deg, max(blue_end_deg, blue_start_deg + 0.1), angle_deg));
	float sun_prox_haze = exp(-pow(angle / radians(max(haze_sun_sigma_deg, 1.0)), 2.0));
	vec3 haze_col = mix(haze_far_color, horizon_color, sun_prox_haze);
	float haze_w = haze_strength * exp(-max(elevation, 0.0) / max(haze_falloff, 0.005));
	color = mix(color, haze_col, clamp(haze_w, 0.0, 1.0));
	color = mix(ground, color, smoothstep(-0.035, 0.015, direction.y));

	// ---- 日盘 + 光晕（先画，云再盖上去，薄云处透光）----
	color += sun_disc_color * halo * sun_halo_strength;
	color = mix(color, sun_disc_color * sun_disc_energy, disk);

	// ---- 层云 ----
	if (cumulus_enabled > 0.5 && elevation > st_low_el - 0.06 && elevation < st_high_el + 0.20) {
		float el0 = max(st_el0, 0.005);
		float ev = max(elevation + el0, 0.005);
		float v = log(ev);
		float v_sun = log(max(sun_el + el0, 0.005));
		vec2 uv = vec2(azimuth * st_scale.x, v * st_scale.y) + st_offset;
		vec2 uvd = vec2(azimuth * st_detail_scale.x, v * st_detail_scale.y) + vec2(5.7, 11.2);
		// LOD：倍频程 i 在屏幕上的仰角频率 = sy * 2^i / (el + el0)，超过 st_lod_freq 的淡出
		float oct = clamp(log2(st_lod_freq * ev / max(st_scale.y, 0.01)) + 1.0, 1.0, 5.0);
		float oct_d = clamp(log2(st_lod_freq * ev / max(st_detail_scale.y, 0.01)) + 1.0, 0.0, 3.0);

		float d = strato_field(uv, uvd, oct, oct_d);
		float cov = mix(st_cov_low, st_cov_high, smoothstep(st_cov_el_a, st_cov_el_b, elevation));
		float lo = 1.0 - cov;
		float dens = smoothstep(lo, lo + st_soft, d);
		// 上下范围用噪声打散，不出直线
		dens *= smoothstep(st_low_el - 0.02, st_low_el + 0.04, elevation + (d - 0.5) * 0.06);
		dens *= 1.0 - smoothstep(st_high_el - 0.08, st_high_el + 0.10, elevation - (d - 0.5) * 0.20);
		// 日盘周围留空隙
		dens *= 1.0 - st_sun_clear * exp(-pow(angle / radians(max(st_sun_clear_deg, 0.5)), 2.0));

		if (dens > 0.002) {
			vec2 to_sun = vec2((sun_az - azimuth) * st_scale.x, (v_sun - v) * st_scale.y);
			to_sun = normalize(to_sun + vec2(1e-4, 0.0));
			vec2 to_sun_d = to_sun * st_rim_step * st_detail_scale / st_scale;
			float d_sun = strato_field(uv + to_sun * st_rim_step, uvd + to_sun_d, oct, oct_d);
			float slope = (d - d_sun) / max(st_rim_step, 0.001);
			float sun_side = smoothstep(-st_shade_soft, st_shade_soft, slope);

			float prox = exp(-pow(angle / radians(max(st_sun_sigma_deg, 1.0)), 2.0));
			vec3 lit = mix(st_lit_far, st_lit_near, prox);
			vec3 shadow = mix(st_shadow_far, st_shadow_near, prox);
			float core = smoothstep(lo + 0.05, lo + 0.35, d);
			float thin = 1.0 - smoothstep(0.10, 0.80, dens);
			vec3 body = mix(shadow, lit, sun_side * mix(st_lit_body, 1.0, thin));
			body = mix(body, shadow, core * st_core_dark);
			float underglow_w = st_underglow * (1.0 - smoothstep(0.05, 0.35, elevation));
			body = mix(body, haze_col, underglow_w);
			float rim = thin * sun_side * (st_prox_floor + (1.0 - st_prox_floor) * prox);
			vec3 col = body + st_rim_color * rim * st_rim_strength;
			float glow_p = exp(-pow(angle / radians(max(st_glow_sigma_deg, 1.0)), 2.0));
			col += st_rim_color * thin * glow_p * st_glow_strength;
			color = mix(color, col, clamp(dens * st_alpha, 0.0, 1.0));
		}
	}
	COLOR = color * sky_energy;
	}
}
