shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 sand_color : source_color = vec4(0.73,0.63,0.48,1.0);
uniform float wetness : hint_range(0.0,1.0) = 0.92;
uniform float puddle_amount : hint_range(0.0,1.0) = 0.72;
uniform float ripple_strength : hint_range(0.0,0.5) = 0.10;
uniform float rain_time = 0.0;
uniform vec2 traveler_xz = vec2(0.47,2.7937353);
uniform vec2 fire_xz = vec2(-0.43,3.50);
varying vec3 world_position;

float hash(vec2 p) {
	p=fract(p*vec2(123.34,456.21));
	p+=dot(p,p+45.32);
	return fract(p.x*p.y);
}
float noise2(vec2 p) {
	vec2 i=floor(p),f=fract(p);
	f=f*f*(3.0-2.0*f);
	return mix(mix(hash(i),hash(i+vec2(1.0,0.0)),f.x),mix(hash(i+vec2(0.0,1.0)),hash(i+vec2(1.0)),f.x),f.y);
}
float ripple(vec2 p) {
	vec2 q=p*2.8,cell=floor(q);
	vec2 center=vec2(hash(cell+vec2(8.4,1.0)),hash(cell+vec2(4.2,5.6)))*0.42+0.29;
	float age=fract(rain_time*0.90+hash(cell));
	float radius=age*0.48;
	float d=length(fract(q)-center);
	float ring=exp(-pow((d-radius)/0.025,2.0));
	return ring*sin(age*3.14159)*(1.0-age);
}
void vertex() {
	world_position=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
}
void fragment() {
	vec2 p=world_position.xz;
	float front=1.0-smoothstep(7.5,12.5,world_position.z);
	float patches=noise2(p*1.35+vec2(noise2(p*3.1),noise2(p*2.2+vec2(8.2)))*0.5);
	float pools=smoothstep(0.49,0.70,patches)*puddle_amount*front;
	float avoid=smoothstep(0.25,0.43,length(p-traveler_xz))*smoothstep(0.34,0.54,length(p-fire_xz));
	pools*=avoid;
	float fine=noise2(p*145.0);
	float worn=noise2(p*12.0);
	vec3 dry=sand_color.rgb*(0.90+worn*0.10)*(0.90+fine*0.15);
	vec3 damp=dry*mix(1.0,0.55,wetness*front);
	ALBEDO=mix(damp,damp*vec3(0.49,0.58,0.65),pools);
	ROUGHNESS=mix(mix(0.94,0.67,wetness*front),0.13,pools);
	SPECULAR=mix(0.23,0.62,pools);
	METALLIC=0.0;
	CLEARCOAT=pools*0.55;
	CLEARCOAT_ROUGHNESS=0.10;
	float r=ripple(p);
	float dx=(ripple(p+vec2(0.0025,0.0))-r)*pools*ripple_strength;
	float dz=(ripple(p+vec2(0.0,0.0025))-r)*pools*ripple_strength;
	// Surface-only moving ripple normals: no glowing decal or floating puddle plane.
	vec3 tx=normalize((VIEW_MATRIX*vec4(1.0,0.0,0.0,0.0)).xyz);
	vec3 tz=normalize((VIEW_MATRIX*vec4(0.0,0.0,1.0,0.0)).xyz);
	NORMAL=normalize(NORMAL-(tx*dx+tz*dz)*8.0);
}
