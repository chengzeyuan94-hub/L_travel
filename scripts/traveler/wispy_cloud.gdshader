shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform vec4 cloud_color : source_color = vec4(1.0,0.95,0.86,1.0);
uniform vec4 shade_color : source_color = vec4(0.68,0.67,0.68,1.0);
uniform float bank_alpha = 1.0;
uniform float variant = 0.0;
uniform float opacity = 1.0;
uniform float shape = 0.0;
float hash21(vec2 p) {return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float noise2(vec2 p) {
 vec2 i=floor(p),f=fract(p); f=f*f*(3.0-2.0*f);
 return mix(mix(hash21(i),hash21(i+vec2(1,0)),f.x),mix(hash21(i+vec2(0,1)),hash21(i+vec2(1,1)),f.x),f.y);
}
float fbm(vec2 p) {float v=0.0,a=0.5;for(int i=0;i<4;i++){v+=a*noise2(p);p=p*2.03+vec2(17.3,9.2);a*=0.5;}return v;}
float puff(vec2 p,vec2 c,vec2 r) {return exp(-dot((p-c)/r,(p-c)/r)*2.0);}
void fragment() {
 vec2 p=UV*2.0-1.0;
 vec2 seed=vec2(variant*7.71,variant*3.19);
 float grain=fbm(vec2(p.x*7.0,p.y*5.0)+seed);
 float warp=(fbm(vec2(p.x*5.0,p.y*2.1)+seed+21.0)-0.5)*0.3;
 vec2 q=p+vec2(0.0,warp);
 q.y += sin(p.x*4.0+shape)*0.12*min(shape,1.0);
 q.x += sin(p.y*3.0+shape)*0.10*min(shape,1.0);
 float d=puff(q,vec2(-0.49,0.15),vec2(.48,.27));
 d+=puff(q,vec2(-.20,-.08),vec2(.35,.52))*.8;
 d+=puff(q,vec2(.12,-.13),vec2(.34,.55))*.85;
 d+=puff(q,vec2(.41,.10),vec2(.39,.32))*.72;
 d+=puff(q,vec2(.68,.22),vec2(.34,.15))*.42;
 float density=d*.67+(grain-.5)*.40;
 float alpha=smoothstep(.065,.38,density)*.82;
 alpha*=smoothstep(1.0,.78,abs(p.x))*smoothstep(1.0,.76,abs(p.y));
 float light=clamp(.74-p.y*.22+(grain-.5)*.28,0.0,1.0);
 ALBEDO=mix(shade_color.rgb,cloud_color.rgb,light);
 ALPHA=alpha*bank_alpha*opacity;
}
