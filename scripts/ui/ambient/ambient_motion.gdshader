shader_type spatial;
render_mode cull_disabled;
uniform float clock = 0.0;
uniform int kind = 0;

mat3 rx(float a) { float c=cos(a); float s=sin(a); return mat3(vec3(1,0,0),vec3(0,c,s),vec3(0,-s,c)); }
mat3 ry(float a) { float c=cos(a); float s=sin(a); return mat3(vec3(c,0,-s),vec3(0,1,0),vec3(s,0,c)); }
mat3 rz(float a) { float c=cos(a); float s=sin(a); return mat3(vec3(c,s,0),vec3(-s,c,0),vec3(0,0,1)); }

void vertex() {
	float p=INSTANCE_CUSTOM.x;
	float t=clock;
	if(kind==1) {
		if(UV.x>0.5) {
			float side=UV.x<1.5 ? -1.0 : 1.0;
			mat3 flap=rz(side*sin(t*1.8+p)*0.25);
			vec3 pivot=vec3(side*0.025,0.025,0.0);
			VERTEX=flap*(VERTEX-pivot)+pivot; NORMAL=flap*NORMAL;
		}
		float angle=t*0.33+p;
		mat3 turn=ry(3.14159-angle);
		VERTEX=turn*VERTEX+vec3(cos(angle)*0.22,sin(t*0.7+p)*0.04,sin(angle)*0.18);
		NORMAL=turn*NORMAL;
	} else if(kind==2) {
		if(UV.x>0.5) {
			mat3 nod=rx(0.08+sin(t*0.5+p)*0.12);
			vec3 pivot=vec3(0,0.20,-0.18);
			VERTEX=nod*(VERTEX-pivot)+pivot; NORMAL=nod*NORMAL;
		}
	} else if(kind==3) {
		if(UV.x>0.5) {
			mat3 tail=rx(sin(t*2.6+p)*0.28);
			VERTEX=tail*(VERTEX-vec3(0,0,0.36))+vec3(0,0,0.36); NORMAL=tail*NORMAL;
		}
		float a=t*0.2+p;
		// The head faces -Z; follow the derivative of the elliptical orbit.
		mat3 turn=ry(atan(0.35*sin(a),-0.25*cos(a)));
		VERTEX=turn*VERTEX+vec3(cos(a)*0.35,sin(t*0.6)*0.007,sin(a)*0.25); NORMAL=turn*NORMAL;
	} else if(kind==4) {
		if(UV.x>0.5) {
			mat3 sail=ry(sin(t*1.3+p)*0.17);
			VERTEX=sail*(VERTEX-vec3(0,0,-0.02))+vec3(0,0,-0.02); NORMAL=sail*NORMAL;
		}
		mat3 rock=rx(sin(t*0.71+p)*0.018)*rz(sin(t*0.58+p+1.0)*0.032);
		VERTEX=rock*VERTEX+vec3(0,sin(t*0.8+p)*0.017,0); NORMAL=rock*NORMAL;
	} else if(kind==5) {
		mat3 drift=ry(sin(t*0.2+p)*0.045);
		VERTEX=drift*VERTEX+vec3(0,sin(t*0.8+p)*0.012,0); NORMAL=drift*NORMAL;
	} else if(kind==6 && UV.x>0.5) {
		VERTEX.z+=sin(t*1.3+p+VERTEX.x*6.0)*0.045*clamp(UV.y/0.25,0.0,1.0);
	} else if(kind==7) {
		mat3 spin=ry(t*0.3); VERTEX=spin*VERTEX; NORMAL=spin*NORMAL;
	}
}

void fragment() { ALBEDO=COLOR.rgb; ROUGHNESS=0.95; SPECULAR=0.15; }
