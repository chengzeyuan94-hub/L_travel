shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D scene_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform sampler2D white_background_texture : repeat_disable, filter_nearest;
uniform sampler2D stars_texture : repeat_disable, filter_linear;
uniform float anim_t = 0.0;
uniform float meteor_t = 0.0;
uniform float stars_weight = 1.0;
uniform float twinkle_amplitude = 0.18;
uniform float twinkle_period_min_s = 5.5;
uniform float twinkle_period_max_s = 10.0;
uniform vec2 viewport_size = vec2(1920.0, 1080.0);
#include "res://shaders/traveler/panti/panti_meteors.gdshaderinc"

float twinkle_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec4 scene = textureLod(scene_texture, SCREEN_UV, 0.0);
	vec3 white_background = textureLod(white_background_texture, SCREEN_UV, 0.0).rgb;
	vec3 difference = max(white_background - scene.rgb, vec3(0.0));
	float sky_mask = smoothstep(0.025, 0.75, max(difference.r, max(difference.g, difference.b)));
	vec3 stars = textureLod(stars_texture, SCREEN_UV, 0.0).rgb;
	vec2 region = floor(SCREEN_UV * vec2(160.0, 90.0));
	float phase = twinkle_hash(region) * TAU;
	float period = mix(twinkle_period_min_s, twinkle_period_max_s, twinkle_hash(region + 73.4));
	float pulse = 0.65 * sin(anim_t * TAU / max(period, 0.1) + phase)
		+ 0.35 * sin(anim_t * TAU / max(period * 1.71, 0.1) + phase * 1.37);
	float twinkle = 1.0 + twinkle_amplitude * pulse;
	vec3 meteors = meteor_light(SCREEN_UV, viewport_size, meteor_t);
	COLOR = vec4(scene.rgb + (stars * twinkle + meteors) * sky_mask * stars_weight, scene.a);
}
