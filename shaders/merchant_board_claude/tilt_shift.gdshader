// Merchant board (Claude sample) — tilt-shift miniature look.
// A sharp horizontal focus band; above and below it the image blurs progressively
// (mip-mapped golden-angle taps), with a gentle vignette and a touch of warmth.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float focus_center = 0.55;   // screen v of the sharp band
uniform float focus_half = 0.16;     // half height of the fully sharp band
uniform float falloff = 0.3;         // distance over which blur ramps to full
uniform float max_radius = 0.009;    // max blur radius (fraction of screen height)
uniform float max_lod = 1.4;
uniform float vignette = 0.22;
uniform float edge_saturation = 1.08;

void fragment() {
	vec2 uv = SCREEN_UV;
	float d = max(0.0, abs(uv.y - focus_center) - focus_half);
	float t = smoothstep(0.0, falloff, d);
	float aspect = SCREEN_PIXEL_SIZE.x > 0.0 ? SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x : 1.0;
	vec3 c;
	if (t < 0.002) {
		c = texture(screen_tex, uv).rgb;
	} else {
		float lod = t * max_lod;
		float r = t * max_radius;
		c = vec3(0.0);
		const int N = 24;
		for (int i = 0; i < N; i++) {
			float a = float(i) * 2.39996;
			float rr = r * sqrt((float(i) + 0.5) / float(N));
			vec2 o = vec2(cos(a) / aspect, sin(a)) * rr;
			c += textureLod(screen_tex, uv + o, lod).rgb;
		}
		c /= float(N);
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(vec3(l), c, mix(1.0, edge_saturation, t));
	}
	vec2 v = (uv - 0.5) * vec2(1.0, 1.25);
	c *= 1.0 - vignette * smoothstep(0.1, 0.55, dot(v, v));
	COLOR = vec4(c, 1.0);
}
