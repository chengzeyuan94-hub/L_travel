shader_type sky;

// Static authored desert sunset. EYEDIR is the only spatial input; no clock,
// moving clouds, screen overlay or extra full-scene render is used.
uniform vec3 zenith_color : source_color = vec3(0.30, 0.40, 0.56);
uniform vec3 horizon_color : source_color = vec3(1.0, 0.62, 0.24);
uniform vec3 ground_bottom_color : source_color = vec3(0.478, 0.373, 0.294);
uniform vec3 ground_horizon_color : source_color = vec3(0.827, 0.612, 0.396);
uniform float horizon_falloff = 0.16;
uniform float sky_energy = 1.0;
uniform vec3 sun_direction = vec3(-0.26, 0.12, 0.96);
uniform vec3 sun_disc_color : source_color = vec3(1.0, 0.96, 0.76);
uniform float sun_disc_energy = 2.6;
uniform float sun_radius_deg = 1.08;
uniform float sun_edge_deg = 0.025;
uniform float sun_halo_radius_deg = 5.2;
uniform float sun_halo_strength = 0.24;
uniform vec3 cloud_color : source_color = vec3(0.93, 0.73, 0.52);
uniform float cloud_opacity = 0.27;
uniform float cloud_seed = 29.0;
uniform float cloud_coverage = 0.42;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise21(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0)), f.x), f.y);
}

float cloud_noise(vec2 p) {
	float n = noise21(p) * 0.53;
	n += noise21(p * 2.03 + vec2(12.7, 5.4)) * 0.27;
	n += noise21(p * 4.09 + vec2(7.3, 19.2)) * 0.13;
	n += noise21(p * 8.21 + vec2(21.1, 1.2)) * 0.07;
	return n;
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	float elevation = asin(clamp(direction.y, -1.0, 1.0));
	float azimuth = atan(direction.x, direction.z);
	float warm_weight = exp(-max(direction.y, 0.0) / max(horizon_falloff, 0.01));
	vec3 color = mix(zenith_color, horizon_color, warm_weight);
	vec3 ground = mix(ground_horizon_color, ground_bottom_color, smoothstep(0.0, 0.7, -direction.y));
	color = mix(ground, color, smoothstep(-0.035, 0.015, direction.y));

	// A few long, broken wisps. Broad gaps between bands keep most sky open.
	float drift = 0.007 * sin(azimuth * 4.7 + 0.8) + 0.006 * sin(azimuth * 9.1);
	float cloud_y = elevation + drift;
	float band = exp(-pow((cloud_y - 0.235) / 0.019, 2.0));
	band += 0.72 * exp(-pow((cloud_y - 0.355) / 0.027, 2.0));
	band += 0.40 * exp(-pow((cloud_y - 0.465) / 0.022, 2.0));
	float texture = cloud_noise(vec2(azimuth * 4.1 + cloud_seed, elevation * 37.0 + cloud_seed * 0.31));
	float torn_edges = smoothstep(1.0 - cloud_coverage, 0.85, texture);
	float wisps = clamp(band * torn_edges * 2.4, 0.0, 1.0);
	vec3 tinted_cloud = mix(cloud_color * 0.72, cloud_color, texture);
	color = mix(color, tinted_cloud, wisps * cloud_opacity);

	float sun_dot = clamp(dot(direction, normalize(sun_direction)), -1.0, 1.0);
	float radius = radians(sun_radius_deg);
	float edge = radians(sun_edge_deg);
	float disk = smoothstep(cos(radius + edge), cos(max(radius - edge, 0.00001)), sun_dot);
	float angle = acos(sun_dot);
	float halo = exp(-pow(angle / radians(max(sun_halo_radius_deg, 0.01)), 2.0));
	color += sun_disc_color * halo * sun_halo_strength;
	color = mix(color, sun_disc_color * sun_disc_energy, disk);
	COLOR = color * sky_energy;
}
