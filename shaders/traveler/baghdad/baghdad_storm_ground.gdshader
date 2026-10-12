shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 sand_color : source_color = vec4(0.73, 0.63, 0.48, 1.0);
varying vec3 world_position;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float sand_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i),hash(i+vec2(1.0,0.0)),f.x),
		mix(hash(i+vec2(0.0,1.0)),hash(i+vec2(1.0)),f.x),f.y);
}
void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
}
void fragment() {
	vec2 p = world_position.xz;
	float damp = smoothstep(0.24,0.80,sand_noise(p*0.63));
	float worn = sand_noise(p*12.0);
	float grain = sand_noise(p*145.0);
	float fade = 1.0-smoothstep(6.0,22.0,world_position.z);
	float aggregate = mix(1.0,0.89+grain*0.20,fade);
	ALBEDO = sand_color.rgb * mix(0.77,1.01,damp) * (0.95+worn*0.09) * aggregate;
	ROUGHNESS = mix(0.82,0.96,damp);
	SPECULAR = 0.18;
	METALLIC = 0.0;
	// Small physical surface normals; the material uses actual world coordinates.
	float dx = sand_noise((p+vec2(0.003,0.0))*145.0)-grain;
	float dz = sand_noise((p+vec2(0.0,0.003))*145.0)-grain;
	vec3 tx = normalize((VIEW_MATRIX*vec4(1.0,0.0,0.0,0.0)).xyz);
	vec3 tz = normalize((VIEW_MATRIX*vec4(0.0,0.0,1.0,0.0)).xyz);
	NORMAL = normalize(NORMAL - (tx*dx+tz*dz)*0.13*fade);
}
