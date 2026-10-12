shader_type sky;

// 导演探针：Codex 的 baghdad_sunset_sky.gdshader 原样保留（渐变 / 太阳盘 / 光晕），
// 只在上面叠两层"云平面投影"的絮状积云，并做朝阳一侧的金边。
// 依旧只用 EYEDIR，无 TIME，无额外全屏 pass。

uniform vec3 zenith_color : source_color = vec3(0.30, 0.40, 0.56);
uniform vec3 horizon_color : source_color = vec3(1.0, 0.62, 0.24);
uniform vec3 ground_bottom_color : source_color = vec3(0.478, 0.373, 0.294);
uniform vec3 ground_horizon_color : source_color = vec3(0.827, 0.612, 0.396);
uniform float horizon_falloff = 0.16;
uniform float sky_energy = 1.0;
uniform vec3 sun_direction = vec3(-0.26, 0.12, 0.96);
uniform vec3 sun_disc_color : source_color = vec3(1.0, 0.96, 0.76);
uniform float sun_disc_energy = 2.6;
uniform float sun_radius_deg = 1.08;
uniform float sun_edge_deg = 0.025;
uniform float sun_halo_radius_deg = 5.2;
uniform float sun_halo_strength = 0.24;
uniform vec3 cloud_color : source_color = vec3(0.93, 0.73, 0.52);
uniform float cloud_opacity = 0.27;
uniform float cloud_seed = 29.0;
uniform float cloud_coverage = 0.42;

// ---- 新增：三段渐变（地平线暖带 / 中段 / 天顶） ----
uniform vec3 mid_color : source_color = vec3(0.86, 0.44, 0.40);
uniform float mid_height = 0.18;

// ---- 新增：絮状积云（两层，(方位角, 仰角) 穹顶域，不做平面投影，低仰角不被压成条） ----
uniform float cumulus_enabled = 1.0;
uniform float cloud_b_base_el = 0.06;   // 低层：厚、近，平底
uniform float cloud_b_top_el = 0.30;
uniform vec2 cloud_b_scale = vec2(2.6, 4.5);
uniform vec2 cloud_b_offset = vec2(11.3, 2.9);
uniform float cloud_b_coverage = 0.58;
uniform float cloud_b_alpha = 0.95;
uniform float cloud_a_base_el = 0.30;   // 高层：薄、远
uniform float cloud_a_top_el = 0.62;
uniform vec2 cloud_a_scale = vec2(2.0, 3.5);
uniform vec2 cloud_a_offset = vec2(3.1, 7.7);
uniform float cloud_a_coverage = 0.42;
uniform float cloud_a_alpha = 0.70;
uniform vec3 cloud_lit_color : source_color = vec3(1.0, 0.85, 0.68);
uniform vec3 cloud_shadow_color : source_color = vec3(0.36, 0.22, 0.36);
uniform vec3 cloud_rim_color : source_color = vec3(1.0, 0.80, 0.40);
uniform float cloud_rim_strength = 2.2;
uniform float cloud_rim_step = 0.09;
uniform float cloud_sun_sigma_deg = 50.0;
uniform float cloud_underglow = 0.30;
uniform float cloud_prox_floor = 0.25;   // 离太阳远的云也保留的金边比例
uniform float cloud_contrast = 2.2;        // fbm 值域拉伸：>1 让云与空隙分明
uniform float cloud_edge_soft = 0.16;     // 云边缘的软硬（小=边缘硬、云更实）
uniform float cloud_shade_softness = 1.2;  // 朝阳面/背阳面明暗过渡
uniform float cloud_core_darkening = 0.45; // 云心压暗

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

float cloud_noise(vec2 p) {
	float n = noise21(p) * 0.53;
	n += noise21(p * 2.03 + vec2(12.7, 5.4)) * 0.27;
	n += noise21(p * 4.09 + vec2(7.3, 19.2)) * 0.13;
	n += noise21(p * 8.21 + vec2(21.1, 1.2)) * 0.07;
	return n;
}

float fbm5(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * noise21(p);
		p = p * 2.02 + vec2(13.7, 5.9);
		a *= 0.5;
	}
	return v;
}

// 返回 rgb + alpha。az/el 为该像素方向的方位角与仰角（弧度）
// 明暗：在 (方位, 仰角) 域里朝太阳方向再采一次密度，密度朝太阳下降的一面是朝阳面（亮、金边），
// 上升的一面是背阳面（暗）。云心再压暗一档，读成有体积的絮状云。
vec4 cumulus(float az, float el, float base_el, float top_el, vec2 scale, vec2 offset, float coverage, float layer_alpha,
		float sun_az, float sun_el, float sun_prox, float underglow_w) {
	if (el < base_el - 0.04 || el > top_el + 0.16) {
		return vec4(0.0);
	}
	vec2 uv = vec2(az * scale.x, el * scale.y) + offset;
	float d = clamp((fbm5(uv) - 0.5) * cloud_contrast + 0.5, 0.0, 1.0);
	float lo = 1.0 - coverage;
	// 底边也用噪声打散，否则两层交界处会出现一条笔直的水平线（v18 实测）
	float base = smoothstep(base_el - 0.03, base_el + 0.06, el + (d - 0.5) * 0.18);
	float top = 1.0 - smoothstep(top_el - 0.10, top_el + 0.12, el - (d - 0.5) * 0.30);
	float dens = smoothstep(lo, lo + cloud_edge_soft, d) * base * top;
	if (dens <= 0.002) {
		return vec4(0.0);
	}
	vec2 to_sun = vec2((sun_az - az) * scale.x, (sun_el - el) * scale.y);
	to_sun = normalize(to_sun + vec2(1e-4, 0.0));
	float d_sun = clamp((fbm5(uv + to_sun * cloud_rim_step) - 0.5) * cloud_contrast + 0.5, 0.0, 1.0);
	float slope = (d - d_sun) / max(cloud_rim_step, 0.001);
	float sun_side = smoothstep(-cloud_shade_softness, cloud_shade_softness, slope);
	float core = smoothstep(lo + 0.06, lo + 0.34, d);
	vec3 body = mix(cloud_shadow_color, cloud_lit_color, sun_side);
	body = mix(body, cloud_shadow_color, core * cloud_core_darkening);
	body = mix(body, horizon_color, underglow_w);
	float thin = 1.0 - smoothstep(0.10, 0.80, dens);
	float rim = thin * sun_side * sun_prox;
	vec3 col = body + cloud_rim_color * rim * cloud_rim_strength;
	return vec4(col, dens * layer_alpha);
}


// ---- 导演线 dir：两区天空 + 横向层云 ----
uniform float sky_span_deg = 40.0;          // 到太阳的角距离归一化跨度
uniform vec3 sun_zone_color : source_color = vec3(1.0, 0.88, 0.55);
uniform vec3 warm_zone_color : source_color = vec3(1.0, 0.62, 0.28);
uniform vec3 cool_zone_color : source_color = vec3(0.44, 0.62, 0.86);
uniform float warm_end = 0.40;               // t 到这里还是全暖
uniform float cool_start = 1.0;              // t 到这里全蓝
uniform float zenith_mix = 0.5;
uniform float haze_strength = 0.75;
uniform vec2 cs_scale = vec2(2.2, 3.0);
uniform vec2 cs_offset = vec2(5.0, 1.0);
uniform float cs_el0 = 0.035;
uniform float cs_detail = 0.25;
uniform float cs_contrast = 1.8;
uniform float cs_coverage = 0.42;
uniform float cs_soft = 0.18;
uniform float cs_low = 0.04;
uniform float cs_high = 0.46;
uniform float cs_alpha = 0.95;
uniform float cs_rim_step = 0.10;
uniform float cs_shade_soft = 1.0;
uniform vec3 cs_lit_near : source_color = vec3(1.0, 0.74, 0.42);
uniform vec3 cs_lit_far : source_color = vec3(1.0, 0.74, 0.66);
uniform vec3 cs_shadow_near : source_color = vec3(0.62, 0.36, 0.30);
uniform vec3 cs_shadow_far : source_color = vec3(0.52, 0.40, 0.56);
uniform float cs_gold_strength = 1.6;

vec4 strato(float az, float el, float sun_az, float sun_el, float w_near, float sun_prox) {
	if (el < cs_low - 0.03 || el > cs_high + 0.12) {
		return vec4(0.0);
	}
	float v = log(max(el, 0.0) + cs_el0);
	vec2 uv = vec2(az * cs_scale.x, v * cs_scale.y) + cs_offset;
	float d = fbm5(uv);
	float detail = fbm5(uv * vec2(4.5, 3.0) + vec2(11.0, 7.0));
	d = clamp((d - 0.5) * cs_contrast + 0.5 + (detail - 0.5) * cs_detail, 0.0, 1.0);
	float env = smoothstep(cs_low - 0.02, cs_low + 0.05, el) * (1.0 - smoothstep(cs_high - 0.14, cs_high + 0.08, el));
	float lo = 1.0 - cs_coverage;
	float dens = smoothstep(lo, lo + cs_soft, d) * env;
	if (dens <= 0.002) {
		return vec4(0.0);
	}
	float v_sun = log(max(sun_el, 0.0) + cs_el0);
	vec2 to_sun = normalize(vec2((sun_az - az) * cs_scale.x, (v_sun - v) * cs_scale.y) + vec2(1e-4, 0.0));
	float d2 = fbm5(uv + to_sun * cs_rim_step);
	float detail2 = fbm5((uv + to_sun * cs_rim_step) * vec2(4.5, 3.0) + vec2(11.0, 7.0));
	d2 = clamp((d2 - 0.5) * cs_contrast + 0.5 + (detail2 - 0.5) * cs_detail, 0.0, 1.0);
	float slope = (d - d2) / max(cs_rim_step, 0.001);
	float sun_side = smoothstep(-cs_shade_soft, cs_shade_soft, slope);
	vec3 lit = mix(cs_lit_far, cs_lit_near, w_near);
	vec3 shadow = mix(cs_shadow_far, cs_shadow_near, w_near);
	float core = smoothstep(lo + 0.08, lo + 0.40, d);
	vec3 body = mix(shadow, lit, sun_side);
	body = mix(body, shadow, core * 0.35);
	float thin = 1.0 - smoothstep(0.10, 0.75, dens);
	// 金边主要在近日区；远日区的云只留柔和的粉边（参考图左上的云没有白描边）
	body += cloud_rim_color * thin * sun_side * sun_prox * cs_gold_strength * (0.30 + 0.70 * w_near);
	return vec4(body, dens * cs_alpha);
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	float elevation = asin(clamp(direction.y, -1.0, 1.0));
	float azimuth = atan(direction.x, direction.z);
	float y_up = max(direction.y, 0.0);
	vec3 sun_n = normalize(sun_direction);
	float sun_dot = clamp(dot(direction, sun_n), -1.0, 1.0);
	float angle = acos(sun_dot);
	float t = angle / radians(max(sky_span_deg, 1.0));

	// 两区：近日黄白→橙，远日蔚蓝，柔和过渡；天顶略加深；地平线整圈暖霾
	vec3 near = mix(sun_zone_color, warm_zone_color, smoothstep(0.0, 0.45, t));
	float w_cool = smoothstep(warm_end, cool_start, t);
	vec3 color = mix(near, cool_zone_color, w_cool);
	color = mix(color, zenith_color, smoothstep(0.30, 0.90, y_up) * zenith_mix * w_cool);
	float haze = exp(-y_up / max(horizon_falloff, 0.01)) * haze_strength;
	color = mix(color, horizon_color, haze);
	vec3 ground = mix(ground_horizon_color, ground_bottom_color, smoothstep(0.0, 0.7, -direction.y));
	color = mix(ground, color, smoothstep(-0.035, 0.015, direction.y));

	// 日盘 + 光晕
	float radius = radians(sun_radius_deg);
	float edge = radians(sun_edge_deg);
	float disk = smoothstep(cos(radius + edge), cos(max(radius - edge, 0.00001)), sun_dot);
	float halo = exp(-pow(angle / radians(max(sun_halo_radius_deg, 0.01)), 2.0));
	color += sun_disc_color * halo * sun_halo_strength;
	color = mix(color, sun_disc_color * sun_disc_energy, disk);

	if (cumulus_enabled > 0.5) {
		float sun_prox = cloud_prox_floor + (1.0 - cloud_prox_floor) * exp(-pow(angle / radians(max(cloud_sun_sigma_deg, 1.0)), 2.0));
		float sun_el = asin(clamp(sun_n.y, -1.0, 1.0));
		float sun_az = atan(sun_n.x, sun_n.z);
		vec4 c = strato(azimuth, elevation, sun_az, sun_el, 1.0 - w_cool, sun_prox);
		color = mix(color, c.rgb, c.a);
	}
	COLOR = color * sky_energy;
}
