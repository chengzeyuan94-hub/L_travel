// L叔在哪儿 · L2 scatter shader (role "scatter"): MultiMesh grass tufts, flowers, pebbles, snow lumps,
// twigs and leaves placed by lshu_scatter.gd (placement baked offline). Same sRGB colour convention as the tile surfaces:
// COLOR = mesh vertex colour × MultiMesh instance colour, multiplied in sRGB and decoded here.
// UV.x = 1 marks petal vertices (colour from INSTANCE_CUSTOM.rgb); UV.y = 1 marks soft-normal geometry
// (blades / petals / leaves take the ground's up-normal so they light like the ground, both sides).
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx, depth_draw_opaque;

uniform bool vertex_color_srgb = true;
uniform float albedo_gain = 1.0;
uniform float saturation = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform float specular_amount : hint_range(0.0, 1.0) = 0.2;
uniform float emission_strength = 0.0;
uniform float anim_time = 0.0;
uniform float wind_strength = 0.0;       // injected from motion.wind_strength
uniform float l2_sway = 55.0;            // bend (m) per m² of local height × wind_strength
uniform float l2_soft_normal = 0.8;      // how far soft geometry leans to the up normal
uniform float l2_petal_gain = 1.0;

varying vec3 v_petal;
varying float v_is_petal;
varying float v_soft;
varying vec3 v_up_world;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float h = max(VERTEX.y, 0.0);
	if (wind_strength > 0.0 && UV.y > 0.5) {
		float g = sin(anim_time * 1.9 + wp.x * 1.7 + wp.z * 1.1) * 0.7 + sin(anim_time * 3.3 + wp.x * 4.1 - wp.z * 2.3) * 0.3;
		float bend = h * h * l2_sway * wind_strength;
		VERTEX.x += g * bend;
		VERTEX.z += cos(anim_time * 1.4 + wp.z * 1.9) * bend * 0.5;
	}
	v_petal = INSTANCE_CUSTOM.rgb;
	v_is_petal = UV.x;
	v_soft = UV.y;
	v_up_world = normalize((MODEL_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

void fragment() {
	vec3 c = COLOR.rgb;
	if (v_is_petal > 0.5) {
		c = v_petal * COLOR.a;
	}
	vec3 base = vertex_color_srgb ? srgb_to_linear(c) : c;
	if (v_is_petal > 0.5) {
		base *= l2_petal_gain;
	}
	base *= albedo_gain;
	float lum = dot(base, vec3(0.2126, 0.7152, 0.0722));
	base = max(mix(vec3(lum), base, saturation), vec3(0.0));
	if (v_soft > 0.5) {
		vec3 up_view = normalize((VIEW_MATRIX * vec4(v_up_world, 0.0)).xyz);
		vec3 n = NORMAL;
		NORMAL = normalize(mix(n, up_view, l2_soft_normal));
	}
	ALBEDO = base;
	ROUGHNESS = roughness;
	SPECULAR = specular_amount;
	EMISSION = base * emission_strength;
}
