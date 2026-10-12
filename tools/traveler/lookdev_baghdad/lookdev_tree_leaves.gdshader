shader_type particles;
// 生命树落叶（探针 key: tree，2026-09-23）：替换 LookdevFallingLeaves 的 ParticleProcessMaterial。
// 叶子从树冠表面（偏下风侧、偏朝相机一侧）生出，先"挂一下"再被风带走：
//   水平速度 = 风速 × 阵风（与树摆动同一套相位，树弯下去时叶子也加速），1.4 s 缓起；
//   叠一个钟摆式左右荡（荡到两端微微上扬），慢慢下落；少数"远飘"叶子下落更慢、起初被托高、风速更快。
// 姿态：绕接近风向的轴翻转 + 随机初始朝向，边飘边翻；出生 0.5 s 从 0 长到全尺寸，寿命末尾/贴地前缩掉。
// 所有随机量都由每片叶子的种子派生（CUSTOM.x），速度交给引擎积分（位置连续，阵风变化不会跳）。
render_mode disable_force;

uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0);
uniform vec3 toward_camera = vec3(0.0, 0.0, -1.0);   // 水平、单位
uniform vec3 crown_center = vec3(0.0, 4.2, 0.0);
uniform vec3 crown_radii = vec3(2.45, 3.2, 2.45);
uniform vec2 spawn_shell = vec2(0.86, 1.0);
uniform vec2 spawn_height = vec2(-0.8, 0.65);         // 单位球 y 的范围（去掉树梢和最底）
uniform float spawn_downwind_bias = 0.45;
uniform float spawn_front_bias = 0.5;
uniform float gust01 = 0.5;                           // 由 GDScript 每帧同步（树冠中心处的阵风 0..1）
uniform vec2 wind_speed = vec2(0.45, 0.75);           // u/s
uniform float gust_speed_gain = 0.6;                  // 阵风对风速的调制：×[1-g/2, 1+g/2]
uniform vec2 fall_speed = vec2(0.12, 0.24);
uniform vec2 side_speed = vec2(-0.04, 0.12);          // + = 朝相机
uniform float drifter_fraction = 0.15;
uniform vec2 drifter_wind_speed = vec2(0.75, 0.95);
uniform vec2 drifter_fall_speed = vec2(0.02, 0.06);
uniform float drifter_lift = 0.22;                    // 初始上托 u/s，3 s 衰减
uniform float accel_time = 1.4;
uniform float swing_amp = 0.12;                       // 钟摆荡幅 u
uniform vec2 swing_hz = vec2(0.25, 0.45);
uniform float swing_dip = 0.35;
uniform vec2 spin_hz = vec2(0.25, 0.8);
uniform vec2 scale_range = vec2(0.8, 1.25);
uniform float grow_time = 0.5;
uniform float shrink_time = 0.8;
uniform float ground_y = 0.3;
uniform vec2 life_fraction = vec2(0.8, 1.0);
uniform vec3 color0 = vec3(0.42, 0.58, 0.16);
uniform vec3 color1 = vec3(0.70, 0.66, 0.14);
uniform vec3 color2 = vec3(0.92, 0.66, 0.16);
uniform vec3 color3 = vec3(0.85, 0.45, 0.12);
uniform float brightness_jitter = 0.06;

uint hash_u(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

float rnd(uint seed, uint k) {
	return float(hash_u(seed * 0x9E3779B9u + k * 0x85EBCA6Bu + 0x68E31DA4u) & 0x00FFFFFFu) / 16777216.0;
}

mat3 axis_angle(vec3 a, float ang) {
	float c = cos(ang);
	float s = sin(ang);
	float t = 1.0 - c;
	return mat3(
		vec3(t * a.x * a.x + c, t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y),
		vec3(t * a.x * a.y - s * a.z, t * a.y * a.y + c, t * a.y * a.z + s * a.x),
		vec3(t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c));
}

void start() {
	uint seed = hash_u(NUMBER * 747796405u + RANDOM_SEED * 2891336453u + 17u) & 0xFFFFu;
	CUSTOM = vec4(float(seed), 0.0, 0.0, mix(life_fraction.x, life_fraction.y, rnd(seed, 1u)));
	float y = mix(spawn_height.x, spawn_height.y, rnd(seed, 2u));
	float a = rnd(seed, 3u) * TAU;
	float r = sqrt(max(1.0 - y * y, 0.0));
	vec3 side = normalize(cross(vec3(0.0, 1.0, 0.0), wind_dir));
	vec3 d = wind_dir * (r * cos(a)) + side * (r * sin(a)) + vec3(0.0, y, 0.0);
	d += wind_dir * spawn_downwind_bias + toward_camera * spawn_front_bias;
	d = normalize(d);
	vec3 pos = crown_center + d * crown_radii * mix(spawn_shell.x, spawn_shell.y, rnd(seed, 4u));
	TRANSFORM = mat4(vec4(0.0, 0.0, 0.0, 0.0), vec4(0.0, 0.0, 0.0, 0.0), vec4(0.0, 0.0, 0.0, 0.0), vec4(pos, 1.0));
	VELOCITY = vec3(0.0);
	float pick = rnd(seed, 5u) * 4.0;
	vec3 col = pick < 1.0 ? color0 : (pick < 2.0 ? color1 : (pick < 3.0 ? color2 : color3));
	col *= 1.0 + (rnd(seed, 22u) - 0.5) * 2.0 * brightness_jitter;
	COLOR = vec4(col, 1.0);
}

void process() {
	uint seed = uint(CUSTOM.x);
	CUSTOM.y += DELTA / LIFETIME;
	float age = CUSTOM.y * LIFETIME;
	bool drifter = rnd(seed, 6u) < drifter_fraction;
	float vw = drifter ? mix(drifter_wind_speed.x, drifter_wind_speed.y, rnd(seed, 7u)) : mix(wind_speed.x, wind_speed.y, rnd(seed, 7u));
	float vf = drifter ? mix(drifter_fall_speed.x, drifter_fall_speed.y, rnd(seed, 8u)) : mix(fall_speed.x, fall_speed.y, rnd(seed, 8u));
	float vs = mix(side_speed.x, side_speed.y, rnd(seed, 9u));
	float ease = smoothstep(0.0, accel_time, age);
	float gust = 1.0 - 0.5 * gust_speed_gain + gust_speed_gain * gust01;
	float sw_w = TAU * mix(swing_hz.x, swing_hz.y, rnd(seed, 10u));
	float th = sw_w * age + rnd(seed, 11u) * TAU;
	float psi = (rnd(seed, 12u) - 0.5) * 1.6;
	vec3 swing_axis = normalize(wind_dir * cos(psi) + toward_camera * sin(psi));
	vec3 v = wind_dir * (vw * gust) + toward_camera * vs;
	v += swing_axis * (swing_amp * sw_w * cos(th));
	v.y += -vf + swing_amp * swing_dip * sw_w * sin(2.0 * th);
	v *= ease;
	if (drifter) {
		v.y += drifter_lift * exp(-age / 3.0) * ease;
	}
	VELOCITY = v;

	float spin_w = TAU * mix(spin_hz.x, spin_hz.y, rnd(seed, 13u)) * (rnd(seed, 14u) < 0.5 ? -1.0 : 1.0);
	vec3 spin_axis = normalize(wind_dir + (vec3(rnd(seed, 15u), rnd(seed, 16u), rnd(seed, 17u)) - 0.5) * 1.2);
	vec3 a0 = normalize(vec3(rnd(seed, 18u), rnd(seed, 19u), rnd(seed, 20u)) - 0.5 + vec3(0.001));
	mat3 rot = axis_angle(spin_axis, spin_w * age) * axis_angle(a0, rnd(seed, 21u) * TAU);
	rot = axis_angle(normalize(cross(swing_axis, vec3(0.0, 1.0, 0.0)) + vec3(0.0, 0.001, 0.0)), 0.45 * sin(th)) * rot;
	vec3 pos = TRANSFORM[3].xyz;
	float end_age = CUSTOM.w * LIFETIME;
	float s = mix(scale_range.x, scale_range.y, rnd(seed, 23u));
	s *= smoothstep(0.0, grow_time, age);
	s *= 1.0 - smoothstep(end_age - shrink_time, end_age, age);
	s *= smoothstep(ground_y, ground_y + 0.3, pos.y);
	TRANSFORM = mat4(vec4(rot[0] * s, 0.0), vec4(rot[1] * s, 0.0), vec4(rot[2] * s, 0.0), vec4(pos, 1.0));
	if (CUSTOM.y > CUSTOM.w || pos.y < ground_y) {
		ACTIVE = false;
	}
}
