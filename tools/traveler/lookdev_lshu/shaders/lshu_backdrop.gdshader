// L叔在哪儿 · backdrop sky. The visible background is a screen-space studio gradient (the web tiles float
// on a flat palette colour); the radiance/irradiance pass (AT_CUBEMAP_PASS) is a hemisphere gradient that
// supplies ambient light and water reflections, independent of the visible backdrop.
shader_type sky;

uniform vec3 backdrop_top : source_color = vec3(0.92, 0.86, 0.80);
uniform vec3 backdrop_bottom : source_color = vec3(0.92, 0.86, 0.80);
uniform float backdrop_energy = 1.0;
uniform float vignette = 0.0;           // darken corners, fraction
uniform vec2 glow_center = vec2(0.5, 0.45);
uniform float glow_amount = 0.0;        // soft brightening behind the tile
uniform vec3 ambient_top : source_color = vec3(0.48, 0.56, 0.69);
uniform vec3 ambient_horizon : source_color = vec3(0.40, 0.40, 0.44);
uniform vec3 ambient_bottom : source_color = vec3(0.20, 0.15, 0.19);
uniform float ambient_energy = 1.0;

void sky() {
	if (AT_CUBEMAP_PASS) {
		float y = EYEDIR.y;
		vec3 c = y >= 0.0 ? mix(ambient_horizon, ambient_top, smoothstep(0.0, 0.8, y)) : mix(ambient_horizon, ambient_bottom, smoothstep(0.0, 0.6, -y));
		COLOR = c * ambient_energy;
	} else {
		vec2 uv = SCREEN_UV;
		vec3 c = mix(backdrop_top, backdrop_bottom, clamp(uv.y, 0.0, 1.0));
		float g = exp(-dot((uv - glow_center) * vec2(1.4, 2.0), (uv - glow_center) * vec2(1.4, 2.0)) * 2.2);
		c *= 1.0 + glow_amount * g;
		vec2 q = uv - 0.5;
		c *= 1.0 - vignette * smoothstep(0.25, 0.75, length(q * vec2(1.0, 1.25)));
		COLOR = c * backdrop_energy;
	}
}
