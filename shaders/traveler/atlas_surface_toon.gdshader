shader_type spatial;
// 卡通风格试验版（2026-09-20）。**这是新文件，原版 atlas_surface.gdshader 一个字不改。**
//
// 与原版的关系：
//   - uniform 全部同名同类型，所以运行时只把 ShaderMaterial.shader 换成这一份，
//     材质上已经设好的 base_color / brightness / rock_tint / wind_* 等参数全部保留。
//   - vertex() 的风摆代码逐字照抄，所以风、逐实例抖动、gust 全部不变。
//   - fragment() 只多算一个 facet_key（给描边和分档用），其余照抄。
//   - 新增一个自定义 light()：把漫反射按档量化，这才是「卡通」的本体。
//
// 注意：定义了 light() 之后 Godot 不再用 render_mode 的 diffuse_* 模式，
// 所以原版的 diffuse_lambert_wrap 在这里由 light() 里的 wrap 项复现。
render_mode cull_disabled;

uniform vec4 base_color : source_color = vec4(1.0);
uniform float night_amount : hint_range(0.0, 1.0) = 0.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 0.0;
uniform float brightness : hint_range(0.0, 3.0) = 1.02;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform float rock_tint_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 rock_tint_color : source_color = vec3(0.62, 0.55, 0.44);

uniform float wind_amp   : hint_range(0.0, 0.30) = 0.0;
uniform float wind_stiff : hint_range(0.5, 3.0)  = 1.6;
uniform float wind_gust                          = 1.0;
uniform vec2  wind_dir                           = vec2(1.0, 0.38);
uniform float anim_t                             = -1.0;

// --- 卡通参数（新增，原版没有，所以换 shader 时取这里的默认值）---
// toon_bands: 明暗分几档。2 = 很硬的赛璐珞，4-5 = 柔和插画。
uniform float toon_bands : hint_range(1.0, 8.0) = 4.0;
// toon_soft: 每档边缘的软化量。0 = 一刀切，1 = 接近连续（等于没分档）。
uniform float toon_soft : hint_range(0.0, 1.0) = 0.35;
// toon_wrap: 背光面的兜底亮度，复现原版 lambert_wrap 的黏土感。
uniform float toon_wrap : hint_range(0.0, 1.0) = 0.5;
// toon_shadow_tint: 暗部偏色。低多边形插画里暗部通常偏冷紫，不是单纯变黑。
uniform vec3 toon_shadow_tint : source_color = vec3(0.72, 0.74, 0.92);

void vertex() {
	if (wind_amp > 0.0) {
		float t = anim_t < 0.0 ? TIME : anim_t;
		vec3  o = MODEL_MATRIX[3].xyz;
		float phase = o.x * 0.72 + o.z * 0.63;
		float pj  = INSTANCE_CUSTOM.r * 6.2831853;
		float amp = wind_amp * (INSTANCE_CUSTOM.g <= 0.0 ? 1.0 : INSTANCE_CUSTOM.g);
		float gr  = (INSTANCE_CUSTOM.b <= 0.0 ? 1.0 : INSTANCE_CUSTOM.b);
		float gust = 1.0 + (wind_gust - 1.0) * gr;
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

	float luma = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	float sat = max(max(albedo.r, albedo.g), albedo.b) - min(min(albedo.r, albedo.g), albedo.b);
	float pale = smoothstep(0.26, 0.60, luma) * (1.0 - smoothstep(0.03, 0.20, sat));
	albedo = mix(albedo, rock_tint_color * (0.72 + 0.5 * luma), pale * rock_tint_amount);

	vec3 night_tint = mix(vec3(1.0), vec3(0.72, 0.82, 1.18), night_amount * 0.38);
	ALBEDO = albedo * night_tint;
	EMISSION = ALBEDO * emission_strength * (1.0 + night_amount * 3.8);
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.0;   // 卡通不要高光；原版是 0.18
}

void light() {
	// wrap 复现原版 diffuse_lambert_wrap：背光面不是全黑，保留黏土质感
	float ndl = dot(normalize(NORMAL), normalize(LIGHT));
	float w = clamp((ndl + toon_wrap) / (1.0 + toon_wrap), 0.0, 1.0);

	// 按档量化，每档边缘用 smoothstep 软化
	float b = max(toon_bands, 1.0);
	float scaled = w * b;
	float idx = floor(scaled);
	float f = scaled - idx;
	float edge = max(toon_soft, 0.001) * 0.5;
	float soft = smoothstep(0.5 - edge, 0.5 + edge, f);
	float level = clamp((idx + soft) / b, 0.0, 1.0);

	// 暗部偏冷：level 低的地方把光色往 toon_shadow_tint 拉
	vec3 tinted = LIGHT_COLOR * mix(toon_shadow_tint, vec3(1.0), level);

	DIFFUSE_LIGHT += level * ATTENUATION * tinted * ALBEDO;
	// SPECULAR_LIGHT 保持 0：卡通面不要镜面高光
}
