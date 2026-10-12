shader_type spatial;
render_mode cull_disabled;
uniform float night = 0.0;
varying vec3 world_pos;
void vertex(){world_pos=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
void fragment(){
 float ripple=sin(world_pos.x*3.0+world_pos.z*4.1+TIME*.65)*sin(world_pos.z*3.7-world_pos.x*.8-TIME*.38);
 float shimmer=smoothstep(.90,.99,ripple)*.055;
 ALBEDO=COLOR.rgb*mix(vec3(1.0),vec3(.56,.67,.84),night)+shimmer;
 ROUGHNESS=.38; METALLIC=.10; SPECULAR=.32;
 NORMAL=normalize(NORMAL+vec3(ripple*.015,0.0,cos(world_pos.z*3.0+TIME)*.015));
}
