// L叔在哪儿 · L1 lighting line · stage floor / visible backdrop.
// Drop-in replacement for lshu_floor.gdshader (the floor covers the whole frame at the fixed camera rule,
// so this shader IS the visible backdrop). Same uniform names as the probe floor, so the viewer keeps
// feeding backdrop_top/bottom (tonemap-compensated), vignette, glow_amount, shadow_value, shadow_tint.
// Additions (all global, set per light preset by modules/l1_atmos.gd from cfg.atmos):
//   - soft studio pool of light behind the tile (glow_tint / glow_radius), gradient curve
//   - contact occlusion around the 8x8 tile footprint (every tile has the same footprint)
//   - sparse screen-space stars (night) that twinkle with the viewer clock
//   - cool/tinted shadow on the backdrop, and a far fade so long shadows dissolve instead of ending hard
shader_type spatial;
render_mode cull_disabled, ambient_light_disabled, specular_disabled, depth_draw_opaque, fog_disabled;

uniform vec3 backdrop_top = vec3(0.8);      // linear (viewer: compensated backdrop * top_mult)
uniform vec3 backdrop_bottom = vec3(0.8);   // linear (viewer: compensated backdrop * bottom_mult)
uniform float vignette = 0.0;
uniform vec2 glow_center = vec2(0.5, 0.45);
uniform float glow_amount = 0.0;
uniform float shadow_value = 0.72;
uniform vec3 shadow_tint = vec3(1.0);       // linear
// ---- L1 additions
uniform float gradient_curve = 1.0;         // >1 keeps the top colour longer
uniform vec3 glow_tint = vec3(1.0);         // linear multiplier of the pool of light
uniform vec2 glow_radius = vec2(1.4, 2.0);  // ellipse scale of the pool (bigger = tighter)
uniform float vignette_inner = 0.25;
uniform float vignette_outer = 0.80;
uniform vec4 tile_rect = vec4(-4.0, -4.0, 8.0, 8.0);
uniform float contact_ao = 0.0;             // 0..1 darkening right at the tile footprint
uniform float contact_ao_radius = 1.0;      // metres of falloff away from the footprint
uniform float shadow_fade_distance = 60.0;  // metres from the tile centre where cast shadows are gone
uniform float stars_amount = 0.0;           // 0 = none
uniform float stars_density = 0.004;        // fraction of 2px cells lit
uniform vec3 stars_tint = vec3(1.0);
uniform float stars_top_bias = 1.4;         // stars thin out towards the bottom of the frame
uniform float anim_time = 0.0;

varying vec3 v_world;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float box_sdf(vec2 p, vec2 half_size) {
	vec2 d = abs(p) - half_size;
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float gy = pow(clamp(uv.y, 0.0, 1.0), gradient_curve);
	vec3 c = mix(backdrop_top, backdrop_bottom, gy);
	vec2 gq = (uv - glow_center) * glow_radius;
	float g = exp(-dot(gq, gq) * 2.2);
	c *= mix(vec3(1.0), glow_tint, g) * (1.0 + glow_amount * g);
	vec2 q = uv - 0.5;
	c *= 1.0 - vignette * smoothstep(vignette_inner, vignette_outer, length(q * vec2(1.0, 1.25)));
	if (stars_amount > 0.0) {
		vec2 cell = floor(FRAGCOORD.xy / 2.0);
		float h = hash12(cell);
		if (h < stars_density) {
			float k = h / stars_density;
			float tw = 0.65 + 0.35 * sin(anim_time * (0.6 + 1.7 * k) + k * 40.0);
			float band = pow(clamp(1.0 - uv.y, 0.0, 1.0), stars_top_bias);
			float mask = 1.0 - g;   // no stars in the pool right behind the tile
			c += stars_tint * stars_amount * (0.35 + 0.65 * k * k) * tw * band * mask;
		}
	}
	if (contact_ao > 0.0) {
		vec2 centre = tile_rect.xy + tile_rect.zw * 0.5;
		float d = box_sdf(v_world.xz - centre, tile_rect.zw * 0.5);
		c *= 1.0 - contact_ao * exp(-max(d, 0.0) / max(contact_ao_radius, 1e-3));
	}
	ALBEDO = c;
}

void light() {
	vec2 centre = tile_rect.xy + tile_rect.zw * 0.5;
	float far_fade = smoothstep(shadow_fade_distance * 0.35, shadow_fade_distance, length(v_world.xz - centre));
	float att = mix(clamp(ATTENUATION, 0.0, 1.0), 1.0, far_fade);
	float lit = mix(shadow_value, 1.0, att);
	DIFFUSE_LIGHT = mix(shadow_tint * shadow_value, vec3(1.0), (lit - shadow_value) / max(1.0 - shadow_value, 1e-4));
}
