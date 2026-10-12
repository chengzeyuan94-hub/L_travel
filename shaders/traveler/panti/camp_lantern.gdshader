shader_type spatial;
render_mode diffuse_burley, specular_disabled;
uniform sampler2D basecolor : source_color, filter_linear_mipmap, repeat_enable;
uniform float emission_energy = 1.3;
void fragment() {
	vec3 c=texture(basecolor,UV).rgb;
	ALBEDO=c;
	ROUGHNESS=0.82;
	// Only the warm glass cells emit; the dark iron frame remains opaque and lit.
	float glass=smoothstep(0.27,0.56,c.r)*smoothstep(0.07,0.20,c.g-c.b);
	EMISSION=c*vec3(1.0,0.68,0.30)*glass*emission_energy;
}
