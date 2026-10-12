// 第四幕 · soft faceted smoke / steam puffs (chimney smoke, camp-fire wisps, cup steam), fix #4: every puff of a
// tile is one instance of a single MultiMesh, so the smoke costs one draw call. Per-kind colours are uniform arrays
// (linear, pushed by lshu_life.gd); per-puff opacity, warmth and kind ride in INSTANCE_CUSTOM (x alpha, y warm,
// z kind index). Faceted normals keep the low-poly look of the web puffs.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_lambert, specular_disabled;

const int SMOKE_KINDS = 3;
uniform vec3 puff_colors[SMOKE_KINDS];
uniform vec3 warm_colors[SMOKE_KINDS];
uniform float self_lits[SMOKE_KINDS];   // night: smoke keeps a little of its own colour against a dark sky
uniform float edge_soft = 0.8;

varying flat vec4 v_puff;

void vertex() {
	v_puff = INSTANCE_CUSTOM;
}

void fragment() {
	int k = clamp(int(v_puff.z + 0.5), 0, SMOKE_KINDS - 1);
	vec3 fn = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = fn;
	float ndv = clamp(dot(fn, VIEW), 0.0, 1.0);
	ALBEDO = puff_colors[k];
	ROUGHNESS = 1.0;
	EMISSION = warm_colors[k] * v_puff.y + puff_colors[k] * self_lits[k];
	ALPHA = clamp(v_puff.x * mix(1.0, pow(ndv, 0.7), edge_soft), 0.0, 1.0);
}
