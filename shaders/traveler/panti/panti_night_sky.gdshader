shader_type sky;

// EYEDIR is the only position input. No TIME, POSITION, screen UV, or nodes.
// Complete native celestial background, subject to the unchanged scene depth of field.
uniform vec3 zenith_color : source_color = vec3(0.045, 0.071, 0.18);
uniform vec3 horizon_color : source_color = vec3(0.11, 0.16, 0.29);
uniform vec3 ground_color : source_color = vec3(0.035, 0.047, 0.085);
uniform float horizon_falloff = 0.34;
uniform float galaxy_strength = 0.3;
uniform vec3 galaxy_color : source_color = vec3(0.43, 0.57, 0.88);
uniform float night_weight = 1.0;
uniform vec3 day_sky_top_color : source_color = vec3(0.26, 0.30, 0.64);
uniform vec3 day_sky_horizon_color : source_color = vec3(0.99, 0.74, 0.58);
uniform vec3 day_ground_bottom_color : source_color = vec3(0.2);
uniform vec3 day_ground_horizon_color : source_color = vec3(0.5);
uniform float day_sky_curve = 0.1;
uniform float day_ground_curve = 0.08;
uniform float day_sky_energy = 1.0;
uniform float day_ground_energy = 1.0;
uniform float day_energy = 1.0;
uniform float day_sun_angle_max = 0.0785398163;
uniform float day_sun_curve = 0.06;
#include "res://shaders/traveler/panti/panti_starfield.gdshaderinc"

// Gradient and sun-disc equations match the shader embedded in Godot 4.7.1's
// ProceduralSkyMaterial (read from the installed executable, no runtime probe).
vec3 procedural_day(vec3 direction) {
	float height = clamp(direction.y, -1.0, 1.0);
	float sky_mix = clamp(pow(1.0 - height, 1.0 / max(day_sky_curve, 0.0001)), 0.0, 1.0);
	vec3 upper = mix(day_sky_top_color, day_sky_horizon_color, sky_mix) * day_sky_energy;
	if (LIGHT0_ENABLED) {
		float sun_angle = dot(LIGHT0_DIRECTION, direction);
		float sun_size = cos(LIGHT0_SIZE);
		float rim = cos(day_sun_angle_max);
		if (sun_angle > sun_size) {
			upper = LIGHT0_COLOR * LIGHT0_ENERGY;
		} else if (sun_angle > rim) {
			float edge = (sun_size - sun_angle) / max(sun_size - rim, 0.00001);
			float sun_mix = clamp(pow(1.0 - edge, 1.0 / max(day_sun_curve, 0.0001)), 0.0, 1.0);
			upper = mix(upper, LIGHT0_COLOR * LIGHT0_ENERGY, sun_mix);
		}
	}
	float ground_mix = clamp(pow(1.0 + height, 1.0 / max(day_ground_curve, 0.0001)), 0.0, 1.0);
	vec3 lower = mix(day_ground_bottom_color, day_ground_horizon_color, ground_mix) * day_ground_energy;
	return mix(lower, upper, step(0.0, direction.y)) * day_energy;
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	float horizon_weight = exp(-max(direction.y, 0.0) / max(horizon_falloff, 0.01));
	vec3 base = mix(zenith_color, horizon_color, horizon_weight);
	base = mix(ground_color, base, smoothstep(-0.10, 0.05, direction.y));
	vec3 day = procedural_day(direction);
	if (AT_CUBEMAP_PASS) {
		COLOR = mix(day, base, night_weight);
	} else {
		vec3 profile = milky_profile(direction);
		float latitude = profile.x;
		float band = profile.y;
		float width = radians(max(galaxy_width_deg, 0.1));
		float along = atan(dot(direction, galaxy_tangent), dot(direction, galaxy_center));
		float cloud = dust_noise(direction * 38.0 + vec3(sky_seed));
		float broken = profile.z;
		float dark_lane = exp(-pow((latitude + (cloud - 0.48) * width) / (width * 0.23), 2.0));
		float core = pow(max(cloud, 0.0), 1.8) * mix(0.25, 1.0, broken);
		float regional = mix(0.7, 1.0, 0.5 + 0.5 * sin(along * 3.7 + 0.4));
		float dust = band * core * regional * (1.0 - 0.68 * dark_lane);
		float horizon_clearance = smoothstep(0.015, 0.15, direction.y);
		vec3 night = base + horizon_clearance * galaxy_color * dust * galaxy_strength + directional_stars(direction);
		COLOR = mix(day, night, night_weight);
	}
}
