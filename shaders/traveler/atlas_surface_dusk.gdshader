shader_type spatial;
// 长安旅人 · 日暮版地表着色器（TASK-CHANGAN-DUSK-001，2026-09-24 转正）。
// 来源：探针 tools/traveler/lookdev_changan/atlas_surface_dusk_merged.gdshader（Carlos 认可的 k_merge_c），只保留 k_merge_c 用到的部分：
//   太阳单独 wrap、暗部反光（地面暖 / 天光冷 / 灯下暖）、琉璃瓦与金饰高光、地面细节 v2（秋天色斑 / 土块 / 颗粒 / 碎叶斑）。
//   k_merge_c 里为 0 的探针口子（着色器内菲涅尔轮廓光 rim_*、地面细节 v1 ground_detail / streak）没有搬过来，结果不变。
//
// 怎么用：scripts/traveler/changan_dusk/changan_dusk_layers.gd 只在长安日暮（dusk_mix > 0）时把长安的 atlas_surface 材质换到这个着色器，
// 回到白天（dusk_mix = 0）再换回 shaders/traveler/atlas_surface.gdshader。uniform 与 atlas_surface 完全兼容，换着色器时材质参数原样保留。
// 为什么不直接改 atlas_surface.gdshader：太阳单独 wrap 需要自定义 light()，而一旦定义 light()，Godot 就不再计算内置的 GGX 高光
// （atlas_surface 的 SPECULAR 0.18）和光源角尺寸项，白天、商旅模式、Atlas 全图会整体变（探针 k1_parity：约 9% 像素差 > 2/255）。
// 换着色器可以保证白天与其他场景用的仍是原着色器，逐像素不变。
//
// dusk_mix（0..1）随 traveler_lookdev.gd 的 apply_period_mix 淡入淡出；日暮新增的每一项都乘它，dusk_mix = 1 时与探针逐项相同。
// 风动顶点代码与 atlas_surface.gdshader、dusk_rim_edge.gdshader 逐字相同：改一处必须三处一起改（金边 pass 靠它与主 pass 深度对齐）。
// 代码在 atlas_surface_dusk.gdshaderinc，按材质分三个变体只编进用得到的部分（结果逐像素相同，寄存器占用更少）：
//   本文件（所有 atlas 材质）/ atlas_surface_dusk_glaze.gdshader（寺庙的 Atlas_solid）/ atlas_surface_dusk_ground.gdshader（Atlas_terrain）。
render_mode cull_disabled;

#include "res://shaders/traveler/atlas_surface_dusk.gdshaderinc"
