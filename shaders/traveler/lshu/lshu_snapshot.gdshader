// L叔在哪儿 · tile-switch dissolve: draws a GPU copy of the last frame over the stage. The copied render target keeps
// the 3D pass's alpha (0 on the backdrop), so the alpha is replaced by the fade value instead of read from the copy.
shader_type canvas_item;

uniform float fade : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	COLOR = vec4(texture(TEXTURE, UV).rgb, fade);
}
