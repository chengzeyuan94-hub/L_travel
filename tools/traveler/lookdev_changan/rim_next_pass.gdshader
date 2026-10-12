shader_type spatial;
// rim 线 · 受阴影的金边叠加 pass（长安日暮探针）。挂在 StandardMaterial3D 节点（人物、佛窟山崖、远景雪山）的 next_pass 上，加色混合。
// 与 lookdev_baghdad/lookdev_fresnel_rim.gdshader 的区别：
//   - 走 light()，乘 ATTENUATION：被佛窟山、房子挡住、处在太阳阴影里的部分不出金边；
//   - 只认太阳（平行光且方向与 sun_dir_world 一致），灯笼 / 佛窟点光、冷补光都不会描边；
//   - 逆光因子 back：视线越对着太阳，边越亮（顺光一侧自然消失）；
//   - 距离衰减 fade_*：远景雪山的边跟着空气透视一起淡，不会从雾里跳出来（本 pass 关了雾，所以自己淡）。
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
