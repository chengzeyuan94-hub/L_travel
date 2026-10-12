shader_type canvas_item;
// 两个世界的合成：雨/开花世界（A）与晚霞世界（B）。
// Carlos 2026-09-23：「过渡到晚霞的时间拉长到 8 秒，我希望是云层滚动之后露出蓝天和黄昏，有那种时间过渡的感知」。
// 风一直从画面右吹向左，所以两次过渡都是"云影前沿"从右向左扫过整个画面（天空和地面一起，地面上就是云影掠过）：
//   direction 0（转晚霞）：暴雨云的尾部边缘向左移走，身后露出太阳、晚霞、蓝天；
//   direction 1（转回雨）：新雨云的前沿从右边压进来，向左盖住。
// 前沿形状是随云一起向左平移的噪声（noise_scroll 与雨云天空的滚动同步），另叠一点全局溶解让光线是渐变的。
uniform sampler2D tex_a : filter_linear;
uniform sampler2D tex_b : filter_linear;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform int direction = 0;
uniform float soft = 0.22;           // 前沿软边宽度
uniform float wipe = 0.85;           // 0 = 纯溶解，1 = 纯前沿推进
uniform float noise_amount = 0.45;   // 前沿的云状起伏
uniform vec2 noise_scale = vec2(2.2, 3.6);
uniform float noise_scroll = 0.0;    // 前沿噪声的水平平移（uv），与云滚动同步
uniform float tilt = 0.25;           // >0：天空比地面先放晴（前沿斜着走）
uniform float aspect = 1.7777778;
uniform vec3 edge_color_ab : source_color = vec3(1.0, 0.74, 0.46);
uniform vec3 edge_color_ba : source_color = vec3(0.55, 0.64, 0.78);
uniform float edge_glow = 0.08;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float noise2(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * noise2(p);
		p = p * 2.03 + vec2(7.3, 1.9);
		a *= 0.5;
	}
	return v / 0.96875;
}
uniform vec2 opening_x = vec2(0.20, 0.80);   // 拱门开口在画面上的左右边界（uv.x）；前沿在这段宽度里走完
float front(vec2 uv, float p) {
	// 0 = 开口右边缘（太阳一侧），1 = 开口左边缘；天空（uv.y 小）稍微提前
	float along = (opening_x.y - uv.x) / max(opening_x.y - opening_x.x, 1e-3);
	along = along * (1.0 - tilt) + uv.y * tilt;
	vec2 q = vec2((uv.x + noise_scroll) * aspect * noise_scale.x, uv.y * noise_scale.y);
	float field = along + (fbm(q) - 0.5) * noise_amount;
	float q_p = mix(-0.5 * soft, 1.0 + 0.5 * noise_amount, p);
	float spatial = 1.0 - smoothstep(q_p, q_p + soft, field);
	spatial *= smoothstep(0.0, 0.10, p);          // p=0 时纯雨世界
	spatial = max(spatial, smoothstep(0.86, 1.0, p));  // 结尾把左边柱子等剩余部分补齐
	return mix(p, spatial, wipe);
}
void fragment() {
	vec3 a = texture(tex_a, UV).rgb;
	vec3 b = texture(tex_b, UV).rgb;
	float m;
	vec3 edge_color;
	if (direction == 0) {
		m = front(UV, progress);
		edge_color = edge_color_ab;
	} else {
		m = 1.0 - front(UV, progress);
		edge_color = edge_color_ba;
	}
	vec3 col = mix(a, b, m);
	float band = m * (1.0 - m) * 4.0;
	col += edge_color * band * edge_glow * step(0.001, progress) * step(progress, 0.999);
	COLOR = vec4(col, 1.0);
}
