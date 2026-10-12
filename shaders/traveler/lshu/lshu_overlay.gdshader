// L叔在哪儿 · shared translucent overlay for tile surfaces the web drew with opacity < 1
// (ripple crests on water). Same sRGB COLOR_0 convention as lshu_surface.gdshader.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled, blend_mix, depth_draw_never;

uniform vec3 albedo_tint : source_color = vec3(1.0);
uniform float opacity : hint_range(0.0, 1.0) = 0.5;
uniform float emission_strength = 0.0;
uniform float anim_time = 0.0;
uniform float bob = 0.002;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += sin(anim_time * 0.8 + w.x * 3.1 + w.z * 1.7) * bob;
}

void fragment() {
	vec3 base = srgb_to_linear(COLOR.rgb) * albedo_tint;
	ALBEDO = base;
	EMISSION = base * emission_strength;
	ALPHA = opacity;
}
