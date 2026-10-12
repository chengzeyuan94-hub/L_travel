// L3 · L叔 rim pass (next_pass on the character's styled body surfaces, all poses).
// Adds a thin fresnel edge light so the toon-shaded figure reads at tile scale (~100 px) and takes on
// the light preset's colour instead of looking pasted on. key_bias biases the rim toward the key light
// side (sun direction, world space) so it reads as light wrap, not as a glow sticker outline.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, fog_disabled;

uniform vec3 rim_color : source_color = vec3(1.0, 0.9, 0.75);
uniform float rim_strength = 0.0;
uniform float rim_power = 3.0;
uniform vec3 key_dir_world = vec3(-0.5, 0.8, 0.4);   // points toward the light
uniform float key_bias = 0.6;                         // 0 = even rim, 1 = key side only
uniform float top_bias = 0.25;                        // extra rim on up-facing edges (sky wrap)
// Opacity of his rig (lshu_actor_motion.gd _set_alpha): the dither fade drops the body pixels but this additive
// pass has no alpha of its own, so without it a hidden or fading rig left a glowing outline where he stood.
// 1 = the approved look exactly (x * 1.0 is exact); 0 = adds nothing.
uniform float rim_fade = 1.0;

void fragment() {
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - ndv, rim_power);
	vec3 key_v = normalize((VIEW_MATRIX * vec4(normalize(key_dir_world), 0.0)).xyz);
	float side = clamp(dot(NORMAL, key_v) * 0.5 + 0.5, 0.0, 1.0);
	float up = clamp((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y, 0.0, 1.0);
	float k = mix(1.0, side * side, key_bias) + top_bias * up;
	ALBEDO = rim_color * fres * k * rim_strength;
	ALBEDO *= rim_fade;
}
