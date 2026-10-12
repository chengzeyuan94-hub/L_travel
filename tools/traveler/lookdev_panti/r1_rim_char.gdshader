shader_type spatial;
// r1（视觉瑕疵审查）副本：只加主光闸门——平行光分支只认方向与 sun_dir_world 一致的 Daylight（由 r1_extra_rim.gd 放进
// a_rim_sync 的同步列表每帧更新）。C 线的 C_BounceCamp 是照人物的平行光、不投影，原来会再叠一整圈不受阴影约束的边（贴纸感）。
// A 线（光与轮廓）· 盘橐坐姿人物 · 菲涅尔轮廓光 pass。挂在 PantiSeatedBody 各表面材质的 next_pass 上，加色混合。
// 人物是光滑法线的卡通模型（DIFFUSE_TOON），菲涅尔用 smoothstep 做成窄而硬的一条带，和卡通明暗一致。
// 两路：
//   1. 主光（平行光：清晨太阳 / 深夜月亮）：朝光一侧 + 逆光更亮 + 可偏向朝上的法线（头顶、肩膀），乘 ATTENUATION（阴影里不出边）。
//   2. 篝火（暖色点光）：朝火一侧的暖边；按灯色判断"暖"（r 明显大于 b），冷色的 NightCharacterFill 不参与。
//      LIGHT_COLOR 含篝火每帧跳动的能量，所以暖边跟着火光一起呼吸。
// 所有强度由 variant 的 morning / midnight 两节插值。
// 注意：人物主材质是 ALPHA_DEPTH_PRE_PASS（透明队列）+ 双面，所以这个 pass 也双面，并由 a_extra_rim.gd 把 render_priority 设为 1，
// 保证在透明队列里排在人物本体之后画；否则本体的 alpha 混合会把加上去的边光整片盖掉（只剩轮廓处几根细线）。
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
