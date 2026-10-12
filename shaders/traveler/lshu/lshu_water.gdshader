// L叔在哪儿 · L2 water shader for the "water" role (procedural lakes / sea and landmark pools).
// Opaque (the web water is opaque too), animated, one rule for every tile:
//  - procedural water (instance uniform l2_level set by lshu_surface_detail.gd): colour from the
//    CONTINUOUS depth (water level - terrain height from height_tex) instead of the web's three per-triangle
//    bands, so the shallow ring is smooth (no sawtooth); shore foam bands lap toward the shoreline.
//  - landmark pools (no level): keep their vertex colour; same waves / fresnel / glints.
//  - P0 fix #3, landmark pool tops (TEXCOORD_0 from tools/traveler/lshu/bake/landmark_water.cjs: x = horizontal
//    distance to the pool's shoreline, y = the pool's largest such distance, asset metres x instance scale):
//    pseudo depth = shoreline distance x l2_pool_slope through the same depth palette, the same shore foam
//    (never wider than l2_pool_foam_frac of the pool) and a ripple tone from the wave field. One rule, no per-tile values.
//  - both: two moving noise normal layers, sky fresnel (water_sky per light), sun glints on crests.
// Uniform names shared with lshu_surface.gdshader keep working (water_sky, water_fresnel, water_ripple, …).
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx, depth_draw_opaque;

uniform bool vertex_color_srgb = true;
uniform vec3 albedo_tint : source_color = vec3(1.0);
uniform float albedo_gain = 1.0;
uniform float saturation = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.23;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular_amount : hint_range(0.0, 1.0) = 0.15;
uniform float emission_strength = 0.0;
uniform vec3 emission_tint : source_color = vec3(1.0);
uniform float water_mode = 1.0;
uniform vec3 water_sky : source_color = vec3(0.8, 0.9, 0.95);
uniform float water_fresnel = 0.35;
uniform float water_ripple = 0.05;
uniform float anim_time = 0.0;
uniform float wind_strength = 0.0;
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform vec4 height_rect = vec4(-4.0, -4.0, 8.0, 8.0);
uniform float height_grid_n = 53.0;

// ---- L2 water
uniform vec3 l2_shallow : source_color = vec3(0.56, 0.80, 0.79);   // web #8fcdca
uniform vec3 l2_mid : source_color = vec3(0.33, 0.67, 0.70);       // web #53aab3
uniform vec3 l2_deep : source_color = vec3(0.22, 0.54, 0.59);      // web #388996
uniform float l2_depth_mid = 0.09;
uniform float l2_depth_deep = 0.34;
uniform float l2_depth_mix = 1.0;           // 0 = web vertex colour, 1 = continuous depth colour
uniform float l2_foam = 0.0;                // shore foam strength
uniform float l2_foam_width = 0.05;         // metres (horizontal, from the shoreline) of the foam line
uniform float l2_foam_bands = 0.0;          // moving bands beyond the line
uniform float l2_foam_speed = 0.35;
uniform vec3 l2_foam_color : source_color = vec3(0.93, 0.98, 0.95);
uniform float l2_wave = 0.0;                // noise normal strength
uniform float l2_wave_scale = 3.2;
uniform float l2_wave_speed = 0.22;
uniform float l2_shimmer = 0.0;             // caustic-like brightness shimmer in the shallows
uniform float l2_glint = 0.0;               // sun glints on crests
uniform float l2_glint_scale = 16.0;
uniform float l2_glint_density = 0.08;
uniform float l2_glint_roughness = 0.12;
uniform vec3 l2_sun_dir = vec3(-0.5, 0.8, 0.4);
instance uniform float l2_level = -100.0;   // procedural water level; -100 = landmark pool
// ---- landmark pools (fix #3)
uniform float l2_pool_slope = 0.8;         // pseudo depth (m) per metre of distance from the pool's shoreline
uniform float l2_pool_depth_mix = 0.75;    // 0 = the landmark's own water colour, 1 = the depth palette above
uniform float l2_pool_foam = 0.45;         // shore foam line on pools, x l2_foam
uniform float l2_pool_bands = 0.0;         // moving foam bands on pools, x l2_foam_bands (0 = line only)
uniform float l2_pool_foam_frac = 0.15;    // pool foam line width <= this fraction of the pool's largest shore distance
uniform float l2_pool_ripple = 0.12;       // brightness ripple from the wave field on pool tops (0 = normals only)

varying vec3 v_world;
varying vec3 v_wn;
varying float v_shore;      // landmark pools: metres to the shoreline
varying float v_pool_r;     // landmark pools: the pool's largest shoreline distance (0 = not a pool top)

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}
float vnoise2(vec2 q) {
	vec3 p = vec3(q.x, 0.37, q.y);
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i), n100 = hash13(i + vec3(1, 0, 0)), n010 = hash13(i + vec3(0, 1, 0)), n110 = hash13(i + vec3(1, 1, 0));
	float n001 = hash13(i + vec3(0, 0, 1)), n101 = hash13(i + vec3(1, 0, 1)), n011 = hash13(i + vec3(0, 1, 1)), n111 = hash13(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y), mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}
float terrain_at(vec2 xz) {
	vec2 uv = (xz - height_rect.xy) / height_rect.zw;
	uv = uv * ((height_grid_n - 1.0) / height_grid_n) + 0.5 / height_grid_n;
	return texture(height_tex, uv).r;
}
float wave_h(vec2 p, float t) {
	return vnoise2(p * l2_wave_scale + vec2(t * l2_wave_speed, t * l2_wave_speed * 0.6)) * 0.6
		+ vnoise2(p * l2_wave_scale * 2.3 + vec2(-t * l2_wave_speed * 1.3, t * l2_wave_speed * 0.9) + 5.0) * 0.4;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float sc = length(MODEL_MATRIX[0].xyz);
	v_shore = UV.x * sc;
	v_pool_r = UV.y * sc;
}

void fragment() {
	vec3 base = vertex_color_srgb ? srgb_to_linear(COLOR.rgb) : COLOR.rgb;
	bool top = abs(v_wn.y) > 0.55;
	float depth = 1.0;
	bool procedural = l2_level > -50.0;
	float shore_d = 10.0;   // horizontal distance to the shoreline (depth / terrain slope)
	if (procedural) {
		depth = l2_level - terrain_at(v_world.xz);
		float e = height_rect.z / (height_grid_n - 1.0) * 0.5;
		vec2 g = vec2(terrain_at(v_world.xz + vec2(e, 0.0)) - terrain_at(v_world.xz - vec2(e, 0.0)),
			terrain_at(v_world.xz + vec2(0.0, e)) - terrain_at(v_world.xz - vec2(0.0, e))) / (2.0 * e);
		shore_d = max(depth, 0.0) / max(length(g), 0.04);
		vec3 dc = mix(l2_shallow, l2_mid, smoothstep(0.0, l2_depth_mid, depth));
		dc = mix(dc, l2_deep, smoothstep(l2_depth_mid, l2_depth_deep, depth));
		base = mix(base, dc, l2_depth_mix);
	}
	bool pool = !procedural && v_pool_r > 0.0;
	if (pool) {
		shore_d = max(v_shore, 0.0);
		depth = shore_d * l2_pool_slope;
		vec3 pc = mix(l2_shallow, l2_mid, smoothstep(0.0, l2_depth_mid, depth));
		pc = mix(pc, l2_deep, smoothstep(l2_depth_mid, l2_depth_deep, depth));
		base = mix(base, pc, l2_pool_depth_mix);
	}
	base *= albedo_tint * albedo_gain;
	float lum = dot(base, vec3(0.2126, 0.7152, 0.0722));
	base = max(mix(vec3(lum), base, saturation), vec3(0.0));

	float t = anim_time;
	vec3 wn = vec3(0.0, 1.0, 0.0);
	float crest = 0.0;
	if (l2_wave > 0.0) {
		float e = 0.035;
		float h0 = wave_h(v_world.xz, t);
		float hx = wave_h(v_world.xz + vec2(e, 0.0), t);
		float hz = wave_h(v_world.xz + vec2(0.0, e), t);
		wn = normalize(vec3(-(hx - h0) / e * l2_wave * 0.05, 1.0, -(hz - h0) / e * l2_wave * 0.05));
		crest = h0;
	} else {
		wn = normalize(vec3(sin(v_world.z * 7.0 + v_world.x * 2.0 + t * 0.7) * water_ripple, 1.0, cos(v_world.x * 6.0 - t * 0.55) * water_ripple * 1.4));
	}
	vec3 n_view = NORMAL;
	float rough = roughness;
	float spec = specular_amount;
	if (water_mode > 0.5 && top) {
		n_view = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
		NORMAL = n_view;
		float fres = pow(1.0 - clamp(dot(n_view, VIEW), 0.0, 1.0), 5.0);
		base = mix(base, water_sky, clamp(water_fresnel * (0.25 + fres), 0.0, 1.0));
		if (l2_shimmer > 0.0) {
			float c1 = vnoise2(v_world.xz * 9.0 + vec2(t * 0.31, -t * 0.23));
			float c2 = vnoise2(v_world.xz * 9.0 * 1.37 + vec2(-t * 0.27, t * 0.19) + 3.3);
			float caustic = pow(1.0 - abs(c1 - c2), 6.0);
			float shallow_w = (procedural || pool) ? 1.0 - smoothstep(0.02, 0.22, depth) : 0.5;
			base *= 1.0 + caustic * l2_shimmer * shallow_w;
		}
		if (pool && l2_pool_ripple > 0.0) {
			base *= 1.0 + (crest - 0.5) * l2_pool_ripple;
		}
		float fw = procedural ? l2_foam_width : min(l2_foam_width, v_pool_r * l2_pool_foam_frac);
		float fstr = procedural ? l2_foam : l2_foam * l2_pool_foam;
		if (fstr > 0.0 && (procedural || pool)) {
			float n = vnoise2(v_world.xz * 7.0 + vec2(t * 0.05, 0.0));
			float line = 1.0 - smoothstep(fw * (0.5 + 0.6 * n), fw * (0.85 + 0.6 * n), shore_d);
			float bands = 0.0;
			float fbands = procedural ? l2_foam_bands : l2_foam_bands * l2_pool_bands;
			if (fbands > 0.0) {
				float ph = shore_d / fw * 2.2 + t * l2_foam_speed * 6.28 + n * 2.5;
				float b = smoothstep(0.75, 0.97, sin(ph));
				bands = b * (1.0 - smoothstep(fw * 1.2, fw * 4.0, shore_d)) * smoothstep(0.35, 0.65, vnoise2(v_world.xz * 3.0 - t * 0.1)) * fbands;
			}
			float foam = clamp(line + bands, 0.0, 1.0) * fstr;
			base = mix(base, l2_foam_color, foam);
			rough = mix(rough, 0.8, foam);
			spec = mix(spec, 0.1, foam);
		}
		if (l2_glint > 0.0) {
			vec2 cell = floor(v_world.xz * l2_glint_scale);
			float h1 = hash13(vec3(cell, floor(t * 0.9 + hash13(vec3(cell, 4.0)) * 3.0)));
			float on = step(1.0 - l2_glint_density, h1) * smoothstep(0.45, 0.75, crest);
			if (on > 0.0) {
				vec2 f = fract(v_world.xz * l2_glint_scale) - 0.5;
				float dotm = (1.0 - smoothstep(0.08, 0.3, length(f * vec2(1.0, 1.8)))) * on;
				vec3 cam_w = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
				vec3 hv = normalize(normalize(l2_sun_dir) + normalize(cam_w - v_world));
				vec3 gn = normalize((VIEW_MATRIX * vec4(hv, 0.0)).xyz);
				n_view = normalize(mix(n_view, gn, dotm));
				NORMAL = n_view;
				rough = mix(rough, l2_glint_roughness, dotm);
				spec = mix(spec, 1.0, dotm * clamp(l2_glint, 0.0, 1.0));
			}
		}
	}
	ALBEDO = base;
	ROUGHNESS = rough;
	METALLIC = metallic;
	SPECULAR = spec;
	EMISSION = base * emission_strength * emission_tint;
}
