// 《山河旅人》 merchant board — 2D screen grade (after the 3D image, before the tilt-shift).
// Built on the "cinema" study's grade, without its aerial haze and light veil:
//  clarity   : luma-only local contrast (radius ~6 px), cored so the sea cell lines and ground
//              noise are not pulled out, and nearly off on open water;
//  bloom     : soft glow around the brightest things only (snow, clouds, surf, white walls), with
//              a warm, wider halation fringe; sand (luma ~0.8) sits below the knee;
//  sun       : a warm multiplicative light gain from the top-left (no screen veil, so the shade
//              there stays deep and nothing is washed out);
//  sea       : selective colour — deep water toward the concept's azure, shallows toward clean
//              turquoise (less red);
//  tone      : a toe that deepens only the darkest tones by scaling luma (richer, never greyer);
//  grade     : gain, slightly cool deep shade, warm highlights (not on greens), vibrance that
//              spares the calibrated sand, and a faint cream lift of the highlights so the sand
//              stays yellow rather than drifting orange, and near-white snow / surf / coins
//              lifted to a clean white; foliage is spared the toe so forests stay lush;
//  vignette  : delicate and warm (the tilt-shift adds its own).
// Strengths follow the scene key (deep mip), so noon, dusk and twilight share it: the darker
// presets turn the toe off and let city lamps bloom.
// Cost: 1 + 5 (key) + 4 (clarity) + 16 (bloom) = 26 texture taps.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

uniform float clarity = 0.30;
uniform float clarity_core = 0.012;
uniform float clarity_water = 0.2;   // fraction of the clarity kept on open water
uniform float bloom_strength = 0.34;
uniform float bloom_threshold = 0.84;
uniform float bloom_knee = 0.08;
uniform float halation = 0.10;
uniform vec3 halation_tint = vec3(1.0, 0.6, 0.36);
uniform vec3 bloom_tint = vec3(1.0, 0.97, 0.92);
uniform float sun_glow = 0.26;
uniform float sun_rays = 0.35;       // soft angular beams in the light
uniform vec2 sun_pos = vec2(-0.08, -0.16);
uniform float sun_falloff = 3.2;
uniform vec3 sun_gain = vec3(0.55, 0.3, -0.04);
uniform float sea_shift = 1.0;
uniform float toe = 0.30;
uniform float toe_pivot = 0.52;
uniform float shoulder = 0.3;
uniform vec3 lift = vec3(-0.012, -0.002, 0.010);
uniform vec3 gain = vec3(1.01, 1.0, 0.99);
uniform float vibrance = 0.16;
uniform vec3 shadow_tint = vec3(-0.008, 0.003, 0.012);
uniform vec3 highlight_tint = vec3(0.012, 0.004, -0.004);
uniform vec3 cream = vec3(1.0, 0.965, 0.885);
uniform float cream_lift = 0.06;
uniform float white_lift = 0.5;      // near-white, unsaturated (snow, surf, sea coins, clouds) toward clean white
uniform float toe_green_keep = 0.85;  // how much of the toe foliage is spared (forests stay lush, not darker)
uniform float vignette = 0.06;
uniform float dither = 0.0;          // optional sub-LSB dither against banding (off: keeps flat water clean)
uniform float key_ref = 0.52;

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

vec3 bright(vec3 c, float thr) {
	float l = luma(c);
	float s = clamp(l - thr + bloom_knee, 0.0, 2.0 * bloom_knee);
	s = s * s / (4.0 * bloom_knee + 1e-4);
	float w = max(s, l - thr) / max(l, 1e-4);
	return c * w;
}

vec3 screen_blend(vec3 a, vec3 b) { return 1.0 - (1.0 - a) * (1.0 - clamp(b, 0.0, 1.0)); }

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = SCREEN_PIXEL_SIZE;
	float aspect = px.y / px.x;
	vec3 c = texture(screen_tex, uv).rgb;

	// scene key (display-space average luma: noon ~0.52, dusk / twilight lower)
	vec3 key = textureLod(screen_tex, vec2(0.5, 0.5), 8.0).rgb + textureLod(screen_tex, vec2(0.2, 0.3), 8.0).rgb
		+ textureLod(screen_tex, vec2(0.8, 0.3), 8.0).rgb + textureLod(screen_tex, vec2(0.2, 0.75), 8.0).rgb
		+ textureLod(screen_tex, vec2(0.8, 0.75), 8.0).rgb;
	float kf = clamp(luma(key / 5.0) / key_ref, 0.3, 1.2);

	// clarity (luma unsharp, radius ~6 px, cored; almost off on open water)
	vec3 b1 = textureLod(screen_tex, uv + vec2(2.0, 1.0) * px, 2.0).rgb + textureLod(screen_tex, uv + vec2(-1.0, 2.0) * px, 2.0).rgb
		+ textureLod(screen_tex, uv + vec2(-2.0, -1.0) * px, 2.0).rgb + textureLod(screen_tex, uv + vec2(1.0, -2.0) * px, 2.0).rgb;
	b1 *= 0.25;
	float lc = luma(c);
	float detail = lc - luma(b1);
	detail = sign(detail) * max(abs(detail) - clarity_core, 0.0);
	detail = clamp(detail, -0.12, 0.12);
	float water0 = clamp((c.b - c.r) * 3.0 - 0.3, 0.0, 1.0) * step(c.r, c.g);
	float lnew = max(lc + detail * clarity * mix(1.0, clarity_water, water0) * (1.0 - 0.6 * smoothstep(0.75, 1.0, lc)), 0.0);
	c *= lnew / max(lc, 1e-3);

	// bloom + halation from mips (threshold drops in darker presets so lamps glow)
	float thr = clamp(bloom_threshold * mix(0.62, 1.0, clamp(kf, 0.0, 1.0)), 0.5, 0.92);
	vec3 bl_near = vec3(0.0);
	vec3 bl_far = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.785398 + 0.39;
		vec2 dir = vec2(cos(a) / aspect, sin(a));
		bl_near += bright(textureLod(screen_tex, uv + dir * 0.006, 2.5).rgb, thr);
		bl_far += bright(textureLod(screen_tex, uv + dir * 0.02, 4.5).rgb, thr + 0.02);
	}
	float night = 1.0 - smoothstep(0.4, 0.85, kf);
	vec3 bloom = (bl_near * bloom_tint * bloom_strength * (1.0 + night) + bl_far * halation_tint * halation * (1.0 + 2.0 * night)) / 8.0;
	c = screen_blend(c, bloom);

	// warm sun light from the top-left: a gain only (keeps the shade deep, adds no veil)
	vec2 sp = (uv - sun_pos) * vec2(aspect, 1.0);
	float r = length(sp);
	float g = exp(-r * sun_falloff) * 0.75 + exp(-r * sun_falloff * 2.6) * 0.25;
	float ang = atan(sp.y, sp.x);
	float rays = 0.5 + 0.5 * sin(ang * 23.0 + 1.3) * sin(ang * 37.0 + 0.4);
	g *= 1.0 - sun_rays + sun_rays * 2.0 * rays * smoothstep(0.05, 0.3, r);
	float gl = g * sun_glow * mix(0.55, 1.0, clamp(kf, 0.0, 1.0));
	c *= 1.0 + gl * sun_gain;

	// sea selective colour: blue-dominant pixels (foam spared)
	float sea = clamp((c.b - c.r) * 3.0 - 0.3, 0.0, 1.0) * step(c.r, c.g) * (1.0 - smoothstep(0.55, 0.8, c.r));
	float deep = smoothstep(0.95, 0.62, c.g / max(c.b, 1e-3));
	sea *= sea_shift;
	c.r *= 1.0 - 0.45 * sea * (1.0 - deep);
	c.g *= 1.0 + 0.14 * sea * deep;
	c.b = min(c.b * (1.0 + 0.03 * sea), 1.0);

	// tone: deepen the toe, lift the shoulder, both by scaling luma (keeps chroma)
	float l = luma(c);
	float lt = l;
	float foliage = smoothstep(0.02, 0.1, c.g - max(c.r, c.b));
	if (l < toe_pivot) {
		float q = 1.0 - l / toe_pivot;
		lt = l - toe * smoothstep(0.45, 0.9, kf) * l * q * q * (1.0 - toe_green_keep * foliage);   // night presets keep their glow
	} else if (l > 0.78) {
		lt = l + shoulder * (l - 0.78) * (1.0 - l) / 0.22;
	}
	c *= lt / max(l, 1e-4);

	// gain / lift and split toning
	c = c * gain + lift * (1.0 - c);
	l = luma(c);
	float greenish = smoothstep(0.02, 0.12, c.g - max(c.r, c.b) + 0.06);
	c += shadow_tint * (1.0 - smoothstep(0.04, 0.4, l)) + highlight_tint * smoothstep(0.55, 0.95, l) * (1.0 - 0.7 * greenish);

	// vibrance, sparing the warm bright sand (it is calibrated and must not go orange)
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	float sat = (mx - mn) / max(mx, 1e-3);
	float sandish = smoothstep(0.72, 0.88, c.r) * step(c.g, c.r) * step(c.b, c.g) * (1.0 - greenish);
	l = luma(c);
	c = mix(vec3(l), c, 1.0 + vibrance * (1.0 - sat) * smoothstep(0.02, 0.2, mx) * (1.0 - 0.85 * sandish));

	// faint cream lift of the highlights (sand toward the concept's yellow, snow warmer white)
	c = mix(c, cream * max(mx, 0.9), cream_lift * smoothstep(0.62, 0.95, l) * (1.0 - greenish) * clamp(kf, 0.0, 1.0));

	// near-white, unsaturated highlights toward a clean white (snow caps, surf, sea coins)
	mx = max(c.r, max(c.g, c.b));
	mn = min(c.r, min(c.g, c.b));
	float wsat = (mx - mn) / max(mx, 1e-3);
	l = luma(c);
	c = mix(c, vec3(1.0, 0.995, 0.98), white_lift * smoothstep(0.76, 0.92, l) * (1.0 - smoothstep(0.08, 0.22, wsat)) * clamp(kf, 0.0, 1.0));

	// delicate warm vignette
	vec2 v = (uv - 0.5) * vec2(1.0, 1.2);
	float vg = smoothstep(0.18, 0.62, dot(v, v));
	c *= mix(vec3(1.0), vec3(0.97, 0.93, 0.88), vg * vignette * 6.0);

	// optional sub-LSB dither against banding (off by default)
	c += (hash(uv * vec2(1931.0, 1087.0)) - 0.5) * dither;

	COLOR = vec4(clamp(c, 0.0, 1.0), 1.0);
}
