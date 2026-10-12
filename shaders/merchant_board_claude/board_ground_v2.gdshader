// Merchant board (Claude sample) — ground, 1:1 with the owner's concept
// (Carlos 2026-09-24: 「具体的纹理和起伏，1:1参考概念图设计」).
// The concept's ground texture IS its low-poly faceting: big flat-shaded triangles tilted a
// few degrees each way, so neighbouring facets catch the light differently, over soft
// large-scale colour drift. No ripples, speckles, fields or roads. The facets come from the
// mesh (build_board.py ground_relief + a ~1.1 u jittered ground mesh); this shader shows
// them flat, adds the soft colour drift, and lays stone paving under the cities from the
// baked board texture (B channel of ground_detail.png).
shader_type spatial;

uniform float flat_amount : hint_range(0.0, 1.0) = 1.0;
uniform float drift_amount = 0.08;
uniform sampler2D detail_tex : filter_linear_mipmap, repeat_disable;
uniform vec4 board_rect = vec4(0.0, 0.0, 128.0, 59.63);
// Direction the sun's light travels (set by the review scene). Facets turned away from
// it take the concept's shade colours in their albedo: deep green on grass, orange-brown on
// sand, instead of the khaki the warm fill alone gives.
uniform vec3 sun_dir = vec3(0.69, -0.72, 0.09);
uniform vec3 grass_shade : source_color = vec3(0.43, 0.51, 0.16);
uniform vec3 sand_shade : source_color = vec3(0.84, 0.66, 0.34);
uniform float shade_tint = 0.55;
// Drifting cloud shadows over the whole board and the passing shower's shadow / wet ground
// (x, z, radius, strength; set by tools/merchant_board_claude_life.gd).
uniform float cloud_shadow = 0.16;
uniform vec2 cloud_wind = vec2(0.55, 0.12);
uniform vec4 storm = vec4(0.0, 0.0, 1.0, 0.0);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

// x: distance to the nearest feature point, y: distance to the cell border, z: cell hash
vec3 voronoi(vec2 p) {
	vec2 n = floor(p), f = fract(p);
	float md = 8.0;
	vec2 mr = vec2(0.0), mg = vec2(0.0);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));
			vec2 r = g + hash22(n + g) - f;
			float d = dot(r, r);
			if (d < md) { md = d; mr = r; mg = g; }
		}
	}
	float ed = 8.0;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			vec2 g = mg + vec2(float(i), float(j));
			vec2 r = g + hash22(n + g) - f;
			if (dot(mr - r, mr - r) > 1e-5) {
				ed = min(ed, dot(0.5 * (mr + r), normalize(r - mr)));
			}
		}
	}
	return vec3(sqrt(md), ed, hash12(n + mg));
}

float aa_fade(float feature, float px) {
	return 1.0 - smoothstep(0.4, 1.0, px * 2.5 / feature);
}

vec3 srgb(vec3 c) {
	return pow(c, vec3(2.2));
}

void fragment() {
	vec3 fn = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	NORMAL = normalize(mix(NORMAL, fn, flat_amount));
	vec2 p = wpos.xz;
	float px = max(length(dFdx(p)), length(dFdy(p)));
	vec3 wfn = normalize(cross(dFdy(wpos), dFdx(wpos)));
	float gentle_w = smoothstep(0.6, 0.8, abs(wfn.y));
	vec3 c = COLOR.rgb;
	float green = texture(detail_tex, (p - board_rect.xy) / board_rect.zw).r;
	float ndl = dot(wfn, -normalize(sun_dir));
	float shade = (1.0 - smoothstep(0.45, 0.85, ndl)) * gentle_w * shade_tint;
	float gw = smoothstep(0.45, 0.75, green);
	float sw = 1.0 - smoothstep(0.2, 0.45, green);
	c = mix(c, grass_shade * (0.8 + 0.4 * dot(c, vec3(0.33))), shade * gw);
	c = mix(c, sand_shade, shade * sw);
	// cloud shadows gliding over the land
	vec2 cp = p * 0.055 - cloud_wind * TIME * 0.02;
	float cn = vnoise(cp) * 0.6 + vnoise(cp * 2.1 + 3.7) * 0.4;
	c *= 1.0 - cloud_shadow * smoothstep(0.52, 0.72, cn);
	float sd = length((p - storm.xy) * vec2(1.0, 1.4)) / storm.z;
	c *= 1.0 - storm.w * (1.0 - smoothstep(0.35, 1.0, sd));
	// soft large-scale colour drift, as in the concept's painted ground
	float drift = vnoise(p * 0.35) * 0.65 + vnoise(p * 0.8 + 7.1) * 0.35 - 0.5;
	c *= 1.0 + drift * 2.0 * drift_amount * gentle_w;
	// stone paving under the cities
	float pave = texture(detail_tex, (p - board_rect.xy) / board_rect.zw).b;
	if (pave > 0.02) {
		vec3 v = voronoi(p * 4.2);
		vec3 stone = mix(srgb(vec3(0.84, 0.76, 0.64)), srgb(vec3(0.70, 0.63, 0.53)), v.z);
		stone = mix(stone, srgb(vec3(0.76, 0.72, 0.66)), step(0.7, hash12(vec2(v.z * 57.0, 1.0))) * 0.6);
		float grout = 1.0 - smoothstep(0.05, 0.11, v.y);
		stone = mix(stone, srgb(vec3(0.52, 0.46, 0.38)), grout * aa_fade(0.04, px));
		float pw = smoothstep(0.4, 0.6, pave + (vnoise(p * 3.0) - 0.5) * 0.3);
		c = mix(c, stone, pw * gentle_w);
	}
	ALBEDO = c;
	ROUGHNESS = 0.93;
}
