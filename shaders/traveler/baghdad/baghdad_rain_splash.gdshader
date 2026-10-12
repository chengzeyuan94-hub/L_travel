shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform float rain_time = 0.0;
varying float age;
varying float variation;

void vertex() {
	age = fract(rain_time * 0.5 * mix(1.6, 2.8, INSTANCE_CUSTOM.g) + INSTANCE_CUSTOM.r);
	variation = INSTANCE_CUSTOM.b;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float radius = length(p);
	float target = mix(0.06, 0.92, age);
	float ring = 1.0 - smoothstep(0.035, 0.09, abs(radius - target));
	float fade = (1.0 - age) * smoothstep(0.0, 0.07, age);
	float broken = mix(0.45, 1.0, smoothstep(-0.1, 0.7, sin(atan(p.y, p.x) * 5.0 + variation * 20.0)));
	ALBEDO = vec3(0.57, 0.68, 0.77);
	ALPHA = ring * fade * broken * 0.30;
}
