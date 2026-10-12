// Merchant board (Claude sample) — sea life that swims along paths. The review scene moves
// and orients every instance along its swim lane each frame; this shader only animates the
// body. Models swim along +X, Y up, Z = the side axis.
// INSTANCE_CUSTOM: x = motion (0 fish: tail sways sideways; 1 whale/dolphin: flukes beat
// up-down; 2 manta: wings flap; 3 turtle: flippers paddle), y = phase 0-1,
// z = beat rate (rad/s), w = amplitude (model units).
shader_type spatial;
render_mode cull_disabled;

void vertex() {
	vec4 cd = INSTANCE_CUSTOM;
	float ph = TIME * cd.z + cd.y * 6.2831;
	vec3 v = VERTEX;
	if (cd.x < 0.5) {
		float tail = clamp((-v.x - 0.2) / 0.3, 0.0, 1.0);
		v.z += sin(ph) * cd.w * tail + sin(ph + v.x * 3.0) * 0.02;
	} else if (cd.x < 1.5) {
		float tail = clamp((-v.x - 0.25) / 0.25, 0.0, 1.0);
		v.y += sin(ph) * cd.w * tail * tail + sin(ph - v.x * 2.0) * 0.012;
	} else if (cd.x < 2.5) {
		float wing = clamp((abs(v.z) - 0.18) / 0.55, 0.0, 1.0);
		v.y += sin(ph - abs(v.z) * 1.5) * cd.w * wing;
	} else {
		float fl = clamp((abs(v.z) - 0.2) / 0.3, 0.0, 1.0);
		v.y += sin(ph + step(0.0, v.x) * 3.1416) * cd.w * fl;
	}
	VERTEX = v;
}

uniform float night_lift = 0.0;
void fragment() {
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * night_lift;
	ROUGHNESS = 0.5;
	SPECULAR = 0.35;
}
