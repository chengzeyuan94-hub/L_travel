// Merchant board (Claude sample) — soft-faceted ground.
// Mesh normals are crease-smoothed (gentle slopes shade softly, cliffs stay crisp);
// a little of the flat face normal is mixed back in so the low-poly facets still read.
shader_type spatial;
uniform float flat_amount : hint_range(0.0, 1.0) = 0.3;
void fragment() {
	vec3 fn = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	NORMAL = normalize(mix(NORMAL, fn, flat_amount));
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.93;
}
