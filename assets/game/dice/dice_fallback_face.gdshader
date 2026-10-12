shader_type canvas_item;
render_mode unshaded;

// 与 3D 骰体共用同一张 atlas；只截取当前骰面，不使用 Unicode 替代符。
uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 cell_origin = vec2(0.0, 0.0);
uniform vec2 cell_size = vec2(0.333333, 0.5);
uniform float inset : hint_range(0.0, 0.08) = 0.02;

void fragment() {
	vec2 uv_in_cell = mix(vec2(inset), vec2(1.0 - inset), UV);
	vec2 atlas_uv = cell_origin + uv_in_cell * cell_size;
	vec4 c = texture(atlas, atlas_uv);
	// 轻微圆角遮罩，保证 fallback 仍像一颗骨骰的正面。
	vec2 q = abs(UV * 2.0 - 1.0) - vec2(0.82);
	float outside = length(max(q, vec2(0.0)));
	float mask = 1.0 - smoothstep(0.12, 0.19, outside);
	COLOR = vec4(c.rgb, c.a * mask);
}
