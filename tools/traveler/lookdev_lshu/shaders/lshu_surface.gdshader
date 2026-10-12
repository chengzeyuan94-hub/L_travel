// L叔在哪儿 · shared tile surface shader (probe baseline). Every opaque tile surface uses it:
// asset GLBs (matte / tree / rock / landmark / glow / water / metal) and the baked procedural parts
// (ground / skirt / cliff / structure / steps / grass / foam / water_side).
// One ShaderMaterial per role; the viewer fills uniforms from the variant's "surface" section.
// COLOR_0 is sRGB-encoded by bake_recipes.cjs (8-bit precision for dark tones); decoded here.
// Extend: copy this file, point the variant's surface.shader at the copy, keep the uniform names below.
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
uniform float noise_amount = 0.0;         // low-frequency albedo breakup, fraction
uniform float noise_scale = 2.5;          // cycles per metre
uniform float facet_jitter = 0.0;         // per-facet brightness jitter, fraction
// ---- rim / fresnel light
uniform float rim_strength = 0.0;
uniform float rim_power = 4.0;
uniform vec3 rim_color : source_color = vec3(1.0);
// ---- contact AO from the tile height field (viewer binds height_tex / height_rect)
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform vec4 height_rect = vec4(-4.0, -4.0, 8.0, 8.0); // x0, z0, width, depth of the vertex grid
uniform float height_grid_n = 53.0;                     // vertices per side (texture width)
uniform float contact_ao = 0.0;                         // 0..1 darkening at ground contact
uniform float contact_ao_height = 0.35;                 // metres above terrain where it fades out
uniform float ao_light_affect = 0.0;
// ---- height tint (e.g. cooler/darker low areas, sunlit tops)
uniform float top_tint_amount = 0.0;
uniform vec3 top_tint : source_color = vec3(1.0);
// ---- water
uniform float water_mode = 0.0;
uniform vec3 water_sky : source_color = vec3(0.8, 0.9, 0.95);
uniform float water_fresnel = 0.35;
uniform float water_ripple = 0.05;
// ---- wind / time (viewer drives anim_time; motion-freeze holds it)
uniform float anim_time = 0.0;
uniform float wind_strength = 0.0;
instance uniform float sway = 0.0;
instance uniform float sway_phase = 0.0;

varying vec3 v_world;
varying vec3 v_world_normal;

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

void vertex() {
	if (sway > 0.0 && wind_strength > 0.0) {
		float h = max(VERTEX.y - 0.16, 0.0);
		float gust = sin(anim_time * 0.83 + sway_phase + VERTEX.z * 1.13 + VERTEX.x * 0.72) + 0.32 * sin(anim_time * 1.71 + VERTEX.x * 2.3 + sway_phase);
		VERTEX.x += gust * h * wind_strength * sway;
		VERTEX.z += cos(anim_time * 0.67 + VERTEX.x * 0.9 + sway_phase) * h * wind_strength * sway * 0.44;
	}
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 base = vertex_color_srgb ? srgb_to_linear(COLOR.rgb) : COLOR.rgb;
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
	float ao = 1.0;
	if (contact_ao > 0.0) {
		vec2 uv = (v_world.xz - height_rect.xy) / height_rect.zw;
		uv = uv * ((height_grid_n - 1.0) / height_grid_n) + 0.5 / height_grid_n;
		float terrain = texture(height_tex, uv).r;
		float above = v_world.y - terrain;
		ao = 1.0 - contact_ao * (1.0 - smoothstep(0.0, contact_ao_height, above));
	}
	vec3 n_view = NORMAL;
	float rough = roughness;
	if (water_mode > 0.5 && v_world_normal.y > 0.55) {
		vec3 wn = normalize(vec3(sin(v_world.z * 7.0 + v_world.x * 2.0 + anim_time * 0.7) * water_ripple, 1.0, cos(v_world.x * 6.0 - anim_time * 0.55) * water_ripple * 1.4));
		n_view = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
		NORMAL = n_view;
		float fres = pow(1.0 - clamp(dot(n_view, VIEW), 0.0, 1.0), 5.0);
		base = mix(base, srgb_to_linear(water_sky), clamp(water_fresnel * (0.25 + fres), 0.0, 1.0));
	}
	ALBEDO = base;
	AO = ao;
	AO_LIGHT_AFFECT = ao_light_affect;
	ROUGHNESS = rough;
	METALLIC = metallic;
	SPECULAR = specular_amount;
	vec3 emission = base * emission_strength * emission_tint;
	if (rim_strength > 0.0) {
		float r = pow(1.0 - clamp(dot(n_view, VIEW), 0.0, 1.0), rim_power);
		emission += rim_color * r * rim_strength * ao;
	}
	EMISSION = emission;
}
