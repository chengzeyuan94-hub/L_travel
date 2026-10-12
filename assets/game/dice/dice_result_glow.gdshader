shader_type canvas_item;
render_mode unshaded, blend_mix;

// 局部结果光：透明画布内只有中心柔边光晕，绝不产生矩形蒙层。
uniform vec4 glow_color : source_color = vec4(0.72, 0.18, 0.16, 0.14);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d = length(p);
	float falloff = 1.0 - smoothstep(0.15, 1.0, d);
	falloff = pow(max(falloff, 0.0), 2.2);
	COLOR = vec4(glow_color.rgb, glow_color.a * intensity * falloff);
}
