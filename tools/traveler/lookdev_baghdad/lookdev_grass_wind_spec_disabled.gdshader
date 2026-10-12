shader_type spatial;
// 地面草随风（lookdev_extra_grass.gd）。等价于草原来的 StandardMaterial3D（顶点色/贴图当颜色、burley 漫反射、
// 可选背光），只多了 vertex() 里的风。风向与云、落叶、风沙一致（画面右 → 左）。
render_mode blend_mix, depth_draw_opaque, diffuse_burley, specular_schlick_ggx, cull_disabled;

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_texture = false;
uniform bool use_vertex_color = true;
uniform bool vertex_color_is_srgb = false;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);
uniform float roughness_v : hint_range(0.0, 1.0) = 0.9;
uniform float specular_v : hint_range(0.0, 1.0) = 0.5;
uniform bool use_backlight = false;
uniform vec3 backlight_color : source_color = vec3(0.0);

uniform vec3 grass_wind_world = vec3(1.0, 0.0, 0.0);
uniform float grass_sway_ratio = 0.22;      // 草尖位移 = ratio × 草高
uniform float grass_gust_period = 5.5;      // 阵风周期 s
uniform float grass_wave_k = 0.9;           // 阵风沿风向传播的空间频率（rad/u）
uniform float grass_rest_bend = 0.35;       // 无阵风时也保持的顺风弯
uniform float grass_flutter = 0.35;         // 细抖相对幅度
uniform float grass_flutter_hz = 1.7;
uniform float grass_height_mode = 0.0;      // 0 = UV2.x 是世界高度；1 = UV2.x 是局部高度（MultiMesh）

void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;
	if (use_vertex_color && vertex_color_is_srgb) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
	vec3 gw_p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float gw_h = UV2.x * (grass_height_mode > 0.5 ? length(MODEL_MATRIX[1].xyz) : 1.0);
	float gw_rel = clamp(UV2.y, 0.0, 1.0);
	float gw_phase = dot(gw_p.xz, grass_wind_world.xz) * grass_wave_k;
	float gw_gust = 0.5 + 0.5 * sin(TIME * 6.2831853 / grass_gust_period - gw_phase);
	gw_gust = grass_rest_bend + (1.0 - grass_rest_bend) * gw_gust * gw_gust;
	float gw_fl = sin(TIME * 6.2831853 * grass_flutter_hz + gw_p.x * 13.1 + gw_p.z * 7.7) * grass_flutter;
	float gw_d = grass_sway_ratio * gw_h * gw_rel * (gw_gust + gw_fl * (0.4 + 0.6 * gw_gust));
	vec3 gw_side = normalize(cross(vec3(0.0, 1.0, 0.0), grass_wind_world) + vec3(1e-5));
	vec3 gw_off = grass_wind_world * gw_d + gw_side * gw_d * 0.25 * sin(TIME * 4.3 + gw_p.z * 9.0);
	gw_off.y -= gw_d * gw_d / max(gw_h, 1e-4) * 0.5;
	VERTEX += (inverse(MODEL_MATRIX) * vec4(gw_off, 0.0)).xyz;
}

void fragment() {
	vec4 c = albedo_color;
	if (use_texture) {
		c *= texture(texture_albedo, UV);
	}
	if (use_vertex_color) {
		c *= COLOR;
	}
	ALBEDO = c.rgb;
	METALLIC = 0.0;
	ROUGHNESS = roughness_v;
	SPECULAR = specular_v;
	if (use_backlight) {
		BACKLIGHT = backlight_color;
	}
}
