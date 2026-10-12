shader_type spatial;
// Match the existing textured, double-sided StandardMaterial3D on the cedars.
render_mode world_vertex_coords, cull_disabled, diffuse_burley, specular_disabled;

uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform float roughness = 0.95;
uniform bool wind_enabled = true;
uniform float anim_t = 0.0;
uniform vec3 wind_world = vec3(-1.0, 0.0, 0.0);
uniform float mesh_bottom_y = 0.0;
uniform float mesh_height = 1.0;
uniform float tip_displacement_ratio = 0.011;
uniform float gust_period_s = 10.0;
uniform float sway_period_s = 9.6;
uniform float gust_weight = 0.72;
uniform float rest_bend_ratio = 0.18;
uniform float bend_exponent = 1.8;
uniform float root_lock_fraction = 0.02;
uniform float crown_ripple_ratio = 0.12;
uniform float crown_layers = 3.0;

void vertex() {
	UV = UV * uv_scale + uv_offset;
	if (wind_enabled) {
		// MODEL_MATRIX includes the MultiMesh instance. World-space motion keeps
		// separately scaled heights/crowns and arbitrary tree yaw from changing
		// the shared screen-right-to-left wind direction.
		vec3 axis_y = MODEL_MATRIX[1].xyz;
		float axis_scale = max(length(axis_y), 0.000001);
		vec3 tree_up = axis_y / axis_scale;
		vec3 root = (MODEL_MATRIX * vec4(0.0, mesh_bottom_y, 0.0, 1.0)).xyz;
		float height_world = max(mesh_height * axis_scale, 0.000001);
		float h = clamp(dot(VERTEX - root, tree_up) / height_world, 0.0, 1.0);
		float u = clamp((h - root_lock_fraction) / (1.0 - root_lock_fraction), 0.0, 1.0);
		float strength = max(INSTANCE_CUSTOM.g, 0.0);
		float rate = max(INSTANCE_CUSTOM.b, 0.01);
		float phase = INSTANCE_CUSTOM.r * 6.28318530718 + dot(root.xz, vec2(0.17, 0.11));
		float shared_gust = 0.5 + 0.5 * sin(anim_t * 6.28318530718 / gust_period_s);
		float local_angle = anim_t * 6.28318530718 * rate / sway_period_s;
		float individual_sway = 0.5 + 0.5 * sin(local_angle + phase);
		float wind_strength = rest_bend_ratio + (1.0 - rest_bend_ratio) *
			mix(individual_sway, shared_gust, gust_weight);
		float trunk_bend = pow(u, bend_exponent) * wind_strength;
		// A small smooth wave through successive canopy levels. Its envelope is
		// zero at both root and tip, keeping the configured tip budget explicit.
		float crown_envelope = 4.0 * u * u * (1.0 - u) * (1.0 - u);
		float crown_bend = crown_ripple_ratio * crown_envelope *
			sin(local_angle * 0.73 + phase + u * crown_layers * 6.28318530718);
		float displacement = height_world * tip_displacement_ratio * strength * (trunk_bend + crown_bend);
		VERTEX += wind_world * displacement;
	}
}

void fragment() {
	if (wind_enabled) {
		// The source mesh has split facet normals. Recompute the deformed face
		// normal from view-space position so bending does not smooth the facets.
		vec3 face_normal = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
		if (dot(face_normal, NORMAL) < 0.0) {
			face_normal = -face_normal;
		}
		NORMAL = face_normal;
	}
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	ALBEDO = texture(texture_albedo, UV).rgb * albedo_color.rgb;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
