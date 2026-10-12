shader_type canvas_item;

// Bottom-up alpha reveal; does not alter smoke color.
// UV.y = 0 top, UV.y = 1 bottom.
uniform float reveal_progress : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 color = texture(TEXTURE, UV);
	float threshold = 1.0 - reveal_progress;
	float mask = smoothstep(threshold - 0.05, threshold + 0.02, UV.y);
	color.a *= mask * step(0.001, reveal_progress);
	COLOR = color;
}
