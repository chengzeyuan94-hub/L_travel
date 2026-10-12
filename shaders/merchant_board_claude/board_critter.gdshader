// Merchant board (Claude sample) — small animated creatures and vehicles placed by
// tools/merchant_board_claude_life.gd (MultiMesh). Models face +X, Y up, Z = side.
// INSTANCE_CUSTOM: x = mode (0 legs walk, 1 wing flap, 2 rigid), y = phase 0-1,
// z = stride (0 = standing still, 1 = full walk), w = beat rate (rad/s).
shader_type spatial;
render_mode cull_disabled;

uniform float hip = 0.4;        // model-space height below which vertices belong to the legs
uniform float stride_amp = 0.09;
uniform float wing_from = 0.12; // |z| beyond which vertices are wing
uniform float wing_amp = 0.18;
uniform float body_bob = 0.015;

void vertex() {
	vec4 cd = INSTANCE_CUSTOM;
	float ph = TIME * cd.w + cd.y * 6.2831;
	vec3 v = VERTEX;
	if (cd.x < 0.5) {
		float leg = clamp((hip - v.y) / max(hip, 1e-3), 0.0, 1.0);
		// diagonal pairs move together: front-left with rear-right
		float pair = (v.x > 0.0 ? 0.0 : 3.1416) + (v.z > 0.0 ? 0.0 : 3.1416);
		v.x += sin(ph + pair) * stride_amp * leg * cd.z;
		v.y += abs(sin(ph)) * body_bob * cd.z * (1.0 - leg);
		// idle: a slow grazing nod of the head end
		v.y -= (1.0 - cd.z) * max(v.x - 0.2, 0.0) * 0.12 * (0.5 + 0.5 * sin(TIME * 0.7 + cd.y * 11.0));
	} else if (cd.x < 1.5) {
		float wing = clamp((abs(v.z) - wing_from) / 0.45, 0.0, 1.0);
		v.y += sin(ph - abs(v.z) * 1.2) * wing_amp * wing;
	}
	VERTEX = v;
}

void fragment() {
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.75;
	SPECULAR = 0.25;
}
