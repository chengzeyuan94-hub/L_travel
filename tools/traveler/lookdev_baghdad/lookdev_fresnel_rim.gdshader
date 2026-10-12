shader_type spatial;
// 金边叠加 pass：挂在主体材质的 next_pass 上，加色混合，只画菲涅尔边。
// 不依赖任何灯（材质 rim 会把场上每盏灯的颜色都加进边里，蓝补光会把金边冲灰）。
render_mode blend_add, unshaded, cull_back, depth_draw_never, fog_disabled;

uniform vec3 rim_color : source_color = vec3(1.0, 0.78, 0.40);
uniform float rim_power = 3.0;       // 越大边越窄
uniform float rim_intensity = 1.3;
uniform vec3 light_dir = vec3(-0.2, 0.1, 0.97);   // 世界空间，指向太阳
uniform float dir_weight = 0.6;      // 0 = 四周均匀，1 = 只在朝阳一侧
uniform float dir_softness = 0.35;

void fragment() {
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fres = pow(1.0 - ndv, rim_power);
	vec3 n_world = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float toward = smoothstep(-dir_softness, dir_softness, dot(n_world, normalize(light_dir)));
	float w = mix(1.0, toward, dir_weight);
	// unshaded 下引擎只输出 ALBEDO（EMISSION 被忽略），所以把边光直接写进 ALBEDO；blend_add 叠上去
	ALBEDO = rim_color * rim_intensity * fres * w;
	ALPHA = 1.0;
}
