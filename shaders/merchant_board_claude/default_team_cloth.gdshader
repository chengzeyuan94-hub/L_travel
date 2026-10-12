shader_type spatial;
// Local trusted cloth recolor only; original three PBR textures remain shared.
uniform sampler2D base_tex : source_color, filter_linear_mipmap;
uniform sampler2D rm_tex : filter_linear_mipmap;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform vec3 team_color : source_color = vec3(0.804, 0.282, 0.227);
uniform float normal_scale = 1.0;
uniform float metallic_factor = 1.0;
uniform float roughness_factor = 1.0;
uniform bool debug_mask = false;
vec3 to_srgb(vec3 c) {
 return mix(c*12.92,1.055*pow(max(c,vec3(0.0)),vec3(1.0/2.4))-0.055,step(vec3(0.0031308),c));
}
void fragment() {
 vec3 base=texture(base_tex,UV).rgb;
 vec3 key=to_srgb(base);
 float rg=key.g/max(key.r,0.001);
 float rb=key.b/max(key.r,0.001);
 float bright=smoothstep(0.47,0.53,key.r);
 float cloth=bright*(1.0-smoothstep(0.43,0.51,rg))*(1.0-smoothstep(0.35,0.44,rb));
 float shade=clamp(max(base.r,max(base.g,base.b))/0.65,0.30,1.25);
 ALBEDO=mix(base,team_color*shade,cloth);
 if(debug_mask) ALBEDO=mix(base,vec3(0.55,0.02,0.95),cloth);
 vec3 packed=texture(rm_tex,UV).rgb;
 ROUGHNESS=packed.g*roughness_factor;
 METALLIC=packed.b*metallic_factor;
 NORMAL_MAP=texture(normal_tex,UV).rgb;
 NORMAL_MAP_DEPTH=normal_scale;
}
