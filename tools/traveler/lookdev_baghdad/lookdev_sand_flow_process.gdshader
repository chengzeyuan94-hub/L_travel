shader_type particles;
// sand / 贴地流沙 + 空中细沙闪光 的粒子运动（look-dev 探针，不是交付代码）。
// 世界坐标（local_coords = false，节点在原点）。风向 wind_dir 已压平归一化（屏幕右 → 左）。
// 每帧：沿风向平移 → 用烘焙的沙面高度图贴地 → 按风向坡度倾斜面片 → 算淡入淡出 × 阵风包络写进 COLOR.a。
// CUSTOM = (类型 0 流沙 / 1 闪光, 已活时间/LIFETIME, 种子 0..1, 本粒子寿命占比)
render_mode disable_velocity, disable_force;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform vec4 hmap = vec4(-12.0, 3.0, 6.6667, 0.0);   // 世界 x0, 世界 z0, 1/步长
uniform vec2 hsize = vec2(161.0, 161.0);
uniform sampler2D spawn_tex : filter_nearest, repeat_disable;  // RGBA32F: 世界 x, 世界 z, 相机深度, 抖动半径
uniform int spawn_count = 1;
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);
uniform vec3 cam_pos = vec3(0.0, 0.18, 0.0);
uniform vec3 cam_fwd = vec3(0.0, 0.0, 1.0);          // 水平前向
uniform float focal_px = 1483.7;
uniform int glint_every = 6;

uniform vec2 flow_speed = vec2(0.45, 0.8);           // u/s
uniform vec2 flow_len_px = vec2(60.0, 150.0);
uniform vec2 flow_len_clamp = vec2(0.25, 1.6);       // u
uniform float flow_quad_px = 10.0;
uniform vec2 flow_lift = vec2(0.01, 0.07);           // 面片底边离沙面（u）
uniform float flow_alpha = 0.5;
uniform vec2 life_frac = vec2(0.55, 1.0);

uniform vec2 glint_speed = vec2(0.9, 1.5);
uniform float glint_px = 3.0;
uniform float glint_blur = 0.8;                      // 按每帧位移拉长（运动模糊）
uniform vec2 glint_lift = vec2(0.04, 0.4);
uniform float glint_alpha = 1.0;
uniform float frame_dt = 0.0333333;

uniform float fade_in = 0.2;
uniform float fade_out = 0.35;
uniform vec4 gust = vec4(9.7, 6.1, 3.0, 0.55);       // 周期 a, 周期 b, 阵风锋面速度 u/s, 深度

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

// 从种子重建本粒子的全部随机参数（start 与 process 同一序列）
void params(float seedf, bool glint, out float speed, out float len_px, out float lift, out float bob_ph, out float tint) {
	uint k = uint(seedf * 16777216.0);
	float r_speed = rnd(k);
	float r_len = rnd(k);
	float r_lift = rnd(k);
	bob_ph = rnd(k) * 6.2831853;
	tint = rnd(k);
	speed = glint ? mix(glint_speed.x, glint_speed.y, r_speed) : mix(flow_speed.x, flow_speed.y, r_speed);
	len_px = mix(flow_len_px.x, flow_len_px.y, r_len);
	lift = glint ? mix(glint_lift.x, glint_lift.y, r_lift * r_lift) : mix(flow_lift.x, flow_lift.y, r_lift * r_lift);
}

mat4 place(vec2 xz, bool glint, float speed, float len_px, float lift, float bob_ph, float t) {
	float d = max(dot(vec3(xz.x, 0.0, xz.y) - vec3(cam_pos.x, 0.0, cam_pos.z), cam_fwd), 0.5);
	float upx = d / focal_px;                                  // 每像素多少 u
	float h = hgt(xz);
	vec3 ax;
	float L;
	float T;
	float y;
	if (glint) {
		T = glint_px * upx;
		L = (glint_px + glint_blur * speed / upx * frame_dt) * upx;
		y = h + lift + 0.035 * sin(t * 1.3 + bob_ph);
		ax = wind_dir;
	} else {
		T = flow_quad_px * upx;
		L = clamp(len_px * upx, flow_len_clamp.x, flow_len_clamp.y);
		float h1 = hgt(xz + wind_dir.xz * 0.3);
		float h0 = hgt(xz - wind_dir.xz * 0.3);
		float slope = (h1 - h0) / 0.6;
		ax = normalize(vec3(wind_dir.x, slope, wind_dir.z));
		y = h + lift + T * 0.5 + 0.008 * sin(t * 0.9 + bob_ph);
	}
	vec3 az = normalize(cross(ax, vec3(0.0, 1.0, 0.0)));
	vec3 ay = normalize(cross(az, ax));
	return mat4(vec4(ax * L, 0.0), vec4(ay * T, 0.0), vec4(az, 0.0), vec4(xz.x, y, xz.y, 1.0));
}

void start() {
	uint s = hash_u(RANDOM_SEED ^ hash_u(NUMBER * uint(1597334677) + INDEX));
	float seedf = float(s & uint(16777215)) / 16777216.0;
	bool glint = (int(INDEX) % glint_every) == 0;
	float speed; float len_px; float lift; float bob_ph; float tint;
	params(seedf, glint, speed, len_px, lift, bob_ph, tint);
	uint k2 = hash_u(s ^ uint(1540483477));
	float r_pick = rnd(k2);
	float r_jx = rnd(k2);
	float r_jz = rnd(k2);
	float r_life = rnd(k2);
	int idx = clamp(int(r_pick * float(spawn_count)), 0, max(spawn_count - 1, 0));
	vec4 sp = texelFetch(spawn_tex, ivec2(idx, 0), 0);
	float lf = mix(life_frac.x, life_frac.y, r_life);
	vec2 xz = sp.xy + (vec2(r_jx, r_jz) - 0.5) * 2.0 * sp.w;
	xz -= wind_dir.xz * speed * LIFETIME * lf * 0.5;          // 让整段路径以采样点为中心
	TRANSFORM = place(xz, glint, speed, len_px, lift, bob_ph, TIME);
	CUSTOM = vec4(glint ? 1.0 : 0.0, 0.0, seedf, lf);
	float tv = (tint - 0.5) * 0.08;
	COLOR = vec4(1.0 + tv, 1.0, 1.0 - tv, 0.0);
	VELOCITY = vec3(0.0);
}

void process() {
	bool glint = CUSTOM.x > 0.5;
	float speed; float len_px; float lift; float bob_ph; float tint;
	params(CUSTOM.z, glint, speed, len_px, lift, bob_ph, tint);
	CUSTOM.y += DELTA / LIFETIME;
	float age = CUSTOM.y / max(CUSTOM.w, 0.01);
	if (age >= 1.0) {
		ACTIVE = false;
	}
	vec2 xz = TRANSFORM[3].xz + wind_dir.xz * speed * DELTA;
	TRANSFORM = place(xz, glint, speed, len_px, lift, bob_ph, TIME);
	float env = smoothstep(0.0, fade_in, age) * (1.0 - smoothstep(1.0 - fade_out, 1.0, age));
	float g = gust_at(xz, TIME);
	float a = glint ? glint_alpha : flow_alpha;
	COLOR.a = clamp(env * a * mix(1.0 - gust.w, 1.0, g), 0.0, 1.0);
}
