shader_type sky;

// Static layered storm ceiling. The physical shaft is a SpotLight3D in fog,
// not painted in this background. No TIME dependency or moving noise.
uniform vec3 zenith_color : source_color = vec3(0.13, 0.17, 0.24);
uniform vec3 horizon_color : source_color = vec3(0.35, 0.41, 0.48);
uniform vec3 cloud_shadow_color : source_color = vec3(0.075, 0.095, 0.135);
uniform vec3 cloud_lit_color : source_color = vec3(0.33, 0.38, 0.45);
uniform vec3 opening_color : source_color = vec3(0.78, 0.81, 0.79);
uniform vec3 ground_color : source_color = vec3(0.12, 0.14, 0.18);
uniform vec3 opening_direction = vec3(-0.35, 0.72, 0.6);
uniform float sky_energy = 0.95;
uniform float cloud_seed = 23.7;
uniform float cloud_coverage = 0.90;
uniform float opening_strength = 0.24;

float hash21(vec2 point) {
	point = fract(point * vec2(123.34, 456.21));
	point += dot(point, point + 45.32);
	return fract(point.x * point.y);
}

float noise21(vec2 point) {
	vec2 cell = floor(point);
	vec2 blend = fract(point);
	blend = blend * blend * (3.0 - 2.0 * blend);
	return mix(mix(hash21(cell), hash21(cell + vec2(1.0, 0.0)), blend.x),
		mix(hash21(cell + vec2(0.0, 1.0)), hash21(cell + vec2(1.0)), blend.x), blend.y);
}

float fbm(vec2 point) {
	float value = 0.0;
	float amplitude = 0.53;
	mat2 turn = mat2(vec2(0.82, 0.57), vec2(-0.57, 0.82));
	for (int octave = 0; octave < 5; octave++) {
		value += noise21(point) * amplitude;
		point = turn * point * 2.07 + vec2(9.4, 15.2);
		amplitude *= 0.47;
	}
	return value;
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	float elevation = asin(clamp(direction.y, -1.0, 1.0));
	float azimuth = atan(direction.x, direction.z);
	float horizon = exp(-max(direction.y, 0.0) * 4.1);
	vec3 color = mix(zenith_color, horizon_color, horizon);

	// Several broad shelves, with smaller billows on their illuminated rims.
	vec2 broad_uv = vec2(azimuth * 3.4, elevation * 7.8) + vec2(cloud_seed, 3.1);
	vec2 warp = vec2(fbm(broad_uv * 0.72 + vec2(4.8, 1.3)),
		fbm(broad_uv * 0.85 + vec2(16.2, 8.7))) - 0.5;
	float broad_mass = fbm(broad_uv * 0.52 + vec2(2.3, 8.1));
	float mass = fbm(broad_uv + warp * 0.65) * 0.75 + broad_mass * 0.25;
	float edge_light = fbm(broad_uv + warp * 0.65 + vec2(-0.24, 0.30));
	float grain = fbm(broad_uv * 3.4 + vec2(7.1, 2.8));
	float underside = smoothstep(0.36, 0.64, mass);
	float rim = clamp((edge_light - mass) * 3.8 + 0.38, 0.0, 1.0);
	float illuminated = clamp(rim * 0.73 + broad_mass * 0.21 + grain * 0.06, 0.0, 1.0);
	vec3 bank = mix(cloud_shadow_color, cloud_lit_color, illuminated);
	float covered = smoothstep(0.19, 0.43, mass) * cloud_coverage;
	color = mix(color, bank * mix(1.04, 0.72, underside), covered);

	// Lower, horizontally stretched rain clouds add depth at the far skyline.
	vec2 low_uv = vec2(azimuth * 6.0, elevation * 22.0) + vec2(6.8, cloud_seed * 0.42);
	float lower_noise = fbm(low_uv + warp * 0.65);
	float shelf = exp(-pow((elevation - 0.19 - warp.x * 0.08) / 0.095, 2.0));
	float lower_mask = shelf * smoothstep(0.30, 0.64, lower_noise) * 0.55;
	color = mix(color, mix(cloud_shadow_color * 0.80, cloud_lit_color * 0.55, lower_noise), lower_mask);

	// Broad, torn opening; no visible solar disc or sunset orange on the horizon.
	float opening_angle = acos(clamp(dot(direction, normalize(opening_direction)), -1.0, 1.0));
	float opening = exp(-pow(opening_angle / 0.17, 2.0));
	float torn_opening = opening * smoothstep(0.18, 0.74, edge_light) * opening_strength;
	color += opening_color * torn_opening;
	color = mix(ground_color, color, smoothstep(-0.05, 0.025, direction.y));
	COLOR = max(color * sky_energy, vec3(0.001));
}
