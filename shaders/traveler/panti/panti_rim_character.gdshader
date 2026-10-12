shader_type spatial;
// Panti light polish · seated traveller rim (next_pass on PantiSeatedBody surface materials).
// Ported 1:1 from the approved probe (tools/traveler/lookdev_panti/r1_rim_char.gdshader, variant m4_final).
// Two paths: (1) main directional light only (main-light gate): narrow fresnel band toward the light, stronger when
// back-lit, optional up bias, x ATTENUATION with a shadow floor; (2) warm point lights (fire / lantern, warmth gate on
// (r - b) / r): a warm edge on the fire side that breathes with the flicker. The body material is in the transparent
// queue (ALPHA_DEPTH_PRE_PASS), so panti_rim_light.gd sets render_priority 1; depth_push 0 keeps the dark outline.
render_mode blend_add, cull_disabled, depth_draw_never, fog_disabled, ambient_light_disabled;

uniform vec3 rim_color : source_color = vec3(1.0, 0.85, 0.6);
uniform float rim_intensity = 1.0;
uniform float rim_lo = 0.55;             // 菲涅尔带（1 - N·V）起点
uniform float rim_hi = 0.85;
uniform float dir_softness = 0.35;
uniform float dir_weight = 0.85;         // 0 = 四周均匀，1 = 只在朝光一侧
uniform float back_min = -0.6;
uniform float back_max = 0.6;
uniform float back_floor = 0.35;
uniform float up_bias = 0.0;             // 0..1：偏向朝上的法线（头、肩）
uniform float shadow_floor = 0.0;        // 人物在帐篷 / 树影里时仍保留的边光比例（0 = 完全跟阴影走）

uniform vec3 fire_color : source_color = vec3(1.0, 0.62, 0.32);
uniform float fire_intensity = 0.0;
uniform float fire_lo = 0.45;
uniform float fire_hi = 0.8;
uniform float fire_side_min = -0.15;
uniform float fire_side_max = 0.45;
uniform float fire_warm_min = 0.4;       // (r - b) / r 超过它才算暖光（篝火 / 灯笼）
uniform float depth_push = 0.001;
uniform vec3 sun_dir_world = vec3(-0.8, 0.3, 0.5);
uniform float main_gate = 0.995;
varying vec3 v_main_dir;

void vertex() {
	vec4 vpos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vpos.xyz *= (1.0 - depth_push);
	POSITION = PROJECTION_MATRIX * vpos;
}

void fragment() {
	ALBEDO = vec3(0.0);
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	v_main_dir = normalize((VIEW_MATRIX * vec4(sun_dir_world, 0.0)).xyz);
}

void light() {
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float ndl = dot(NORMAL, LIGHT);
	if (LIGHT_IS_DIRECTIONAL) {
		float is_main = step(main_gate, dot(LIGHT, v_main_dir));
		float fres = smoothstep(rim_lo, rim_hi, 1.0 - ndv);
		float toward = smoothstep(-dir_softness, dir_softness, ndl);
		float wdir = mix(1.0, toward, dir_weight);
		float back = mix(back_floor, 1.0, smoothstep(back_min, back_max, dot(LIGHT, -VIEW)));
		float n_up = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y;
		float up = mix(1.0, smoothstep(-0.2, 0.7, n_up), up_bias);
		vec3 hue = LIGHT_COLOR / max(max(LIGHT_COLOR.r, LIGHT_COLOR.g), max(LIGHT_COLOR.b, 0.0001));   // 只取色相，亮度由 rim_intensity 决定（过渡不鼓包）
		SPECULAR_LIGHT += is_main * hue * rim_color * rim_intensity * fres * wdir * back * up * mix(shadow_floor, 1.0, ATTENUATION);
	} else if (fire_intensity > 0.0) {
		float warm = (LIGHT_COLOR.r - LIGHT_COLOR.b) / max(LIGHT_COLOR.r, 0.0001);
		float gate = smoothstep(fire_warm_min, fire_warm_min + 0.2, warm);
		float fres = smoothstep(fire_lo, fire_hi, 1.0 - ndv);
		float side = smoothstep(fire_side_min, fire_side_max, ndl);
		SPECULAR_LIGHT += LIGHT_COLOR / PI * fire_color * fire_intensity * fres * side * gate * ATTENUATION;
	}
}
