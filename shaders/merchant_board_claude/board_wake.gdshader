// Merchant board (Claude sample) — a boat's wake: a soft white V of foam trailing behind the
// hull, flat on the water (PlaneMesh, +X = the boat's heading, the boat sits at uv.x = 1).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

instance uniform float moving = 1.0;
uniform float light = 1.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void fragment() {
	float along = UV.x;              // 1 at the stern, 0 far behind
	float side = UV.y * 2.0 - 1.0;   // -1 .. 1 across
	float spread = (1.0 - along) * 0.9 + 0.08;
	float arm = abs(abs(side) - spread);
	float foam = 1.0 - smoothstep(0.0, 0.09 + (1.0 - along) * 0.08, arm);
	float churn = (1.0 - smoothstep(0.0, 0.14, abs(side))) * smoothstep(0.55, 1.0, along);   // prop wash
	float n = vnoise(vec2(along * 18.0 + TIME * 3.0, side * 6.0));
	float a = max(foam * (0.5 + 0.5 * n), churn * 0.6 * n) * along * moving;
	if (a < 0.01) discard;
	ALBEDO = vec3(0.96, 0.99, 1.0) * light;
	ALPHA = a * 0.8;
}
