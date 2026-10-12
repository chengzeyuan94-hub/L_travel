shader_type spatial;
// 长安旅人 · 日暮人物金边：受阴影的菲涅尔边（TASK-CHANGAN-DUSK-001，2026-09-24 由探针 rim_next_pass.gdshader 转正，数学逐字不变）。
// 人物生成后由 changan_dusk_driver.gd 挂在人物各表面的 next_pass 上，加色混合；淡入淡出时按 dusk_mix 缩放 rim_intensity。
//   - 走 light()，乘 ATTENUATION：处在太阳阴影里的部分不出金边；
//   - 只认太阳（平行光且方向与 sun_dir_world 一致），灯笼 / 佛窟点光、冷补光都不会描边；
//   - 逆光因子 back：视线越对着太阳，边越亮；距离衰减 fade_*（本 pass 关了雾，所以自己淡）。
// ALBEDO=0 + ambient_light_disabled：不吃环境光 / SSIL / 反射，只有 light() 里写的 SPECULAR_LIGHT 被加上去。
render_mode blend_add, cull_back, depth_draw_never, fog_disabled, ambient_light_disabled;

uniform vec3 rim_color : source_color = vec3(1.0, 0.76, 0.42);
uniform float rim_intensity = 1.2;
uniform float rim_power = 3.0;          // 越大边越窄
uniform vec3 sun_dir_world = vec3(-0.91, 0.24, -0.33);
uniform float dir_softness = 0.3;       // 法线朝太阳的过渡宽度
uniform float dir_weight = 0.85;        // 0 = 四周均匀，1 = 只在朝阳一侧
uniform float back_min = -0.1;          // dot(L, 视线方向)：越背光越亮
uniform float back_max = 0.7;
uniform float fade_start = 25.0;        // 离相机距离（u）
uniform float fade_end = 120.0;
uniform float fade_min = 0.35;

varying float v_fade;

void fragment() {
	float d = length(VERTEX);
	v_fade = mix(1.0, fade_min, smoothstep(fade_start, fade_end, d));
	ALBEDO = vec3(0.0);
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		vec3 sun_v = normalize((VIEW_MATRIX * vec4(sun_dir_world, 0.0)).xyz);
		if (dot(LIGHT, sun_v) > 0.985) {
			float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
			float fres = pow(1.0 - ndv, rim_power);
			float toward = smoothstep(-dir_softness, dir_softness, dot(NORMAL, LIGHT));
			float w = mix(1.0, toward, dir_weight);
			float back = smoothstep(back_min, back_max, dot(LIGHT, -VIEW));
			SPECULAR_LIGHT += rim_color * rim_intensity * fres * w * back * ATTENUATION * v_fade;
		}
	}
}
