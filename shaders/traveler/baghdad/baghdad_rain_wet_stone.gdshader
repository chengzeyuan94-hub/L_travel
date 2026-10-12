shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled;

uniform sampler2D base_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 base_tint : source_color = vec4(1.0);
uniform bool use_texture = true;
uniform bool use_vertex_color = true;
uniform bool vertex_color_srgb = false;
uniform vec3 uv_scale = vec3(1.0);
uniform vec3 uv_offset = vec3(0.0);
uniform float wetness : hint_range(0.0,1.0) = 0.92;
uniform bool gravel_surface = false;
varying vec3 world_position;

float hash(vec2 p) {
	p = fract(p * vec2(123.34,456.21));
	p += dot(p,p+45.32);
	return fract(p.x*p.y);
}
float noise2(vec2 p) {
	vec2 i=floor(p), f=fract(p);
	f=f*f*(3.0-2.0*f);
	return mix(mix(hash(i),hash(i+vec2(1.0,0.0)),f.x),mix(hash(i+vec2(0.0,1.0)),hash(i+vec2(1.0)),f.x),f.y);
}
vec3 srgb_to_linear(vec3 color) {
	return mix(color/12.92,pow((color+vec3(0.055))/1.055,vec3(2.4)),step(vec3(0.04045),color));
}
void vertex() {
	world_position=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
	UV=UV*uv_scale.xy+uv_offset.xy;
}
void fragment() {
	vec3 base=base_tint.rgb;
	if(use_texture) base*=texture(base_texture,UV).rgb;
	if(use_vertex_color) base*=vertex_color_srgb ? srgb_to_linear(COLOR.rgb) : COLOR.rgb;
	vec3 world_normal=normalize((INV_VIEW_MATRIX*vec4(NORMAL,0.0)).xyz);
	float upward=smoothstep(0.15,0.90,world_normal.y);
	float patch=smoothstep(0.20,0.78,noise2(world_position.xz*4.6+noise2(world_position.xz*0.9)));
	float damp=wetness*mix(0.62,1.0,patch);
	float film=damp*upward;
	// Broad irregular wet patches retain the photographed stone cracks and facets.
	ALBEDO=base*mix(1.0,0.60,damp);
	ROUGHNESS=mix(0.66,gravel_surface ? 0.36 : 0.20,film);
	SPECULAR=mix(0.27,0.53,damp);
	METALLIC=0.0;
	CLEARCOAT=film*(gravel_surface ? 0.15 : 0.34);
	CLEARCOAT_ROUGHNESS=0.18;
}
