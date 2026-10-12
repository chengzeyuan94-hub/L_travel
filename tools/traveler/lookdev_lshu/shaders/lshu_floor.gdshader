// L叔在哪儿 · stage floor under the floating tile. It continues the backdrop exactly (same screen-space
// gradient and the same tonemap-compensated colours as lshu_backdrop.gdshader) and only darkens where the
// sun's shadow falls, as the web previews show the tile's shadow on the backdrop.
// Only the sun reaches this surface (the floor sits on its own render layer), ambient is disabled, so
// lit = backdrop, shadowed = backdrop * shadow_value.
shader_type spatial;
render_mode cull_disabled, ambient_light_disabled, specular_disabled, depth_draw_opaque;

uniform vec3 backdrop_top = vec3(0.8);      // linear, same values the viewer gives the sky
uniform vec3 backdrop_bottom = vec3(0.8);
uniform float vignette = 0.0;
uniform vec2 glow_center = vec2(0.5, 0.45);
uniform float glow_amount = 0.0;
uniform float shadow_value = 0.72;          // backdrop multiplier in full shadow
uniform vec3 shadow_tint = vec3(1.0);       // optional tint of the shadowed floor (linear)

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 c = mix(backdrop_top, backdrop_bottom, clamp(uv.y, 0.0, 1.0));
	float g = exp(-dot((uv - glow_center) * vec2(1.4, 2.0), (uv - glow_center) * vec2(1.4, 2.0)) * 2.2);
	c *= 1.0 + glow_amount * g;
	vec2 q = uv - 0.5;
	c *= 1.0 - vignette * smoothstep(0.25, 0.75, length(q * vec2(1.0, 1.25)));
	ALBEDO = c;
}

void light() {
	float lit = mix(shadow_value, 1.0, clamp(ATTENUATION, 0.0, 1.0));
	DIFFUSE_LIGHT = mix(shadow_tint * shadow_value, vec3(1.0), (lit - shadow_value) / max(1.0 - shadow_value, 1e-4));
}
