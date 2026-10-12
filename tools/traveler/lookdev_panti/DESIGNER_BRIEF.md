# 盘橐旅人 · 光影设计线共用说明（导演探针，2026-09-23）

目标（Carlos 原话方向）：像长安日暮那一轮一样，给盘橐加「反光」「轮廓光」「地面（雪地）细节」，整体再精修。
盘橐有两个已批准的时段：清晨 morning、深夜 midnight，点篝火（或按 1/2）用 8 秒平滑过渡。两个时段都要做，过渡中间帧也要好看。

## 不可改 / 不可碰
- 机位、FOV、景深（camera 及其 attributes）一律不动。构图不动，不加新物体（灯、shader、粒子质感可以加）。
- Codex 的文件零写入：scripts/**、shaders/**、scenes/**、data/**、assets/** 只读。
- 共享探针文件只读：tools/traveler/lookdev_panti/{panti_lookdev.py, panti_overlay.gd, panti_period_watcher.gd, lookdev_viewer.gd, panti_probe.tscn}。
- 也不要碰：data/rulesets/**、scripts/ui/**、tests/、project.godot、experiments/**、art-src/**、generated/**、tools/lowpoly/**、docs/design/**。
- 不要 git commit / push。不要读 ~/.config/silkroad/ 下任何文件。不要跑 tools/traveler/probe_instance_origins.gd。
- 只允许新建：tools/traveler/lookdev_panti/ 下以你的前缀开头的文件（a_* / b_* / c_*，含 variants/<前缀>*.json），以及渲染输出（自动写到 docs/reports/traveler-panti-light-20260923/）。

## 怎么渲
    python3 tools/traveler/lookdev_panti/panti_lookdev.py --slot=<你的槽位> --no-clone --periods=morning,midnight,blend50 <variant> [<variant2> ...]
- 每个 variant 每个时段一张 1920×1080：docs/reports/traveler-panti-light-20260923/<variant>_<period>.png（+ .json 带 p50/p95 帧时间、.log）。blend50 = 过渡权重 0.5 的中间帧。
- 一次约 8 秒/张。打印行末 errs=N 必须为 0；有错看 .log。GDScript 解析错误会让渲染挂到 240 秒超时——所有变量写显式类型。
- 基线：variants/p0_baseline.json（`{}`），图已在 p0_baseline_{morning,midnight,blend50}.png。
- 看图用 Read 打开 PNG；量像素用：`~/.local/bin/uv run --with pillow --with numpy python -c "..."`（系统 python 没有 PIL）。
- 盘点：inventory_morning.json / inventory_midnight.json 列了场景里所有几何体、材质、灯、环境参数。

## variant JSON 结构（tools/traveler/lookdev_panti/variants/<名>.json）
    {"base": "另一个variant(可选，一层继承；同名顶层节整节覆盖)",
     "static": {"extra_scripts": [{"script": "res://tools/traveler/lookdev_panti/<你的前缀>_xxx.gd", "cfg": {...}}],
                "day_sky": {ProceduralSkyMaterial 属性}},
     "morning":  {"sun": {...}, "env": {...}, "lights": {...}, "shaders": {...}, "materials": {...}},
     "midnight": {同上}}
- extra 脚本：`extends RefCounted`，实现 `func build(host: Node3D, cfg: Dictionary) -> Dictionary`（返回值进日志）。在 PANTI_READY 之前、watcher 配置之前执行一次。
- watcher 每帧按过渡权重 w（0=清晨→1=深夜）把 morning/midnight 两节的数值插值后写进场景，所以点篝火切换时也会平滑混合：
  - "sun": DirectionalLight3D 属性（light_color / light_energy / shadow_* …），外加 "sunel"/"sunaz"（度）。注意过渡进行中 Codex 的过渡代码也会写太阳/环境，watcher 排在它之后覆盖。
  - "env": Environment 属性。
  - "lights": {"节点名": {light_energy, light_color, omni_range …}}，按名字 find_child；你自己 extra 脚本里建的灯要起唯一的名字，并在两个时段都写数值（写 0 就是关）。
  - "shaders": {"文件名.gdshader": {uniform: 值}}：场景里 shader.resource_path 文件名等于它的所有 ShaderMaterial（含 next_pass 链、MultiMesh 材质）都改。所以 shader 必须从 .gdshader 文件 load，不能 Shader.new() 写代码。
  - "materials": {"节点名通配": {StandardMaterial3D 属性}}：给这些节点换一份当前材质的副本再改。
  - 只在一个时段写了的键，另一个时段取场景原值。颜色写 [r,g,b] 或 [r,g,b,a]。
- 动画时间：优先用场景的 weather 时钟 `host.weather.anim_t`（按空格暂停时会停），可以在 extra 脚本里加一个小 Node 每帧把它写进你的 shader 的 anim_t uniform。

## 场景事实（盘点结果）
- 渲染器 Forward+；SSAO、SSIL 开；SSR 关；tonemap ACES(4)；glow 开。
- 雪地 PantiWorld/SnowGround：material_override 是 StandardMaterial3D，纯色 #dbe8f7，roughness 1，specular 关，无纹理，不投影；网格是平面着色的低多边形起伏（约 151×156 u）。
- 树 SnowCedars_G/L/M/F（MultiMesh，共 54 棵）：ShaderMaterial = shaders/traveler/panti/panti_tree_wind.gdshader（world_vertex_coords、cull_disabled、diffuse_burley、specular_disabled，有风动 vertex()）。要改树的着色，把该 shader 复制成你自己的文件，改完后把材质的 .shader 换成你的（保留原 uniform 值），vertex() 风动代码必须原样保留。
- 岩石 SnowRocks_*（MultiMesh，StandardMaterial3D 带贴图）。营地 CampRoot/Tent、Stump、Firepit、Banner（StandardMaterial3D 带贴图），Lantern（camp_lantern.gdshader），篝火火焰 CampFireFlames（panti_camp_fire.gdshader）+ 火星粒子。
- 城堡 PantiWorld/PantiFortress：StandardMaterial3D 带贴图。深夜时 PantiCastleLights 会把 castle.material_override 换成带窗户自发光的 lit_material，清晨换回 null（用表面原材质）。要给城堡加 next_pass，两个材质都要挂：`host.castle.mesh.surface_get_material(0)` / `get_active_material(0)` 和 `host.castle_lighting.lit_material`。
- 人物 PantiSeatedBody（StandardMaterial3D 带贴图）+ 描边网格 PantiSeatedOutline。人物网格在渲染层 1<<19 上；light_cull_mask = 1<<19 的灯只照人物。
- 灯：Daylight（DirectionalLight3D，带阴影）；CampFireWarmLight（Omni，火光，Codex 的火焰动画每帧写它的能量）；LanternWarmth；PantiCastleLights/{gate-interior,left-market,front-market,right-market,upper-gallery}（深夜城下暖光池，随过渡权重淡入）；NightCharacterFill（深夜人物冷补光）。
- 清晨：太阳 el −18° az −58°，能量 1.8，色 (1,0.86,0.71)；环境光取天空。深夜：太阳当月光 el −32° az −28°，能量 0.55，色 (0.48,0.61,1.0)；环境光纯色 (0.37,0.47,0.76)×0.48；银河星空。
- 帧时间基线：清晨 p95≈6 ms，深夜 p95≈9–16 ms。

## Godot 着色要点（踩过的坑）
- 自定义 light() 会整个替换内置光照。兰伯特（带 wrap r）要自己写：`DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * max(0.0, (dot(NORMAL, LIGHT) + r) / ((1.0 + r) * (1.0 + r))) / PI;`（r=0 即普通兰伯特）。ATTENUATION 里含阴影；边缘光/高光写进 SPECULAR_LIGHT 并乘 ATTENUATION。
- light() 对每盏灯各跑一次（太阳 + 每个 Omni），所以雪面高光/闪粉写在 light() 里会自动对篝火、城下暖光也起作用——这正是"反光"要的。用 LIGHT_IS_DIRECTIONAL 区分太阳和点光。
- unshaded 的 shader 不认 EMISSION，要写 ALBEDO。next_pass 加色轮廓参考长安：tools/traveler/lookdev_changan/rim_edge_pass.gdshader（屏幕空间深度差金边）、rim_next_pass.gdshader、bounce_snow_sheen.gdshader、atlas_surface_dusk_merged.gdshader（带 light() 的完整示例）。
- 低多边形平面着色是这个场景的风格，法线细节要轻，不要把刻面抹平。
- 阴影 bias 调过头会出"等高线"条纹（长安踩过），改阴影参数要看近景雪地有没有条纹。

## 验收（每条线自检，数字写进汇报）
1. 三张图（morning / midnight / blend50）都 errs=0。
2. p95 帧时间 ≤ 33.3 ms（1920×1080）。
3. 画面整体不跑偏：每个时段全图平均亮度相对基线变化在 ±10% 以内（变化要集中在轮廓、反光、雪面细节这些局部）。
4. 已批准的气质不变：清晨明亮、蓝白为主、暖晨光；深夜深蓝、星空、篝火和城窗是暖色焦点。
5. 汇报：最终 variant 名、改了什么（每项一句话）、两个时段各自数值差异、上面 1–3 的实测数字、你自己最满意和最不满意的地方、以及新建的全部文件清单。
