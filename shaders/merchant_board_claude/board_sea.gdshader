// Merchant board (Claude sample) — crystal-clear stylized sea.
// The seabed, coral and fish are real geometry below; this surface looks through
// them: real water thickness from the depth buffer drives Beer–Lambert absorption
// (clear turquoise over the sand shelf, deep blue over the drop-off), the view of
// the bottom is refracted by the faceted swell, and on top sit animated foam rings
// rolling to every shore, a breathing surf line, drifting light lines and glints.
// dist_tex: R = distance from the coast / 4 units, G = land mask (build_board.py).
shader_type spatial;
render_mode shadows_disabled, ambient_light_disabled, specular_schlick_ggx, cull_back;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D dist_tex : filter_linear, repeat_disable;
uniform vec4 board_rect = vec4(0.0, 0.0, 128.0, 59.63);
uniform vec3 absorb = vec3(1.3, 0.34, 0.18);        // per unit of water, red goes first
uniform vec3 shallow_tint : source_color = vec3(0.45, 0.95, 1.0);
// Concept colours (Carlos 2026-09-24 「浅海发白」→ 改): shallows ~(69,208,226) turquoise,
// open water ~(5,166,214), deep ~(2,131,201).
uniform vec3 shallow_color : source_color = vec3(0.0, 0.74, 0.86);
uniform vec3 deep_color : source_color = vec3(0.02, 0.3, 0.62);
uniform float shallow_mix = 0.85;
// The sea is emissive (unlit), so evening presets dim and tint it from the review scene.
uniform vec3 light_tint = vec3(1.0);
uniform vec3 foam_color : source_color = vec3(0.96, 0.99, 1.0);
uniform float refraction = 0.012;
uniform float foam_speed = 0.11;
uniform float ring_spacing = 0.95;
uniform float ring_reach = 0.8;
uniform float light_lines = 0.035;
uniform float glint_amount = 0.5;
uniform float swell = 0.025;

varying vec3 wpos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec2 hash2(vec2 p) { return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float cell_edge(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	float d1 = 8.0, d2 = 8.0;
	for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
		vec2 g = vec2(float(x), float(y));
		vec2 o = 0.5 + 0.35 * sin(TIME * 0.35 + 6.2831 * hash2(i + g));
		float d = length(g + o - f);
		if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
	}
	return d2 - d1;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += swell * (sin(wpos.x * 1.1 + TIME * 0.7) * cos(wpos.z * 0.9 - TIME * 0.5) - 1.0);
}

void fragment() {
	vec3 flat_n = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	NORMAL = flat_n;
	vec2 uv = (wpos.xz - board_rect.xy) / board_rect.zw;
	float d_shore = texture(dist_tex, uv).r * 4.0;

	// refracted view of the bottom (offset by the facet normal), guarded so we never
	// pull in pixels that are in front of the water
	vec2 off = (flat_n.xz) * refraction;
	vec2 suv = SCREEN_UV + off;
	float dz = textureLod(depth_tex, suv, 0.0).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(suv * 2.0 - 1.0, dz, 1.0);
	behind.xyz /= behind.w;
	if (behind.z > VERTEX.z) {
		suv = SCREEN_UV;
		dz = textureLod(depth_tex, suv, 0.0).r;
		behind = INV_PROJECTION_MATRIX * vec4(suv * 2.0 - 1.0, dz, 1.0);
		behind.xyz /= behind.w;
	}
	float thick = clamp(VERTEX.z - behind.z, 0.0, 20.0);
	vec3 bottom = textureLod(screen_tex, suv, 0.0).rgb;
	vec3 trans = exp(-absorb * thick);
	// Things just under the surface (coral tips, fish) keep their true colours; the
	// turquoise tint grows with depth, so the sand shelf reads clear turquoise.
	vec3 tint = mix(vec3(1.0), shallow_tint, smoothstep(0.08, 0.45, thick));
	vec3 water = bottom * tint * trans + deep_color * (vec3(1.0) - trans);
	// The white sand shelf read as milky water. Past the first few hundredths of a unit
	// the bottom only lends its brightness pattern (facets, caustics): the hue is the
	// concept's turquoise. Coral tips and fish right under the surface keep their colours.
	// The shallow band is measured from the coast (as in the concept: a turquoise band
	// ~1-2 u wide), not from the water depth, so open water keeps its absorbed blue.
	float lb = dot(bottom, vec3(0.3, 0.59, 0.11));
	vec3 turq = shallow_color * mix(0.8, 0.98, smoothstep(0.15, 0.85, lb));
	float band_w = max(1.0 - smoothstep(0.7, 2.0, d_shore), 1.0 - smoothstep(0.45, 0.9, thick));  // coastal band or any shallow shelf
	water = mix(water, turq, band_w * smoothstep(0.12, 0.45, thick) * shallow_mix);
	// Past the band, pull the per-pixel absorbed colour toward a spatially smooth
	// shallow -> mid -> deep ramp by distance from shore, so shelf drop-offs and seabed
	// pits no longer cut hard edges and holes into the turquoise band.
	vec3 mid_col = vec3(0.0, 0.26, 0.58);  // linear; dist_tex saturates at 4 u
	vec3 ramp = mix(mix(turq, mid_col, smoothstep(1.2, 2.6, d_shore)), deep_color, smoothstep(2.6, 4.0, d_shore));
	water = mix(water, ramp, (1.0 - band_w) * 0.55);

	// foam rings rolling toward the shore + breathing surf line
	float wob = vnoise(wpos.xz * 0.7 + vec2(TIME * 0.05, -TIME * 0.04));
	float ring = fract(d_shore * ring_spacing + TIME * foam_speed + wob * 0.45);
	float band = smoothstep(0.0, 0.04, ring) * (1.0 - smoothstep(0.08, 0.15, ring));
	float fade = 1.0 - smoothstep(0.25, ring_reach, d_shore);
	float surf_w = 0.065 + 0.03 * sin(TIME * 1.2 + wpos.x * 1.7 + wpos.z * 1.3);
	float surf = 1.0 - smoothstep(surf_w * 0.55, surf_w, d_shore);
	float foam = clamp(max(surf, band * fade * 0.35), 0.0, 1.0);
	// drifting light lines and glints on the surface
	float e = cell_edge(wpos.xz * 0.32 + vec2(TIME * 0.03, TIME * 0.02));
	float lines = (1.0 - smoothstep(0.0, 0.045, e)) * smoothstep(1.0, 3.0, d_shore) * light_lines;
	float g = vnoise(wpos.xz * 5.0 + vec2(TIME * 0.9, TIME * 0.6));
	float glint = smoothstep(0.93, 0.99, g) * smoothstep(0.6, 2.0, d_shore) * glint_amount;

	vec3 c = water + vec3(lines) * vec3(0.8, 0.95, 1.0) + vec3(glint);
	c = mix(c, foam_color, foam);
	// the same drifting cloud shadows as the land (board_ground_v2)
	vec2 cp = wpos.xz * 0.055 - vec2(0.55, 0.12) * TIME * 0.02;
	float cn = vnoise(cp) * 0.6 + vnoise(cp * 2.1 + 3.7) * 0.4;
	c *= 1.0 - 0.12 * smoothstep(0.52, 0.72, cn);
	ALBEDO = vec3(0.0);
	EMISSION = c * light_tint;
	ROUGHNESS = 0.22;
	SPECULAR = 0.6;
}
