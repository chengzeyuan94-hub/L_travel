// Merchant board (Claude sample) — tree kit with a gentle wind sway (MultiMesh instances;
// MODEL_MATRIX is the instance transform, so every tree gets its own phase).
shader_type spatial;

uniform float sway = 0.035;
uniform float speed = 1.1;
uniform float board_wind_gust = 1.0;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float ph = origin.x * 0.37 + origin.z * 0.61;
	float h = max(VERTEX.y, 0.0);
	float g = 0.6 + 0.4 * sin(TIME * 0.23 + origin.x * 0.05);   // travelling gusts
	float s = sin(TIME * speed + ph) * sway * h * h * g * board_wind_gust;
	VERTEX.x += s;
	VERTEX.z += 0.5 * sin(TIME * speed * 0.8 + ph * 1.7) * sway * h * h * g * board_wind_gust;
}

void fragment() {
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.9;
}
