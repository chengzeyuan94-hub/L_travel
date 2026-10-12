// L叔在哪儿 · shared surface shader (approved probe L2 surface detail). A superset of the probe base shader: every uniform and
// code path is kept (baseline values reproduce the baseline look); the L2 blocks below are all gated by
// uniforms that default to 0. Used for every opaque role; per-role behaviour comes only from look.json
// surface.roles.<role> values, never from tile ids.
//   ground : smoothed cell colour (kills the per-triangle stripes / sawtooth), material-class grain
//            (grass / sand / snow / wet decided from the ground colour itself), patches, sand ripples,
//            path grain + worn border (from the path distance map), slope earth tint, valley shade, glints
//   skirt / cliff : strata lines + grain, ground-coloured lip on the tile rim, darker toward the bottom
//   assets : base-to-top gradient above the terrain (facet-preserving: lighting stays per facet), facet jitter
//   glow   : window glass by day, warm flicker at night
//   *      : crease highlight when the mesh carries CUSTOM0 barycentrics (scripts/traveler/lshu/lshu_edges.gd (import time))
// Maps are bound by lshu_surface_detail.gd: l2_ground_col_tex (52x52 cell colours, sRGB-encoded like
// COLOR_0), l2_path_tex (R = distance to the nearest path centreline / path width), l2_sun_dir.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx, depth_draw_opaque;

// ---- colour
uniform bool vertex_color_srgb = true;
uniform vec3 albedo_tint : source_color = vec3(1.0);
uniform float albedo_gain = 1.0;
uniform float saturation = 1.0;
// ---- response
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular_amount : hint_range(0.0, 1.0) = 0.25;
uniform float emission_strength = 0.0;   // glow role; per light preset
uniform vec3 emission_tint : source_color = vec3(1.0);
// ---- world-space detail (assets have no UVs)
uniform float noise_amount = 0.0;
uniform float noise_scale = 2.5;
uniform float facet_jitter = 0.0;
// ---- rim / fresnel light
uniform float rim_strength = 0.0;
uniform float rim_power = 4.0;
uniform vec3 rim_color : source_color = vec3(1.0);
// ---- contact AO from the tile height field (viewer binds height_tex / height_rect)
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform vec4 height_rect = vec4(-4.0, -4.0, 8.0, 8.0);
uniform float height_grid_n = 53.0;
uniform float contact_ao = 0.0;
uniform float contact_ao_height = 0.35;
uniform float ao_light_affect = 0.0;
// ---- height tint
uniform float top_tint_amount = 0.0;
uniform vec3 top_tint : source_color = vec3(1.0);
// ---- water (kept for roles that still use the old water path)
uniform float water_mode = 0.0;
uniform vec3 water_sky : source_color = vec3(0.8, 0.9, 0.95);
uniform float water_fresnel = 0.35;
uniform float water_ripple = 0.05;
// ---- wind / time
uniform float anim_time = 0.0;
uniform float wind_strength = 0.0;
instance uniform float sway = 0.0;
instance uniform float sway_phase = 0.0;

// ==== L2 ================================================================================================
// maps (bound by lshu_surface_detail.gd; l2_maps_ready = 0 until then)
uniform sampler2D l2_ground_col_tex : filter_linear, repeat_disable;
uniform sampler2D l2_path_tex : filter_linear, repeat_disable;
uniform float l2_maps_ready = 0.0;
uniform vec3 l2_sun_dir = vec3(-0.5, 0.8, 0.4);        // world direction toward the sun (per light)
uniform vec2 l2_ground_range = vec2(0.0, 1.0);         // tile ground min / max height (from the recipe)
// ground
uniform float l2_ground_smooth = 0.0;     // 0 = web per-triangle colour, 1 = smoothed cell colour
uniform float l2_smooth_normal = 0.0;     // ground: lean the facet normal toward the height-field normal (kills stripe shading)
uniform float l2_glint_sand = 0.35;       // glint weight on sand relative to snow
uniform float l2_grain = 0.0;             // fine grain amplitude (per class multipliers below)
uniform float l2_grain_scale = 24.0;
uniform vec4 l2_grain_class = vec4(1.0, 0.7, 0.45, 0.8);  // grass, sand, snow, wet
uniform float l2_patch = 0.0;             // low-frequency patches (brightness)
uniform float l2_patch_scale = 0.75;
uniform float l2_patch_hue = 0.0;         // grass patches drift toward dry / lush
uniform vec3 l2_dry_tint : source_color = vec3(1.0, 0.93, 0.72);
uniform vec3 l2_lush_tint : source_color = vec3(0.86, 1.0, 0.86);
uniform float l2_sand_ripple = 0.0;
uniform float l2_sand_ripple_scale = 16.0;
uniform float l2_path_detail = 0.0;       // pebble speckle inside paths
uniform float l2_path_edge = 0.0;         // darker worn rim along the path border
uniform float l2_slope_tint = 0.0;        // steep ground turns earthy
uniform vec3 l2_slope_color : source_color = vec3(0.86, 0.76, 0.64);
uniform float l2_valley = 0.0;            // low ground slightly darker / cooler, high ground lighter
uniform vec3 l2_valley_tint : source_color = vec3(0.9, 0.93, 1.0);
uniform float l2_glint = 0.0;             // snow / sand glints (sun-facing micro facets)
uniform float l2_glint_scale = 34.0;
uniform float l2_glint_density = 0.06;
uniform float l2_glint_roughness = 0.3;
// sand class at night (P0 fix #5): cancel part of the night light's colour cast on the sand albedo so sand keeps about
// half its daytime chroma (warm sand under a blue night) instead of greying out. 0 = off (every light but night).
uniform float l2_sand_counter = 0.0;     // strength: albedo *= (lum(cast) / cast)^l2_sand_counter, sand class only
uniform vec3 l2_sand_cast : source_color = vec3(1.0);  // colour cast to counter (look.json: the night key light colour)
// skirt / cliff
uniform float l2_strata = 0.0;
uniform float l2_strata_freq = 38.0;
uniform float l2_lip = 0.0;               // ground-coloured lip at the top of the skirt
uniform float l2_lip_height = 0.04;
uniform float l2_bottom_dark = 0.0;       // skirt / cliff darker toward the bottom
uniform float l2_bottom_y = -0.83;
// assets: base-to-top gradient above the terrain
uniform float l2_height_grad = 0.0;
uniform float l2_height_grad_range = 0.9;
uniform vec3 l2_base_tint : source_color = vec3(0.86, 0.85, 0.92);
uniform float l2_top_light = 0.0;         // upward facets lifted a little (sky light on tops)
// water side walls (proc water_side)
uniform float l2_side_depth = 0.0;
uniform float l2_water_level = 0.0;
// glow
uniform float l2_glow_glass = 0.0;        // albedo toward glass (day)
uniform vec3 l2_glass_color : source_color = vec3(0.24, 0.29, 0.34);
uniform float l2_glow_flicker = 0.0;
// crease highlight (needs CUSTOM0 = barycentric xyz + edge mask w, see lshu_edges.gd)
uniform float l2_edge = 0.0;
uniform float l2_edge_px = 1.1;
uniform vec3 l2_edge_color : source_color = vec3(1.0, 0.97, 0.9);
uniform float l2_edge_dark = 0.0;         // lower creases (facing down) darken instead

varying vec3 v_world;
varying vec3 v_world_normal;
varying vec4 v_bary;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i), n100 = hash13(i + vec3(1, 0, 0)), n010 = hash13(i + vec3(0, 1, 0)), n110 = hash13(i + vec3(1, 1, 0));
	float n001 = hash13(i + vec3(0, 0, 1)), n101 = hash13(i + vec3(1, 0, 1)), n011 = hash13(i + vec3(0, 1, 1)), n111 = hash13(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y), mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}
float vnoise2(vec2 p) {
	return vnoise(vec3(p.x, 0.37, p.y));
}
float terrain_at(vec2 xz) {
	vec2 uv = (xz - height_rect.xy) / height_rect.zw;
	uv = uv * ((height_grid_n - 1.0) / height_grid_n) + 0.5 / height_grid_n;
	return texture(height_tex, uv).r;
}
// Material class weights from an sRGB-encoded ground colour: x grass, y sand/earth, z snow, w wet/bed.
vec4 ground_class(vec3 c) {
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	float sat = (mx - mn) / max(mx, 1e-3);
	float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	float snow = smoothstep(0.74, 0.84, lum) * (1.0 - smoothstep(0.07, 0.16, sat));
	float grass = smoothstep(-0.015, 0.03, c.g - c.r) * smoothstep(0.07, 0.14, c.g - c.b) * (1.0 - snow);
	float wet = smoothstep(-0.01, 0.04, c.b - c.r) * (1.0 - snow) * (1.0 - grass);
	float sand = clamp(1.0 - grass - snow - wet, 0.0, 1.0);
	return vec4(grass, sand, snow, wet);
}
// P0 fix #5: sand-class counter-tint against the night colour cast (weight = sand class of the sRGB ground colour).
vec3 sand_counter(vec3 lin, vec3 srgb_src) {
	vec3 cast = max(l2_sand_cast, vec3(1e-3));
	vec3 wb = pow(vec3(dot(cast, vec3(0.2126, 0.7152, 0.0722))) / cast, vec3(l2_sand_counter));
	return mix(lin, lin * wb, ground_class(srgb_src).y);
}

void vertex() {
	if (sway > 0.0 && wind_strength > 0.0) {
		float h = max(VERTEX.y - 0.16, 0.0);
		float gust = sin(anim_time * 0.83 + sway_phase + VERTEX.z * 1.13 + VERTEX.x * 0.72) + 0.32 * sin(anim_time * 1.71 + VERTEX.x * 2.3 + sway_phase);
		VERTEX.x += gust * h * wind_strength * sway;
		VERTEX.z += cos(anim_time * 0.67 + VERTEX.x * 0.9 + sway_phase) * h * wind_strength * sway * 0.44;
	}
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_bary = CUSTOM0;
}

void fragment() {
	vec3 gn = v_world_normal;
	vec3 n_view = NORMAL;
	if (l2_smooth_normal > 0.0 && v_world_normal.y > 0.0) {
		float e = height_rect.z / (height_grid_n - 1.0) * 0.5;
		float hx0 = terrain_at(v_world.xz - vec2(e, 0.0));
		float hx1 = terrain_at(v_world.xz + vec2(e, 0.0));
		float hz0 = terrain_at(v_world.xz - vec2(0.0, e));
		float hz1 = terrain_at(v_world.xz + vec2(0.0, e));
		vec3 sn = normalize(vec3(hx0 - hx1, 2.0 * e, hz0 - hz1));
		gn = normalize(mix(v_world_normal, sn, l2_smooth_normal));
		n_view = normalize((VIEW_MATRIX * vec4(gn, 0.0)).xyz);
		NORMAL = n_view;
	}
	vec3 src = COLOR.rgb;
	float path_u = 1.0;
	if (l2_maps_ready > 0.5) {
		vec2 guv = (v_world.xz - height_rect.xy) / height_rect.zw;
		if (l2_ground_smooth > 0.0) {
			src = mix(src, texture(l2_ground_col_tex, guv).rgb, l2_ground_smooth);
		}
		path_u = texture(l2_path_tex, guv).r;
	}
	vec3 base = vertex_color_srgb ? srgb_to_linear(src) : src;
	base *= albedo_tint * albedo_gain;
	float lum = dot(base, vec3(0.2126, 0.7152, 0.0722));
	base = max(mix(vec3(lum), base, saturation), vec3(0.0));
	if (noise_amount > 0.0) {
		float n = vnoise(v_world * noise_scale) * 0.65 + vnoise(v_world * noise_scale * 2.7 + 7.1) * 0.35;
		base *= 1.0 + (n - 0.5) * 2.0 * noise_amount;
	}
	if (facet_jitter > 0.0) {
		float f = hash13(floor(v_world_normal * 17.0) + floor(v_world * 3.0) * 0.37);
		base *= 1.0 + (f - 0.5) * facet_jitter;
	}
	if (top_tint_amount > 0.0) {
		base = mix(base, base * top_tint, clamp(v_world_normal.y, 0.0, 1.0) * top_tint_amount);
	}

	// ---- L2 ground detail
	float glint = 0.0;
	vec3 glint_n = vec3(0.0, 1.0, 0.0);
	if (l2_grain > 0.0 || l2_patch > 0.0 || l2_sand_ripple > 0.0 || l2_glint > 0.0 || l2_slope_tint > 0.0 || l2_valley > 0.0 || l2_path_detail > 0.0 || l2_path_edge > 0.0) {
		vec4 cls = ground_class(src);
		float px = length(fwidth(v_world.xz));                 // metres per pixel here
		float path_core = 1.0 - smoothstep(0.40, 0.60, path_u); // inside the walked path
		float path_rim = smoothstep(0.42, 0.58, path_u) * (1.0 - smoothstep(0.62, 0.95, path_u));
		if (l2_patch > 0.0) {
			float p = vnoise2(v_world.xz * l2_patch_scale + 3.1) * 0.62 + vnoise2(v_world.xz * l2_patch_scale * 2.3 - 5.7) * 0.38;
			float pc = (p - 0.5) * 2.0;
			base *= 1.0 + pc * l2_patch * (1.0 - 0.6 * path_core);
			if (l2_patch_hue > 0.0) {
				vec3 tint = pc > 0.0 ? l2_dry_tint : l2_lush_tint;
				base = mix(base, base * tint, abs(pc) * l2_patch_hue * cls.x * (1.0 - path_core));
			}
		}
		if (l2_grain > 0.0) {
			float fade = 1.0 - smoothstep(0.35, 0.8, px * l2_grain_scale);
			float g = vnoise2(v_world.xz * l2_grain_scale) * 0.6 + vnoise2(v_world.xz * l2_grain_scale * 2.1 + 11.0) * 0.4;
			float amp = dot(cls, l2_grain_class) * l2_grain * fade;
			base *= 1.0 + (g - 0.5) * 2.0 * amp;
		}
		if (l2_sand_ripple > 0.0) {
			float warp = vnoise2(v_world.xz * 1.3) * 2.2;
			float r = sin((v_world.x * 0.55 + v_world.z * 0.84) * l2_sand_ripple_scale + warp * 3.0);
			float flat_w = smoothstep(0.86, 0.97, gn.y);
			float fade = 1.0 - smoothstep(0.3, 0.7, px * l2_sand_ripple_scale);
			base *= 1.0 + r * l2_sand_ripple * cls.y * flat_w * fade * (1.0 - path_core);
		}
		if (l2_path_detail > 0.0 && path_core > 0.0) {
			vec2 cell = floor(v_world.xz * 42.0);
			float h1 = hash13(vec3(cell, 3.3));
			vec2 f = fract(v_world.xz * 42.0) - 0.5;
			float dotm = (1.0 - smoothstep(0.18, 0.42, length(f))) * step(0.72, h1);
			float shade = (hash13(vec3(cell, 8.1)) > 0.5) ? 1.0 : -1.0;
			float fade = 1.0 - smoothstep(0.012, 0.03, px);
			base *= 1.0 + dotm * shade * 0.16 * l2_path_detail * path_core * fade;
			float g2 = vnoise2(v_world.xz * 11.0 + 2.0);
			base *= 1.0 + (g2 - 0.5) * 0.12 * l2_path_detail * path_core;
		}
		if (l2_path_edge > 0.0) {
			base *= 1.0 - path_rim * l2_path_edge;
		}
		if (l2_slope_tint > 0.0) {
			float steep = 1.0 - smoothstep(0.62, 0.88, gn.y);
			base = mix(base, base * l2_slope_color, steep * l2_slope_tint * (1.0 - cls.w) * (1.0 - cls.z * 0.5));
		}
		if (l2_valley > 0.0) {
			float t = clamp((v_world.y - l2_ground_range.x) / max(l2_ground_range.y - l2_ground_range.x, 0.05), 0.0, 1.0);
			float k = (smoothstep(0.0, 1.0, t) - 0.5) * 2.0;          // -1 low .. +1 high, zero-mean
			base *= 1.0 + 0.4 * l2_valley * k;
			base = mix(base, base * l2_valley_tint, l2_valley * max(-k, 0.0) * 2.0);
		}
		if (l2_glint > 0.0) {
			float wgl = cls.z + cls.y * l2_glint_sand;
			vec2 cell = floor(v_world.xz * l2_glint_scale);
			float h1 = hash13(vec3(cell, 17.7));
			if (wgl > 0.2 && h1 > 1.0 - l2_glint_density * wgl) {
				vec2 f = fract(v_world.xz * l2_glint_scale) - 0.5;
				glint = (1.0 - smoothstep(0.12, 0.34, length(f))) * (1.0 - path_core);
				vec3 cam_w = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
				vec3 hv = normalize(normalize(l2_sun_dir) + normalize(cam_w - v_world));
				vec3 jit = vec3(hash13(vec3(cell, 1.3)) - 0.5, 0.0, hash13(vec3(cell, 2.9)) - 0.5) * 0.35;
				glint_n = normalize(hv + jit);
			}
		}
	}
	// ---- sand class at night (P0 fix #5)
	if (l2_sand_counter > 0.0) {
		base = sand_counter(base, src);
	}
	// ---- L2 skirt / cliff layers
	if (l2_strata > 0.0 || l2_lip > 0.0 || l2_bottom_dark > 0.0) {
		float side = 1.0 - smoothstep(0.35, 0.7, abs(v_world_normal.y));
		if (l2_strata > 0.0) {
			float wob = vnoise(v_world * 2.1) * 0.05 + vnoise(v_world * 7.0) * 0.012;
			float s = sin((v_world.y + wob) * l2_strata_freq) * 0.6 + sin((v_world.y + wob * 1.7) * l2_strata_freq * 2.63 + 1.3) * 0.4;
			float g = vnoise(v_world * 26.0) - 0.5;
			base *= 1.0 + (s * 0.5 + g * 0.6) * l2_strata * side;
		}
		if (l2_bottom_dark > 0.0) {
			base *= mix(1.0 - l2_bottom_dark, 1.0, smoothstep(l2_bottom_y, l2_bottom_y + 0.9, v_world.y));
		}
		if (l2_lip > 0.0 && l2_maps_ready > 0.5) {
			vec2 xz = clamp(v_world.xz, height_rect.xy + 0.001, height_rect.xy + height_rect.zw - 0.001);
			float top = terrain_at(xz);
			float wob = (vnoise(vec3(v_world.xz * 9.0, 0.0).xzy) - 0.5) * l2_lip_height * 0.9;
			float lip = 1.0 - smoothstep(l2_lip_height * 0.6, l2_lip_height, top - v_world.y + wob);
			vec2 guv = (xz - height_rect.xy) / height_rect.zw;
			vec3 gcol = srgb_to_linear(texture(l2_ground_col_tex, guv).rgb) * 0.88;
			base = mix(base, gcol, lip * l2_lip * side);
		}
	}
	// ---- L2 water side walls: darker with depth below the water line
	if (l2_side_depth > 0.0) {
		base *= mix(1.0, 0.55, clamp((l2_water_level - v_world.y) / 0.7, 0.0, 1.0) * l2_side_depth);
	}

	float ao = 1.0;
	float above = 10.0;
	if (contact_ao > 0.0 || l2_height_grad > 0.0) {
		above = v_world.y - terrain_at(v_world.xz);
	}
	if (contact_ao > 0.0) {
		ao = 1.0 - contact_ao * (1.0 - smoothstep(0.0, contact_ao_height, above));
	}
	// ---- L2 asset gradient (colour only; facets keep their own lighting)
	if (l2_height_grad > 0.0) {
		float t = smoothstep(0.0, l2_height_grad_range, above);
		base = mix(base * mix(vec3(1.0), l2_base_tint, l2_height_grad), base, t);
	}
	if (l2_top_light > 0.0) {
		base *= 1.0 + l2_top_light * smoothstep(0.55, 0.95, v_world_normal.y);
	}
	// ---- L2 crease highlight
	float edge_mask = 0.0;
	if (l2_edge > 0.0 && v_bary.w > 0.5) {
		int bits = int(v_bary.w + 0.5) - 1;
		vec3 b = v_bary.xyz;
		vec3 fw = max(fwidth(b), vec3(1e-5));
		vec3 d = b / fw;   // pixels to each edge
		float e = 1e5;
		if ((bits & 1) != 0) e = min(e, d.x);
		if ((bits & 2) != 0) e = min(e, d.y);
		if ((bits & 4) != 0) e = min(e, d.z);
		edge_mask = 1.0 - smoothstep(l2_edge_px * 0.5, l2_edge_px, e);
		float up = clamp(v_world_normal.y * 0.5 + 0.5, 0.0, 1.0);
		vec3 bright = base * (1.0 + l2_edge) + l2_edge_color * 0.02 * l2_edge;
		base = mix(base, mix(base * (1.0 - l2_edge_dark), bright, smoothstep(0.25, 0.6, up)), edge_mask);
	}

	float rough = roughness;
	float spec = specular_amount;
	if (water_mode > 0.5 && v_world_normal.y > 0.55) {
		vec3 wn = normalize(vec3(sin(v_world.z * 7.0 + v_world.x * 2.0 + anim_time * 0.7) * water_ripple, 1.0, cos(v_world.x * 6.0 - anim_time * 0.55) * water_ripple * 1.4));
		n_view = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
		NORMAL = n_view;
		float fres = pow(1.0 - clamp(dot(n_view, VIEW), 0.0, 1.0), 5.0);
		base = mix(base, srgb_to_linear(water_sky), clamp(water_fresnel * (0.25 + fres), 0.0, 1.0));
	}
	if (glint > 0.0) {
		vec3 glint_view = normalize((VIEW_MATRIX * vec4(glint_n, 0.0)).xyz);
		n_view = normalize(mix(n_view, glint_view, glint));
		NORMAL = n_view;
		rough = mix(rough, l2_glint_roughness, glint);
		spec = mix(spec, 1.0, glint * clamp(l2_glint, 0.0, 1.0));
	}
	// ---- L2 glow: glass by day, flicker at night
	vec3 emission = base * emission_strength * emission_tint;
	if (l2_glow_glass > 0.0) {
		base = mix(base, l2_glass_color, l2_glow_glass);
		rough = mix(rough, 0.18, l2_glow_glass);
		spec = mix(spec, 0.6, l2_glow_glass);
	}
	if (l2_glow_flicker > 0.0) {
		float ph = hash13(floor(v_world * 1.7)) * 6.28;
		emission *= 1.0 + l2_glow_flicker * (sin(anim_time * 5.3 + ph) * 0.6 + sin(anim_time * 12.7 + ph * 1.9) * 0.4);
	}
	ALBEDO = base;
	AO = ao;
	AO_LIGHT_AFFECT = ao_light_affect;
	ROUGHNESS = rough;
	METALLIC = metallic;
	SPECULAR = spec;
	if (rim_strength > 0.0) {
		float r = pow(1.0 - clamp(dot(n_view, VIEW), 0.0, 1.0), rim_power);
		emission += rim_color * r * rim_strength * ao;
	}
	EMISSION = emission;
}
