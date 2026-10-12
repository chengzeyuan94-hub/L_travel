shader_type particles;
// sand / 沙脊扬沙 的粒子运动（look-dev 探针，不是交付代码）。
// 出生点：GDScript 从相机视角求出的沙丘轮廓脊点（crest_tex）。每缕从脊上被风掀起，
// 顺风（屏幕右 → 左）飘、微微上抬、拉长变宽、变淡。出生时按阵风包络定这一缕的浓度（大多数很淡）。
// VELOCITY 用来存出生点（disable_velocity，不参与积分）。
// CUSTOM = (浓度, 已活时间/LIFETIME, 种子 0..1, 本粒子寿命占比)
render_mode disable_velocity, disable_force;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform vec4 hmap = vec4(-12.0, 3.0, 6.6667, 0.0);
uniform vec2 hsize = vec2(161.0, 161.0);
uniform sampler2D crest_tex : filter_nearest, repeat_disable;   // RGBA32F: 世界 x, y, z, 抖动半径
uniform int crest_count = 1;
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);

uniform vec2 speed = vec2(0.3, 0.55);        // u/s 顺风
uniform vec2 rise = vec2(0.02, 0.06);        // u/s 上抬
uniform vec2 len0 = vec2(0.35, 0.6);         // 出生时长度（u）
uniform vec2 len1 = vec2(1.4, 2.4);          // 消散时长度
uniform vec2 hgt0 = vec2(0.08, 0.14);
uniform vec2 hgt1 = vec2(0.28, 0.5);
uniform float alpha = 0.22;
uniform vec2 strength = vec2(0.2, 1.0);
uniform float strength_pow = 1.6;
uniform vec2 life_frac = vec2(0.7, 1.0);
uniform vec4 gust = vec4(9.7, 6.1, 3.0, 0.6);
uniform float fade_in = 0.25;
uniform float fade_pow = 1.4;

uint hash_u(uint x) {
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = (x >> uint(16)) ^ x;
	return x;
}

float rnd(inout uint s) {
	s = hash_u(s + uint(1013904223));
	return float(s & uint(16777215)) / 16777216.0;
}

float hgt(vec2 xz) {
	vec2 t = (xz - hmap.xy) * hmap.z;
	return textureLod(height_tex, (t + 0.5) / hsize, 0.0).r;
}

float gust_at(vec2 xz, float t) {
	float s = dot(xz, wind_dir.xz);
	float ph = t - s / max(gust.z, 0.01);
	float a = 0.5 + 0.5 * sin(ph * 6.2831853 / gust.x);
	float b = 0.5 + 0.5 * sin(ph * 6.2831853 / gust.y + 1.7);
	return clamp(a * 0.65 + b * 0.35, 0.0, 1.0);
}

void params(float seedf, out float spd, out float rs, out float l0, out float l1, out float h0, out float h1) {
	uint k = uint(seedf * 16777216.0);
	spd = mix(speed.x, speed.y, rnd(k));
	rs = mix(rise.x, rise.y, rnd(k));
	l0 = mix(len0.x, len0.y, rnd(k));
	l1 = mix(len1.x, len1.y, rnd(k));
	h0 = mix(hgt0.x, hgt0.y, rnd(k));
	h1 = mix(hgt1.x, hgt1.y, rnd(k));
}

mat4 place(vec3 origin, float t, float age, float spd, float rs, float l0, float l1, float h0, float h1) {
	float L = mix(l0, l1, pow(clamp(age, 0.0, 1.0), 0.7));
	float H = mix(h0, h1, clamp(age, 0.0, 1.0));
	vec3 p = origin + wind_dir * (spd * t + L * 0.45) + vec3(0.0, rs * t + H * 0.42, 0.0);
	float g = hgt(p.xz);
	p.y = max(p.y, g + H * 0.3);
	vec3 az = normalize(cross(wind_dir, vec3(0.0, 1.0, 0.0)));
	return mat4(vec4(wind_dir * L, 0.0), vec4(0.0, H, 0.0, 0.0), vec4(az, 0.0), vec4(p, 1.0));
}

void start() {
	uint s = hash_u(RANDOM_SEED ^ hash_u(NUMBER * uint(1597334677) + INDEX + uint(77)));
	float seedf = float(s & uint(16777215)) / 16777216.0;
	uint k2 = hash_u(s ^ uint(1540483477));
	int idx = clamp(int(rnd(k2) * float(crest_count)), 0, max(crest_count - 1, 0));
	vec4 c = texelFetch(crest_tex, ivec2(idx, 0), 0);
	float jx = (rnd(k2) - 0.5) * 2.0 * c.w;
	vec3 origin = vec3(c.x, c.y, c.z) + vec3(jx * wind_dir.z, 0.0, -jx * wind_dir.x);   // 沿脊线方向（垂直风向）抖一点
	origin.y = max(hgt(origin.xz), c.y - 0.05);
	float st = mix(strength.x, strength.y, pow(rnd(k2), strength_pow));
	st *= mix(1.0 - gust.w, 1.0, gust_at(origin.xz, TIME));
	float lf = mix(life_frac.x, life_frac.y, rnd(k2));
	VELOCITY = origin;
	CUSTOM = vec4(st, 0.0, seedf, lf);
	float spd; float rs; float l0; float l1; float h0; float h1;
	params(seedf, spd, rs, l0, l1, h0, h1);
	TRANSFORM = place(origin, 0.0, 0.0, spd, rs, l0, l1, h0, h1);
	COLOR = vec4(1.0, 1.0, 1.0, 0.0);
}

void process() {
	CUSTOM.y += DELTA / LIFETIME;
	float age = CUSTOM.y / max(CUSTOM.w, 0.01);
	if (age >= 1.0) {
		ACTIVE = false;
	}
	float spd; float rs; float l0; float l1; float h0; float h1;
	params(CUSTOM.z, spd, rs, l0, l1, h0, h1);
	float t = CUSTOM.y * LIFETIME;
	TRANSFORM = place(VELOCITY, t, age, spd, rs, l0, l1, h0, h1);
	float env = smoothstep(0.0, fade_in, age) * pow(clamp(1.0 - age, 0.0, 1.0), fade_pow);
	COLOR = vec4(1.0, 1.0, 1.0, clamp(env * alpha * CUSTOM.x, 0.0, 1.0));
}
