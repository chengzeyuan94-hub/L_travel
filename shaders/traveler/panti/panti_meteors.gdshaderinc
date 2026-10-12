// Quiet screen-space meteors for the post-DOF sky composite.
// Tunable values mirror data/traveler/panti_meteors.json one for one.
// Caller supplies the shared scene clock, sky occlusion mask and night weight.
uniform float meteor_cycle_s = 45.0;
uniform vec2 meteor_reference_size = vec2(1920.0, 1080.0);
uniform vec3 meteor_start_times_s = vec3(3.0, 7.4, 12.8);
uniform vec3 meteor_lifetimes_s = vec3(1.7, 1.9, 1.5);
uniform vec2 meteor_start_0_px = vec2(1150.0, 20.0);
uniform vec2 meteor_start_1_px = vec2(1025.0, 12.0);
uniform vec2 meteor_start_2_px = vec2(1095.0, 84.0);
uniform vec2 meteor_direction = vec2(-0.84, 0.5425864);
uniform vec3 meteor_travel_px = vec3(140.0, 130.0, 125.0);
uniform vec3 meteor_tail_px = vec3(110.0, 100.0, 90.0);
uniform float meteor_width_px = 1.35;
uniform float meteor_head_length_px = 1.7;
uniform float meteor_tail_falloff = 1.8;
uniform float meteor_tail_energy = 0.44;
uniform float meteor_brightness = 1.15;
uniform vec2 meteor_fade_s = vec2(0.16, 0.42);
uniform vec3 meteor_head_rgb : source_color = vec3(0.84, 0.92, 1.0);
uniform vec3 meteor_tail_rgb : source_color = vec3(0.52, 0.68, 1.0);

vec3 meteor_one(vec2 p, float aa, float phase_s, float start_s,
		float life_s, vec2 start_px, float travel_px, float tail_px) {
	float age = phase_s - start_s;
	if (age < 0.0 || age >= life_s) {
		return vec3(0.0);
	}
	vec2 direction = normalize(meteor_direction);
	vec2 head = start_px + direction * travel_px * age / life_s;
	vec2 delta = p - head;
	float along = dot(delta, direction);
	float across = abs(delta.x * direction.y - delta.y * direction.x);
	float half_width = meteor_width_px * 0.5;
	float line = 1.0 - smoothstep(max(half_width - aa, 0.0), half_width + aa, across);
	float tail_fraction = clamp(-along / tail_px, 0.0, 1.0);
	float tail = line * pow(1.0 - tail_fraction, meteor_tail_falloff);
	// The luminous tail stays behind the moving head, not ahead of it.
	tail *= 1.0 - smoothstep(0.0, meteor_head_length_px, along);
	float head_along = along / meteor_head_length_px;
	float head_across = across / max(half_width, aa);
	float head_core = exp(-head_along * head_along - head_across * head_across);
	float envelope = smoothstep(0.0, meteor_fade_s.x, age)
		* (1.0 - smoothstep(life_s - meteor_fade_s.y, life_s, age));
	return (meteor_head_rgb * head_core
		+ meteor_tail_rgb * tail * meteor_tail_energy) * envelope * meteor_brightness;
}

vec3 meteor_light(vec2 uv, vec2 render_dimensions, float timeline_s) {
	float phase_s = mod(max(timeline_s, 0.0), meteor_cycle_s);
	vec2 p = uv * meteor_reference_size;
	float aa = 0.5 * max(meteor_reference_size.x / max(render_dimensions.x, 1.0),
		meteor_reference_size.y / max(render_dimensions.y, 1.0));
	vec3 light_value = meteor_one(p, aa, phase_s, meteor_start_times_s.x,
		meteor_lifetimes_s.x, meteor_start_0_px, meteor_travel_px.x, meteor_tail_px.x);
	light_value += meteor_one(p, aa, phase_s, meteor_start_times_s.y,
		meteor_lifetimes_s.y, meteor_start_1_px, meteor_travel_px.y, meteor_tail_px.y);
	light_value += meteor_one(p, aa, phase_s, meteor_start_times_s.z,
		meteor_lifetimes_s.z, meteor_start_2_px, meteor_travel_px.z, meteor_tail_px.z);
	return light_value;
}
