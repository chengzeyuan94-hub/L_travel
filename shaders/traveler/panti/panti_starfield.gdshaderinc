// Shared deterministic world-direction star field and Milky Way profile.
uniform vec3 galaxy_center = vec3(-0.54, 0.45, -0.71);
uniform vec3 galaxy_tangent = vec3(0.40, 0.85, 0.34);
uniform vec3 galaxy_normal = vec3(0.74, -0.10, -0.66);
uniform float galaxy_width_deg = 3.5;
uniform float galaxy_warp_deg = 1.6;
uniform float star_strength = 0.8;
uniform float base_star_density = 0.028;
uniform float milky_star_density = 0.12;
uniform float star_size_multiplier = 1.0;
uniform float sky_seed = 29.17;

float hash31(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

vec3 hash23(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), u.x),
			mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), u.x), u.y),
		mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), u.x),
			mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), u.x), u.y), u.z);
}

float dust_noise(vec3 p) {
	float value = 0.0;
	float weight = 0.5;
	for (int i = 0; i < 4; i++) {
		value += weight * noise3(p);
		p = p * 2.07 + vec3(14.7, 23.1, 8.6);
		weight *= 0.5;
	}
	return value;
}

vec3 star_layer(vec2 spherical_uv, float grid_count, float density, float seed, float size_factor) {
	vec2 grid = spherical_uv * vec2(grid_count, grid_count * 0.5);
	vec2 cell = floor(grid);
	vec3 random = hash23(cell + seed);
	// A star stays inside its own cell, so no neighbour loops are needed.
	vec2 position = vec2(0.25) + random.xy * 0.5;
	float distance_to_star = length(fract(grid) - position);
	float aa = max(length(fwidth(grid)) * 0.52, 0.0001);
	float radius = mix(0.055, 0.15, pow(random.z, 5.0)) * star_size_multiplier * size_factor;
	float coverage = 1.0 - smoothstep(max(0.0, radius - aa), radius + aa, distance_to_star);
	coverage *= min(1.0, (radius * radius) / (aa * aa));
	float occupied = step(hash31(vec3(cell, seed + 9.3)), density);
	float brightness = mix(0.17, 1.0, pow(random.z, 4.0));
	vec3 color = mix(vec3(0.60, 0.74, 1.0), vec3(1.0, 0.92, 0.80), random.x * 0.35);
	return color * coverage * occupied * brightness;
}

vec3 milky_profile(vec3 direction) {
	float warp = (noise3(direction * 7.0 + sky_seed) - 0.5) * radians(galaxy_warp_deg);
	float latitude = asin(clamp(dot(direction, galaxy_normal), -1.0, 1.0)) + warp;
	float width = radians(max(galaxy_width_deg, 0.1));
	float band = exp(-0.5 * latitude * latitude / (width * width));
	float broken = smoothstep(0.22, 0.70, noise3(direction * 12.0 + 10.7));
	return vec3(latitude, band, broken);
}

vec3 directional_stars(vec3 direction) {
	vec3 profile = milky_profile(direction);
	vec2 spherical_uv = vec2(atan(direction.x, -direction.z) / TAU + 0.5,
		asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5);
	float clustering = mix(0.42, 1.0, profile.z);
	vec3 stars = star_layer(spherical_uv, 1400.0, base_star_density, sky_seed, 1.0);
	stars += star_layer(spherical_uv, 2700.0, profile.y * milky_star_density * clustering, sky_seed + 171.0, 0.85);
	return stars * star_strength * smoothstep(0.015, 0.15, direction.y);
}
