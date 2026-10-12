shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform vec4 halo_color : source_color = vec4(1.0);
uniform float night_enabled = 0.0;
void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float soft_disc = pow(max(0.0, 1.0 - r), 2.0);
	ALBEDO = halo_color.rgb;
	ALPHA = soft_disc * 0.25 * night_enabled;
}
