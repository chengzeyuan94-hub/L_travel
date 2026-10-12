shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;

uniform float clear_depth_near = 5.5;
uniform float clear_depth_far = 19.0;
uniform float leaf_roughness = 1.0;
uniform float leaf_specular = 0.0;
uniform bool diagnostic_mask = false;
varying float particle_depth;

void vertex() {
	// Per-particle model origin, not a screen-space layer. Ordinary depth testing stays on.
	particle_depth = -(VIEW_MATRIX * MODEL_MATRIX[3]).z;
}

void fragment() {
	if (particle_depth < clear_depth_near || particle_depth > clear_depth_far) {
		discard;
	}
	NORMAL = normalize(NORMAL) * (FRONT_FACING ? 1.0 : -1.0);
	ALBEDO = diagnostic_mask ? vec3(0.0) : COLOR.rgb;
	EMISSION = diagnostic_mask ? vec3(1.0) : vec3(0.0);
	ROUGHNESS = leaf_roughness;
	SPECULAR = leaf_specular;
	METALLIC = 0.0;
}
