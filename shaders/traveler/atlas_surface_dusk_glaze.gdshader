shader_type spatial;
// 长安旅人 · 日暮版地表着色器 · 琉璃瓦 / 金饰高光变体（只用于寺庙所在的 Atlas_solid 材质）。代码在 atlas_surface_dusk.gdshaderinc，说明见 atlas_surface_dusk.gdshader。
render_mode cull_disabled;

#define DUSK_GLAZE
#include "res://shaders/traveler/atlas_surface_dusk.gdshaderinc"
