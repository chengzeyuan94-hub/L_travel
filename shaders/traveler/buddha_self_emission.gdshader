shader_type spatial;
render_mode diffuse_lambert;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 base_color : source_color = vec4(1.0);
uniform vec4 glow_color : source_color = vec4(1.0);
uniform float glow_energy = 0.85;
uniform float glow_active = 0.0;
uniform float edge_feather = 0.004;
uniform float roughness = 0.94;
uniform vec4 profiles[12]; // local y, center x, half width, front-surface z cutoff
uniform bool debug_mask = false;
varying vec3 asset_position;
varying vec3 asset_normal;

void vertex() { asset_position = VERTEX; asset_normal = NORMAL; }

float statue_mask(vec3 p) {
    if (p.y < profiles[0].x || p.y > profiles[11].x) return 0.0;
    vec3 section = profiles[0].yzw;
    for (int i=0; i<11; i++) {
        if (p.y >= profiles[i].x && p.y <= profiles[i+1].x) {
            float t=(p.y-profiles[i].x)/(profiles[i+1].x-profiles[i].x);
            section=mix(profiles[i].yzw,profiles[i+1].yzw,t);
        }
    }
    float silhouette=1.0-smoothstep(section.y-edge_feather,section.y,abs(p.x-section.x));
    float front=smoothstep(section.z,section.z+edge_feather,p.z);
    float ends=smoothstep(profiles[0].x,profiles[0].x+edge_feather,p.y)
        *(1.0-smoothstep(profiles[11].x-edge_feather,profiles[11].x,p.y));
    return silhouette*front*ends;
}

void fragment() {
    vec3 stone=texture(albedo_texture,UV).rgb*base_color.rgb;
    float mask=statue_mask(asset_position);
    float relief=0.45+0.55*max(dot(normalize(asset_normal),normalize(vec3(-0.3,0.65,1.0))),0.0);
    ALBEDO=debug_mask ? vec3(0.0) : stone;
    EMISSION=debug_mask ? vec3(mask) : stone*glow_color.rgb*glow_energy*glow_active*mask*relief;
    ROUGHNESS=roughness;
    METALLIC=0.0;
    SPECULAR=0.0;
}
