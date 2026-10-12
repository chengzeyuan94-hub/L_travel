shader_type canvas_item;

void fragment() {
	vec4 color = texture(TEXTURE, UV);
	if (color.a < 0.015) {
		color = vec4(0.0);
	}
	COLOR = color;
}
