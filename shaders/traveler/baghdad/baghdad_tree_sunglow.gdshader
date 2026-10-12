shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;

// Keep the imported atlas and opaque PBR surface. Only the canopy faces toward
// the cloudbreak receive HDR emission for the localized canopy halo.
uniform sampler2D base_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 base_tint : source_color = vec4(1.0);
uniform bool use_texture = true;
uniform bool use_vertex_color = false;
uniform bool vertex_color_srgb = false;
uniform vec3 uv_scale = vec3(1.0);
uniform vec3 uv_offset = vec3(0.0);
uniform float surface_roughness = 0.9;
uniform float surface_specular = 0.18;
uniform vec3 beam_position = vec3(0.0);
uniform vec3 beam_direction = vec3(0.0, -1.0, 0.0);
uniform float beam_cos_outer = 0.995;
uniform float beam_cos_inner = 0.998;
uniform float beam_range = 20.0;
uniform float canopy_bottom = 2.6;
uniform float canopy_full = 4.0;
uniform float glow_strength = 6.5;
uniform vec3 glow_color : source_color = vec3(1.0, 0.82, 0.38);
varying vec3 world_position;

vec3 srgb_to_linear(vec3 color) {
	return mix(color / 12.92, pow((color + vec3(0.055)) / 1.055, vec3(2.4)),
		step(vec3(0.04045), color));
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	UV = UV * uv_scale.xy + uv_offset.xy;
}

void fragment() {
	vec3 base = base_tint.rgb;
	if (use_texture) {
		base *= texture(base_texture, UV).rgb;
	}
	if (use_vertex_color) {
		base *= vertex_color_srgb ? srgb_to_linear(COLOR.rgb) : COLOR.rgb;
	}
	ALBEDO = base;
	ROUGHNESS = surface_roughness;
	SPECULAR = surface_specular;
	METALLIC = 0.0;

	vec3 from_light = world_position - beam_position;
	float distance_to_light = length(from_light);
	vec3 light_ray = from_light / max(distance_to_light, 0.0001);
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float cone = smoothstep(beam_cos_outer, beam_cos_inner, dot(light_ray, beam_direction));
	float facing = smoothstep(0.0, 0.75, dot(world_normal, -light_ray));
	float canopy = smoothstep(canopy_bottom, canopy_full, world_position.y);
	float within_range = 1.0 - smoothstep(beam_range * 0.90, beam_range, distance_to_light);
	float luminance = dot(base, vec3(0.2126, 0.7152, 0.0722));
	float texture_detail = smoothstep(0.018, 0.15, luminance);
	vec3 leaf_color = base / max(max(base.r, max(base.g, base.b)), 0.001);
	vec3 warm_leaf = mix(glow_color, leaf_color * glow_color, 0.60);
	EMISSION = warm_leaf * glow_strength * cone * facing * canopy * within_range * texture_detail;
}
