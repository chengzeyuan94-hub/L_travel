// Merchant board (Claude sample) — player tokens (L叔 riding a camel / sailing a boat).
// Models face +X, Y up, Z = side. Faces painted with the team-colour key (sRGB 255,0,255 main,
// 150,0,150 shade) take the player's colour. Driven by tools/merchant_board_claude_token.gd:
//   stride    0..1 walk-cycle strength (camel legs swing, body bobs); 0 = standing
//   walk_rate walk-cycle angular speed (rad/s), tied to the ground speed so feet do not skate
//   hip       model-space height below which vertices are legs (camel)
//   flag_from model-space height above which vertices are the pennant (flutters in the wind)
shader_type spatial;
render_mode cull_disabled;

uniform vec3 team_color : source_color = vec3(0.8, 0.28, 0.23);
uniform float stride = 0.0;
uniform float walk_rate = 6.0;
uniform float walk_phase = 0.0;
uniform float hip = 0.25;
uniform float stride_amp = 0.085;
uniform float body_bob = 0.018;
uniform float flag_from = 10.0;
uniform float flag_x = 0.0;         // pennant hoist (pole axis): it flies toward -x from here
uniform float flutter = 1.0;
uniform float highlight = 0.0;      // 0..1 selection glow (current player)
uniform float night_lift = 0.0;

varying float is_team;
varying float team_dark;

void vertex() {
	float ph = walk_phase;
	vec3 v = VERTEX;
	float leg = clamp((hip - v.y) / max(hip, 1e-3), 0.0, 1.0);
	// diagonal pairs together: front-left with rear-right
	float pair = (v.x > 0.0 ? 0.0 : 3.1416) + (v.z > 0.0 ? 0.0 : 3.1416);
	v.x += sin(ph + pair) * stride_amp * leg * stride;
	v.y += max(sin(ph + pair), 0.0) * 0.03 * leg * stride;           // lift the stepping foot
	v.y += abs(sin(ph)) * body_bob * stride * (1.0 - leg);
	// the camel's neck and head (front of the body, above the legs) nod twice per stride
	float head = smoothstep(0.22, 0.34, v.x) * step(hip + 0.2, v.y);
	v.y += sin(ph * 2.0) * 0.014 * stride * head;
	v.x += cos(ph * 2.0) * 0.008 * stride * head;
	// pennant: ripples along its length, stronger toward the free end
	float fl = clamp((v.y - flag_from) / 0.08, 0.0, 1.0);
	float along = max(flag_x - v.x, 0.0);
	v.z += sin(TIME * 7.0 - along * 30.0) * 0.022 * fl * flutter * along * 6.0;
	VERTEX = v;
	vec3 c = COLOR.rgb;   // linear
	is_team = step(0.6, c.r) * step(0.6, c.b) * step(c.g, 0.05);
	team_dark = step(0.2, c.r) * step(0.2, c.b) * step(c.g, 0.02) * (1.0 - is_team);
}

void fragment() {
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	vec3 c = COLOR.rgb;
	c = mix(c, team_color, is_team);
	c = mix(c, team_color * 0.62, team_dark);
	ALBEDO = c;
	EMISSION = c * night_lift + team_color * highlight * 0.35 * (is_team + team_dark);
	ROUGHNESS = 0.7;
	SPECULAR = 0.3;
	RIM = 0.25;
	RIM_TINT = 0.4;
}
