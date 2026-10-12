// L3 · soft faceted smoke / steam puffs (chimney smoke, fire wisps, tea steam). One material per kind,
// per-puff opacity and warmth as instance uniforms. Faceted normals keep the low-poly look of the web puffs.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_lambert, specular_disabled;

uniform vec3 puff_color : source_color = vec3(0.85, 0.87, 0.85);
uniform vec3 warm_color : source_color = vec3(1.0, 0.55, 0.25);
uniform float edge_soft = 0.8;
uniform float self_lit = 0.0;          // night: smoke keeps a little of its own colour against a dark sky
instance uniform float puff_alpha = 0.3;
instance uniform float puff_warm = 0.0;

void fragment() {
	vec3 fn = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = fn;
	float ndv = clamp(dot(fn, VIEW), 0.0, 1.0);
	ALBEDO = puff_color;
	ROUGHNESS = 1.0;
	EMISSION = warm_color * puff_warm + puff_color * self_lit;
	ALPHA = clamp(puff_alpha * mix(1.0, pow(ndv, 0.7), edge_soft), 0.0, 1.0);
}
