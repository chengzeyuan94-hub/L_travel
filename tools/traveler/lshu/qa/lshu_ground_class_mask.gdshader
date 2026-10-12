// 第四幕「L叔在哪儿」· QA only (fix #5 evidence): unshaded ground-class mask for the ground role.
// Swapped onto the shared ground material by qa/lshu_ground_class_capture.gd for two frames; never used by the scene.
// R = sand class weight, G / B = pass marker (pass A: G = 1, pass B: B = 1), so |A - B| isolates visible ground
// pixels. ground_class() and the smoothed source colour are copied from shaders/traveler/lshu/lshu_surface.gdshader
// and must stay in step with it.
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, depth_draw_opaque;

uniform sampler2D l2_ground_col_tex : filter_linear, repeat_disable;
uniform vec4 height_rect = vec4(-4.0, -4.0, 8.0, 8.0);
uniform float l2_maps_ready = 0.0;
uniform float l2_ground_smooth = 0.0;
uniform float mask_pass = 0.0;

varying vec3 v_world;

vec4 ground_class(vec3 c) {
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	float sat = (mx - mn) / max(mx, 1e-3);
	float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	float snow = smoothstep(0.74, 0.84, lum) * (1.0 - smoothstep(0.07, 0.16, sat));
	float grass = smoothstep(-0.015, 0.03, c.g - c.r) * smoothstep(0.07, 0.14, c.g - c.b) * (1.0 - snow);
	float wet = smoothstep(-0.01, 0.04, c.b - c.r) * (1.0 - snow) * (1.0 - grass);
	float sand = clamp(1.0 - grass - snow - wet, 0.0, 1.0);
	return vec4(grass, sand, snow, wet);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 src = COLOR.rgb;
	if (l2_maps_ready > 0.5 && l2_ground_smooth > 0.0) {
		vec2 guv = (v_world.xz - height_rect.xy) / height_rect.zw;
		src = mix(src, texture(l2_ground_col_tex, guv).rgb, l2_ground_smooth);
	}
	vec4 cls = ground_class(src);
	ALBEDO = vec3(cls.y, mask_pass < 0.5 ? 1.0 : 0.0, mask_pass < 0.5 ? 0.0 : 1.0);
}
