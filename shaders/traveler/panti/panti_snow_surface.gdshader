shader_type spatial;
// Panti light polish · snow ground surface (replaces the SnowGround StandardMaterial3D, albedo copied).
// Ported 1:1 from the approved probe (tools/traveler/lookdev_panti/b_snow_surface.gdshader, variant m4_final).
// All switches default to 0; at 0 the result matches the original material (Burley diffuse, roughness 1).
//   1. detail / rip_* / macro_*: world-space wind ripples = low normal tilt + faint tone / warm-cool; each octave
//      fades by its per-pixel phase rate (fwidth), so grazing distance never moires; plus a distance fade (~7 u).
//   2. sheen_*: broad Blinn lobe x Schlick in light(); directional and point strengths separate.
//   2b. sun_tint_*: warm-lit / cool-side multiplier on directional diffuse only (morning only).
//   2c. vr_*: un-clipped warm reflection lobe from the fire, lantern and castle spill lights (real-time positions and
//      energies fed by panti_snow_shading.gd), written to EMISSION.
//   3. glit_*: world-locked angular cells around the fixed camera, random ice-facet normals wobbling on weather anim_t
//      (pause holds them); lit only when aligned with the half vector and x ATTENUATION (no glitter in tree shadow).
// Untagged vec3 uniforms (*_tint multipliers, vr_color) must be written as Vector3: a Color is sRGB-converted.

uniform vec3 albedo : source_color = vec3(0.86, 0.91, 0.97);
uniform float burley = 1.0;

// ---- 1. 细节 ----
uniform float detail = 0.0;                 // 总强度（0 = 关）
uniform float detail_near = 2.0;            // 离相机距离（u）：从这里开始淡出
uniform float detail_far = 10.0;            // 到这里完全淡出
uniform vec2 wind_dir = vec2(-0.81, 0.58);  // 风向（世界 xz）：雪垄的相位沿这个方向走
uniform float rip_freq = 5.0;               // 主雪垄频率（条 / u）
uniform float rip_skew = 0.35;              // 不对称（迎风缓、背风陡）
uniform float rip2_ratio = 2.3;             // 第二层细纹频率倍数
uniform float rip2_amt = 0.45;              // 第二层细纹幅度
uniform float rip_warp = 0.35;              // 域扭曲幅度（u）：让垄线弯曲、分叉
uniform float rip_warp_scale = 0.55;        // 域扭曲频率（1/u）
uniform float rip_patch_scale = 0.32;       // 雪垄成片 / 平滑区交替的频率（1/u）
uniform float rip_patch_lo = 0.30;
uniform float rip_patch_hi = 0.68;
uniform float rip_slope = 0.05;             // 法线最大倾斜（≈ 弧度）
uniform float rip_tone = 0.025;             // 脊亮 / 谷暗
uniform float rip_break = 0.0;              // 沿垄线方向把长垄打断成一段段（0..1）
uniform float rip_break_scale = 1.6;        // 打断的频率（1/u，沿垄线）
uniform vec3 hollow_tint = vec3(0.94, 0.97, 1.05);  // 谷 / 凹处（线性倍率，偏蓝）
uniform vec3 crest_tint = vec3(1.025, 1.01, 0.975); // 脊 / 向阳（线性倍率，偏暖白）
uniform float rip_tint_amount = 0.5;        // 雪垄冷暖（按 h 在 hollow / crest 之间）
uniform float macro_scale = 0.18;           // 大尺度冷暖斑频率（1/u）
uniform float macro_amount = 0.0;           // 大尺度冷暖斑强度（不随距离淡出）
uniform float facet_jitter = 0.0;           // 每个低多边形面一个随机明度（突出刻面）
uniform float aa_lo = 0.10;                 // 每像素相位变化（周）超过它开始淡出
uniform float aa_hi = 0.30;                 // 到这里完全淡出

// ---- 2. 光泽 ----
uniform float sheen_sun = 0.0;              // 平行光（太阳 / 月亮）光泽强度
uniform float sheen_point = 0.0;            // 点光（篝火 / 灯笼 / 城下暖光）光泽强度
uniform float sheen_power_sun = 6.0;        // Blinn 指数（小 = 宽）
uniform float sheen_power_point = 10.0;
uniform float sheen_f0 = 0.08;              // Schlick F0（背光掠射时趋近 1）
uniform vec3 sheen_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float sheen_facet_fade = 0.0;       // >0：朝光刻面才有平行光光泽（ndl 门限）
// 2b. 平行光冷暖：向阳面偏暖白、侧光 / 背光面偏蓝（亮度大致守恒的倍率，只作用于平行光漫反射）
uniform float sun_tint_amount = 0.0;
uniform vec3 sun_warm = vec3(1.05, 1.0, 0.92);
uniform vec3 sun_cool = vec3(0.94, 0.99, 1.08);
uniform float sun_tint_lo = 0.15;
uniform float sun_tint_hi = 0.55;
// 2c. 远距暖反光（虚拟反射光源）：Godot 点光的 range 截断了真正的镜面反射路径（低光源、低机位时，
//     反射点离光源很远），这里按灯的真实位置 / 颜色 × 能量（panti_snow_shading.gd 读灯写入）补一条不截断的光泽瓣，
//     写进 EMISSION。篝火、灯笼、城门 / 城下暖光。
uniform float vr_strength = 0.0;
uniform float vr_power = 24.0;              // 光泽瓣指数
uniform float vr_f0 = 0.1;
uniform float vr_radius = 2.5;              // 距离衰减半径（u）：1 / (1 + (d/r)^2)
uniform vec3 vr_tint = vec3(1.0, 1.0, 1.0); // 线性倍率
uniform float vr_recolor = 0.0;             // 0 = 用灯本身的颜色；1 = 用灯的最大通道当强度、换成 vr_color 的色相（避免红橙灯光叠在蓝雪上发粉）
uniform vec3 vr_color = vec3(1.0, 0.5, 0.18); // 线性
uniform float vr_glit = 0.0;                // 虚拟光源的闪粉强度
uniform float vr_flat = 0.0;                // 光泽瓣用的法线向正上方混合（0..1）：软化刻面把反光切成三角块
uniform vec3 vr_pos[6];
uniform vec3 vr_col[6];

// ---- 3. 闪粉 ----
uniform float glit_sun = 0.0;
uniform float glit_point = 0.0;
uniform float glit_density = 0.35;          // 每格有闪粉的概率
uniform float glit_cell_px = 7.0;           // 格子大小（1080p 像素）
uniform float glit_size_near = 1.3;         // 闪粉半径（实际像素，高斯）
uniform float glit_size_far = 0.75;
uniform float glit_near = 2.0;              // 距离（u）
uniform float glit_far = 12.0;
uniform float glit_far_keep = 0.2;          // 远处保留的密度比例
uniform float glit_cone = 0.965;            // dot(冰晶法线, H) 从这里开始亮
uniform float glit_speed = 0.5;             // 冰晶摆动速度（rad/s 量级）
uniform float glit_wobble = 0.22;           // 冰晶摆动幅度
uniform float glit_twinkle = 0.4;           // 额外明灭
uniform float glit_prism = 0.12;            // 彩虹色偏
uniform vec3 glit_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float anim_t = 0.0;
uniform vec3 ref_cam_pos = vec3(7.7157, 0.2526, 15.3793);
uniform vec2 ref_cam_fwd = vec2(-0.571, -0.80);
uniform float ref_rad_per_px = 0.000646;

varying vec3 v_world;
varying float v_glit;
varying vec3 v_glit_n;
varying vec3 v_glit_col;

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

vec2 rip_phase(vec2 p) {
	vec2 wd = normalize(wind_dir);
	vec2 warp = (vec2(fbm3(p * rip_warp_scale + 3.3), fbm3(p * rip_warp_scale + 17.9)) - 0.5) * 2.0 * rip_warp;
	vec2 wp = p + warp;
	float ph1 = dot(wp, wd) * rip_freq;
	vec2 wd2 = vec2(wd.x * 0.94 - wd.y * 0.34, wd.x * 0.34 + wd.y * 0.94);
	float ph2 = dot(wp + warp * 0.6, wd2) * rip_freq * rip2_ratio + 0.37;
	return vec2(ph1, ph2);
}

// aa: x = 主垄基频，y = 主垄二次谐波，z = 细纹
float rip_h(vec2 p, vec3 aa) {
	vec2 ph = rip_phase(p);
	float s1 = 6.2831853 * ph.x;
	float s2 = 6.2831853 * ph.y;
	float h = sin(s1) * aa.x + rip_skew * sin(2.0 * s1) * aa.y + rip2_amt * sin(s2) * aa.z;
	float amp = smoothstep(rip_patch_lo, rip_patch_hi, fbm3(p * rip_patch_scale + 5.0));
	if (rip_break > 0.0) {
		vec2 wd = normalize(wind_dir);
		vec2 bq = vec2(dot(p, vec2(-wd.y, wd.x)) * rip_break_scale, dot(p, wd) * rip_break_scale * 0.35);
		amp *= mix(1.0, smoothstep(0.28, 0.72, noise21(bq + 31.7)), rip_break);
	}
	return h * amp / (1.0 + rip_skew + rip2_amt);
}

float schlick5(float u) {
	float m = clamp(1.0 - u, 0.0, 1.0);
	float m2 = m * m;
	return m2 * m2 * m;
}

vec3 hue3(float h) {
	return clamp(abs(fract(h + vec3(0.0, 0.6667, 0.3333)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 n_geo = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 base = albedo;
	float dist = length(v_world - CAMERA_POSITION_WORLD);
	vec3 n_w = n_geo;
	vec2 p = v_world.xz;

	if (macro_amount > 0.0) {
		float mac = fbm3(p * macro_scale + 7.1);
		vec3 mt = mix(hollow_tint, crest_tint, smoothstep(0.3, 0.7, mac));
		base *= mix(vec3(1.0), mt, macro_amount);
	}
	if (facet_jitter > 0.0) {
		float fh = hash21(floor(n_geo.xz * 331.0) + floor(n_geo.y * 173.0));
		base *= 1.0 + (fh - 0.5) * 2.0 * facet_jitter;
	}
	if (detail > 0.0) {
		vec2 ph = rip_phase(p);
		vec2 fw = fwidth(ph);
		vec3 aa = vec3(1.0 - smoothstep(aa_lo, aa_hi, fw.x), 1.0 - smoothstep(aa_lo, aa_hi, 2.0 * fw.x), 1.0 - smoothstep(aa_lo, aa_hi, fw.y));
		float fade = detail * (1.0 - smoothstep(detail_near, detail_far, dist));
		aa *= fade;
		if (aa.x + aa.z > 0.001) {
			float e = 0.004;
			float h0 = rip_h(p, aa);
			float hx = rip_h(p + vec2(e, 0.0), aa);
			float hz = rip_h(p + vec2(0.0, e), aa);
			vec2 g = vec2(hx - h0, hz - h0) / e;
			vec2 tilt = g * rip_slope / (6.2831853 * rip_freq);
			n_w = normalize(n_geo - vec3(tilt.x, 0.0, tilt.y));
			base *= 1.0 + rip_tone * h0;
			base *= mix(vec3(1.0), mix(hollow_tint, crest_tint, clamp(0.5 + 0.5 * h0 * 1.6, 0.0, 1.0)), rip_tint_amount * max(aa.x, aa.z));
		}
	}
	ALBEDO = base;
	NORMAL = normalize((VIEW_MATRIX * vec4(n_w, 0.0)).xyz);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.5;

	// ---- 闪粉：固定参考机位的角度格（≈ 1080p 像素格），世界锁定 ----
	v_glit = 0.0;
	v_glit_n = NORMAL;
	v_glit_col = vec3(1.0);
	if (glit_sun + glit_point > 0.0) {
		vec3 rel = v_world - ref_cam_pos;
		vec2 fwd = normalize(ref_cam_fwd);
		vec2 right = vec2(-fwd.y, fwd.x);
		float hd = length(rel.xz);
		vec2 q = vec2(atan(dot(rel.xz, right), dot(rel.xz, fwd)), atan(-rel.y, hd)) / (ref_rad_per_px * glit_cell_px);
		vec2 dqx = dFdx(q);
		vec2 dqy = dFdy(q);
		float px_per_cell = inversesqrt(max(abs(dqx.x * dqy.y - dqx.y * dqy.x), 1e-8));
		float nearness = 1.0 - smoothstep(glit_near, glit_far, dist);
		float dens = glit_density * mix(glit_far_keep, 1.0, nearness);
		float rad = mix(glit_size_far, glit_size_near, nearness);
		vec2 cell0 = floor(q);
		vec2 f0 = fract(q);
		float best = 0.0;
		vec2 best_cell = cell0;
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				vec2 c = cell0 + vec2(float(i), float(j));
				if (hash21(c + 0.37) < dens) {
					vec2 ctr = vec2(float(i), float(j)) + vec2(hash21(c + 1.7), hash21(c + 9.1));
					float dpx = length(f0 - ctr) * px_per_cell;
					float s = exp(-dpx * dpx / (rad * rad));
					if (s > best) {
						best = s;
						best_cell = c;
					}
				}
			}
		}
		if (best > 0.002) {
			vec2 c = best_cell;
			vec3 rn = vec3(hash21(c + 2.3), hash21(c + 4.4), hash21(c + 6.6)) * 2.0 - 1.0;
			float t = anim_t * glit_speed;
			float p1 = hash21(c + 8.8) * 6.2831853;
			float p2 = hash21(c + 3.9) * 6.2831853;
			rn = normalize(rn + glit_wobble * vec3(sin(t + p1), sin(t * 0.83 + p2), cos(t * 1.13 + p1)));
			float side = dot(rn, n_geo);
			if (side < 0.0) {
				rn -= 2.0 * side * n_geo;
			}
			float br = 0.35 + 0.65 * hash21(c + 5.5);
			float tw = mix(1.0, 0.5 + 0.5 * sin(anim_t * glit_speed * 2.3 + p2 * 3.0), glit_twinkle);
			v_glit = best * br * tw;
			v_glit_n = normalize((VIEW_MATRIX * vec4(rn, 0.0)).xyz);
			v_glit_col = mix(vec3(1.0), hue3(hash21(c + 7.7)) * 1.4 + 0.2, glit_prism);
		}
	}

	if (vr_strength + vr_glit > 0.0) {
		vec3 vw = normalize(CAMERA_POSITION_WORLD - v_world);
		vec3 gn = normalize((INV_VIEW_MATRIX * vec4(v_glit_n, 0.0)).xyz);
		vec3 acc = vec3(0.0);
		vec3 nv = normalize(mix(n_w, vec3(0.0, 1.0, 0.0), vr_flat));
		for (int i = 0; i < 6; i++) {
			vec3 col = vr_col[i];
			if (col.r + col.g + col.b <= 0.0001) {
				continue;
			}
			col = mix(col, vr_color * max(col.r, max(col.g, col.b)), vr_recolor);
			vec3 lv = vr_pos[i] - v_world;
			float d2 = dot(lv, lv);
			vec3 l = lv * inversesqrt(max(d2, 1e-6));
			vec3 hh = normalize(l + vw);
			float ndh = max(dot(nv, hh), 0.0);
			float vdh = clamp(dot(vw, hh), 0.0, 1.0);
			float fres = vr_f0 + (1.0 - vr_f0) * schlick5(vdh);
			float lit = smoothstep(-0.02, 0.15, dot(nv, l));
			float fall = 1.0 / (1.0 + d2 / (vr_radius * vr_radius));
			float lobe = pow(ndh, vr_power) * (vr_power + 2.0) / 8.0;
			float gl = v_glit * smoothstep(glit_cone, 1.0, dot(gn, hh));
			acc += col * lit * fall * (lobe * fres * vr_strength + gl * gl * vr_glit * v_glit_col);
		}
		EMISSION = acc * vr_tint;
	}
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float cndl = max(ndl, 0.0);
	vec3 h = normalize(VIEW + LIGHT);
	// 漫反射：Godot DIFFUSE_BURLEY 原样（roughness 1）
	float cndv = max(dot(NORMAL, VIEW), 1e-4);
	float cldh = clamp(dot(LIGHT, h), 0.0, 1.0);
	float fd90m1 = 2.0 * cldh * cldh * ROUGHNESS - 0.5;
	float fb = (1.0 + fd90m1 * schlick5(cndv)) * (1.0 + fd90m1 * schlick5(cndl));
	float diff = cndl * mix(1.0, fb, burley);
	vec3 dtint = vec3(1.0);
	if (LIGHT_IS_DIRECTIONAL && sun_tint_amount > 0.0) {
		dtint = mix(vec3(1.0), mix(sun_cool, sun_warm, smoothstep(sun_tint_lo, sun_tint_hi, ndl)), sun_tint_amount);
	}
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * diff * dtint / PI;

	float ks = LIGHT_IS_DIRECTIONAL ? sheen_sun : sheen_point;
	if (ks > 0.0) {
		float pw = LIGHT_IS_DIRECTIONAL ? sheen_power_sun : sheen_power_point;
		float ndh = max(dot(NORMAL, h), 0.0);
		float vdh = clamp(dot(VIEW, h), 0.0, 1.0);
		float lobe = pow(ndh, pw) * (pw + 2.0) / 8.0;
		float fres = sheen_f0 + (1.0 - sheen_f0) * schlick5(vdh);
		float gate = smoothstep(-0.05, 0.25, ndl);
		if (LIGHT_IS_DIRECTIONAL && sheen_facet_fade > 0.0) {
			gate *= mix(1.0, smoothstep(0.15, 0.6, ndl), sheen_facet_fade);
		}
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * sheen_tint * lobe * fres * gate * ks / PI;
	}
	float kg = LIGHT_IS_DIRECTIONAL ? glit_sun : glit_point;
	if (kg > 0.0 && v_glit > 0.001) {
		float a = dot(v_glit_n, h);
		float g = smoothstep(glit_cone, 1.0, a);
		float up = smoothstep(-0.02, 0.12, ndl);
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * glit_tint * v_glit_col * g * g * up * v_glit * kg / PI;
	}
}
