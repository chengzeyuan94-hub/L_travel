shader_type spatial;
// 长安旅人 · 日暮雪面柔光（TASK-CHANGAN-DUSK-001，2026-09-24 由探针 bounce_snow_sheen.gdshader 转正，数学逐字不变）。
// 接在远景雪山 FarBackdrop/MassifBandMerged 的材质链末尾（next_pass），加色混合；淡入淡出时按 dusk_mix 缩放 sheen_strength。
// 只画雪（顶点色亮、低饱和；山体岩石顶点色亮度 ~0.09，雪 ~0.89，界线干净），不改原材质，也不改雪线。
// 三个成分：朝阳面整体微亮（夕照映雪）、太阳 Blinn 高光瓣、掠射角菲涅尔（只在朝阳一侧）。
// unshaded + blend_add：引擎只输出 ALBEDO；fog_disabled 避免雾色被重复加上，远近衰减用 distance_fade_* 手动给。
render_mode blend_add, unshaded, cull_back, depth_draw_never, fog_disabled, shadows_disabled;

uniform vec3 sun_dir_world = vec3(-0.91, 0.24, -0.33);   // 指向太阳（extra 脚本写入）
uniform vec3 sheen_color : source_color = vec3(1.0, 0.70, 0.62);
uniform float sheen_strength = 0.2;
uniform float face_amount = 0.5;
uniform float face_min = 0.05;
uniform float face_max = 0.75;
uniform float lobe_amount = 0.8;
uniform float lobe_power = 10.0;
uniform float fres_amount = 0.5;
uniform float fres_power = 3.0;
uniform float snow_lo = 0.45;
uniform float snow_hi = 0.75;
uniform float distance_fade_near = 60.0;
uniform float distance_fade_far = 260.0;
uniform float distance_fade_min = 0.45;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float l = dot(max(COLOR.rgb, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
	float snow = smoothstep(snow_lo, snow_hi, l);
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 v = normalize(CAMERA_POSITION_WORLD - v_world);
	vec3 L = normalize(sun_dir_world);
	float ndl = dot(n, L);
	float face = smoothstep(face_min, face_max, ndl);
	float lobe = pow(max(dot(n, normalize(L + v)), 0.0), lobe_power) * smoothstep(-0.05, 0.2, ndl);
	float fres = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), fres_power) * smoothstep(-0.1, 0.35, ndl);
	float d = length(CAMERA_POSITION_WORLD - v_world);
	float fade = mix(1.0, distance_fade_min, smoothstep(distance_fade_near, distance_fade_far, d));
	ALBEDO = sheen_color * snow * sheen_strength * fade * (face * face_amount + lobe * lobe_amount + fres * fres_amount);
	ALPHA = 1.0;
}
