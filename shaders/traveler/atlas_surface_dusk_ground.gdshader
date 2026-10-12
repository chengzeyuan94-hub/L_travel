shader_type spatial;
// 长安旅人 · 日暮版地表着色器 · 地面细节 v2 变体（只用于 Atlas_terrain 材质）。代码在 atlas_surface_dusk.gdshaderinc，说明见 atlas_surface_dusk.gdshader。
render_mode cull_disabled;

#define DUSK_GROUND
#include "res://shaders/traveler/atlas_surface_dusk.gdshaderinc"
