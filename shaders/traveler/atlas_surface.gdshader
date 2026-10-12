shader_type spatial;
// LOOKDEV REWRITE (2026-09-18, scratch clone only — original kept in the repo).
// Why: the original used `ambient_light_disabled` and faked ambient+fill inside EMISSION.
// Godot's SSAO/SSIL only modulate REAL ambient light, so with the original shader no amount
// of Environment post-processing could ever produce contact occlusion. Here we hand lighting
// back to the engine: vertex colour albedo, flat facets, wrap diffuse for the clay feel.
render_mode cull_disabled, diffuse_lambert_wrap;

uniform vec4 base_color : source_color = vec4(1.0);
uniform float night_amount : hint_range(0.0, 1.0) = 0.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 0.0;
uniform float brightness : hint_range(0.0, 3.0) = 1.02;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
// Lifts pale cream/grey rocks toward stone-ochre so they stop reading as white blobs.
uniform float rock_tint_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 rock_tint_color : source_color = vec3(0.62, 0.55, 0.44);

// --- motion layer ---
// wind_amp is a TILT (dimensionless), not a distance: displacement = amp * lever,
// lever is in local units, so the same amp gives the same *relative* sway on a
// 0.27 u bush and a 1.05 u fir. Per-material values are in motion_params.json.
uniform float wind_amp   : hint_range(0.0, 0.30) = 0.0;
uniform float wind_stiff : hint_range(0.5, 3.0)  = 1.6;
uniform float wind_gust                          = 1.0;   // 0.55..1.55, MotionDirector, once per frame
uniform vec2  wind_dir                           = vec2(1.0, 0.38);
uniform float anim_t                             = -1.0;  // <0 => fall back to TIME (editor preview)

void vertex() {
	if (wind_amp > 0.0) {
		float t = anim_t < 0.0 ? TIME : anim_t;
		// MODEL_MATRIX[3] is the per-instance origin inside a MultiMesh
		// (already relied on by the shipped shader's own comment; step S1b re-verifies it).
		vec3  o = MODEL_MATRIX[3].xyz;
		// = the two web prototypes' phase terms summed: (x*0.44+z*0.26) + (x*0.28+z*0.37)
		float phase = o.x * 0.72 + o.z * 0.63;
		// per-instance jitter; INSTANCE_CUSTOM reads 0 on non-instanced draws, hence the guards
		float pj  = INSTANCE_CUSTOM.r * 6.2831853;
		float amp = wind_amp * (INSTANCE_CUSTOM.g <= 0.0 ? 1.0 : INSTANCE_CUSTOM.g);
		float gr  = (INSTANCE_CUSTOM.b <= 0.0 ? 1.0 : INSTANCE_CUSTOM.b);
		float gust = 1.0 + (wind_gust - 1.0) * gr;
		// cantilever: the base is rigid, the tip carries the travel, and the
		// trunk/canopy seam stays continuous without any per-vertex root height.
		float lever = pow(max(VERTEX.y, 0.0), wind_stiff);
		float move  = (sin(t * 1.1 + phase + pj) + 0.4 * sin(t * 1.8 + (phase + pj) * 1.6))
		              * amp * gust * lever;
		VERTEX.x += move * wind_dir.x;
		VERTEX.z += move * wind_dir.y;
	}
}

void fragment() {
	NORMAL = normalize(NORMAL) * (FRONT_FACING ? 1.0 : -1.0);
	vec3 albedo = max(COLOR.rgb, vec3(0.0)) * base_color.rgb * brightness;

	// Desaturated + bright => a pale rock or snow-ish facet. Push only those toward ochre.
	float luma = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	float sat = max(max(albedo.r, albedo.g), albedo.b) - min(min(albedo.r, albedo.g), albedo.b);
	float pale = smoothstep(0.26, 0.60, luma) * (1.0 - smoothstep(0.03, 0.20, sat));
	albedo = mix(albedo, rock_tint_color * (0.72 + 0.5 * luma), pale * rock_tint_amount);

	vec3 night_tint = mix(vec3(1.0), vec3(0.72, 0.82, 1.18), night_amount * 0.38);
	ALBEDO = albedo * night_tint;
	EMISSION = ALBEDO * emission_strength * (1.0 + night_amount * 3.8);
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.18;
}
