# 第四幕「L叔在哪儿」· Godot 地块探针（导演探针基础设施）

这是导演探针，不是交付代码。它把 web 项目 Lshu_Travel_960 的随机地块搬进 Godot：web 的规划器和组装器离线烘焙，Godot 只负责组装和渲染。所有画面参数都放在 **一条全局管线** 里（光照预设、共享表面 shader、背景、机位规则、真人 L叔），每块地块都继承同一套。**任何只对某一块地块有意义的参数都算违规**：variant 里没有按地块 ID 写的键，只允许按全局规则写（光照档、地貌主题、素材 group、表面 role）。

## 0. 目录

| 路径 | 内容 | Godot 是否导入 |
|---|---|---|
| `web_src/` | web 源码的最小副本（`src/`、`studio/`、`journey/` 共 11 个 JS，`assets/manifest.json`，140 个原始 GLB，`config/`，12 张 `sample_NN.png` 和 `app_31/34.png` 预览，`tests/harness.cjs` 作参考）。**没有** `serve.py`、Jev 代码和任何密钥。副本逐字节不改。 | 否（`.gdignore`） |
| `bake/bake_recipes.cjs` | 离线烘焙：配方 → 布局 JSON + 程序化 GLB；`--assets` 转换 140 个素材 GLB | — |
| `baked/<ID>.json`、`baked/<ID>_proc.glb`、`baked/index.json` | 烘焙产物。运行时用 `GLTFDocument` 读取，**新烘焙的地块不需要重新 import** | 否（`.gdignore`） |
| `glb/<asset>.glb` + `.import` | 转换后的 140 个素材（sRGB 顶点色、按 role 拆分的 surface、转子子节点），`.import` 里关闭了 LOD 生成和网格压缩 | 是 |
| `shaders/lshu_surface.gdshader` | 共享表面 shader，所有不透明地块表面都用它 | 是 |
| `shaders/lshu_overlay.gdshader` | 共享半透明 shader（水面波纹） | 是 |
| `shaders/lshu_backdrop.gdshader`、`lshu_floor.gdshader` | 背景天空和接影子的台面 | 是 |
| `lshu_tile_viewer.gd/.tscn` | 查看器：组装 + 光照 + L叔 + 机位 + 截图 | 是 |
| `variants/*.json` | 外观变体。`baseline.json` 近似 web 画面；`example_hook.json` 演示 extra_scripts 接口 | — |
| `modules/example_rim_hook.gd` | extra_scripts 模块的最小示例 | 是 |
| `lshu_lookdev.py` | 批量截图（和 `lookdev_panti/panti_lookdev.py` 同一套路） | — |
| `make_sheets.py` | 拼图：contact sheet、四光照、和 web 预览并排对比 | — |

报告和截图输出在 `docs/reports/traveler-lshu-20260923/`（`docs/.gdignore` 已存在）。

## 1. 常用命令

```bash
cd /Users/chengzeyuan/Developer/SilkRoad
NODE=~/.local/bin/node; GODOT=/Applications/Godot.app/Contents/MacOS/Godot

# 1) 素材转换（只在 web 素材变了时跑），跑完必须 import 一次
$NODE tools/traveler/lookdev_lshu/bake/bake_recipes.cjs --assets
$GODOT --headless --path . --import

# 2) 烘焙配方：12 个样板（D01–D12，各用样板光照）；或者任意 Jxxx[:光照][=ID]
$NODE tools/traveler/lookdev_lshu/bake/bake_recipes.cjs --showcases
$NODE tools/traveler/lookdev_lshu/bake/bake_recipes.cjs J218:night J531:sunset J793:day
$NODE tools/traveler/lookdev_lshu/bake/bake_recipes.cjs --check J721        # 确定性检查（同一配方建两次比对）

# 3) 截图（缺省 D01–D12 各用样板光照，缺省冻结动作）
python3 tools/traveler/lookdev_lshu/lshu_lookdev.py --slot=0 baseline
python3 tools/traveler/lookdev_lshu/lshu_lookdev.py --slot=1 --recipes=D01,D05,D06 --lights=all baseline
python3 tools/traveler/lookdev_lshu/lshu_lookdev.py --slot=2 --recipes=D05 --live --tag=live my_variant

# 4) 拼图
UV="$HOME/.local/bin/uv run -q --with pillow python"
$UV tools/traveler/lookdev_lshu/make_sheets.py sheet  baseline              # <variant>_sheet.png
$UV tools/traveler/lookdev_lshu/make_sheets.py lights baseline --recipes=D01,D05,D06
$UV tools/traveler/lookdev_lshu/make_sheets.py web    baseline              # <variant>_vs_web.png

# 5) 给 Carlos 开实时窗口（L 切换光照，F 冻结/恢复动作）
$GODOT --path . res://tools/traveler/lookdev_lshu/lshu_tile_viewer.tscn -- --recipe=D05 --light=sunset --variant=baseline
```

`lshu_lookdev.py` 的参数：`--slot=N`、`--recipes=`、`--lights=showcase|all|day,night`、`--live`（不冻结动作）、`--tag=x`（文件名加后缀 `_x`）、`--timeout=`。其他 `--xxx` 原样转给查看器。输出文件名为 `<variant>_<recipe>_<light>[_tag].png/.json/.log`。错误计数包括 `SCRIPT ERROR`、`SHADER ERROR`、以 `ERROR:` 开头的行和 `TIMEOUT`，末行 `SUMMARY … errors=N`。

**窗口位（slot）**：窗口缩成 400×225，停在屏幕右下角往左、往上排：slot 0–3 是第一排，4–7 是第二排。并行跑时每条线各用一个 slot，窗口互不遮挡。macOS 上窗口被遮挡或最小化就会停止绘制。

## 2. 烘焙（`bake/bake_recipes.cjs`）

- 做法和 `web_src/tests/harness.cjs` 一样，在 Node 的 `vm` 里加载 web 的 10 个脚本，再调用 `StudioWorld.build(Journey480.recipe(id, light))`。
- 加载时对源码文本打 7 处补丁，每处都断言只命中 1 次；web_src 里的文件本身不改。
  - 给 `asset()` 放下的网格和主景节点打 `lshuAsset` 标记。这些输出为实例，不进程序化 GLB。
  - 给每个网格记录发出时所处的程序化阶段（ground / steps / water / structure / grass / flame）。
  - 跳过 `optimize()` 合批。
  - 标记人物替身。
  - 暴露 `anim`。
  - 记录草丛位置和营火位置。
- 确定性：J721 和 J027 各建两次，结果一致。单个配方烘焙约 0.4–0.7 s。
- 光照不影响几何（规划器只用种子），所以同一配方只烘一次，`light` 字段只是缺省光照。

**`<ID>.json`（schema `lshu.tile.v1`）主要字段**

| 字段 | 含义 |
|---|---|
| `light` | 缺省光照预设名 |
| `place` | `{id, name, theme(snow/desert/harbor/autumn), landform, asset, new_city, city}` |
| `layout` | 6 种布局之一 |
| `kit` | 4 组配景之一：look / camp / tea / encounter |
| `tile` | 8×8 设计米。`ground_y_range`；`skirt_bottom_y` -0.54；`plinth_bottom_y` -0.8275；`web_floor_y` -0.92 |
| `terrain` | `{N:52, step, origin:[-4,-4], heights[53][53]}`，和 web 的 `height()` 用同一对角线，查看器的 `terrain_height(x,z)` 与之逐点一致 |
| `paths[]` | `{id, kind, width, points:[[x,y,z]…]}` |
| `water` | web 的水位信息，另加 `proc_roles`、`landmark_water_regions` |
| `glow` | `{proc, landmark_glow_regions, web_emission:{day .13, sunset .5, night 1.7}}` |
| `hero`、`camp`、`pads`、`peaks`、`reservations` | web 规划器的原始区块，以后做散布时用来避让 |
| `instances[]` | `{asset_id, position, yaw, scale, role, group, anim(sway/boat/bob/null), motion, sway_amplitude?, phase?, regions?, runtime_parts?}` |
| `character` | `{position, ground_y, yaw, action(look/tea/bloom), pose(standing/seated/carrying), kit, support, seat_top, web_scale}` |
| `fires[]` | `{position, flame_center, scale, source(camp_kit 或素材 id)}` |
| `lamps[]` | 世界坐标点 |
| `effects[]` | 主景 effect_points（灯、火）换算后的世界坐标 |
| `smoke[]` | 木屋烟囱的烟团基点，**目前没有渲染** |
| `grass[]` | `{position, height, color}` |
| `proc` | `{file, roles:{role:{triangles, source_meshes, web_opacity, web_roughness}}}` |
| `stats` | 统计 |

**`<ID>_proc.glb`**：每个 role 一个节点 `proc_<role>`，材质名 `lshu_<role>`，节点 extras 里带 `lshu.role`。role 有：
- `ground`：连续地表，路面颜色已经按顶点混进去
- `skirt`：侧裙和底座
- `cliff`：峡谷岩柱
- `structure`：旧三场景的木屋、灯塔、码头、栈桥、石阶以外的程序化构件
- `steps`：石阶
- `glow`：窗、灯室
- `water`：水面
- `water_side`：水体侧面
- `foam`：岸边泡沫
- `ripple`：半透明波纹
- `grass`：草丛

顶点色 = web 材质色 × web 顶点色，都在 sRGB 空间相乘，和 web shader 的做法一致。

**`glb/<asset>.glb`（`--assets`）**
- 保留原始 extras，另加 `lshu.asset`，内容来自 manifest：id、group、role、size、motion、sockets、effect_points、runtime_parts、material_regions、ground_offset_m 等。
- 主网格按 `material_regions` 拆成多个 surface，材质名为 `lshu_matte / lshu_glow / lshu_water / lshu_metal`。
- `runtime_parts`（S03 风车）拆成子节点 `rotor_<name>`，节点原点就是 pivot，extras 里带 `lshu.runtime_part{axis, speed_rad_s}`。

**顶点色约定（解决白模和 8 位精度两个问题）**：两类 GLB 的 `COLOR_0` 存的都是 **sRGB 编码** 的值（不符合 glTF 标准，glTF 规定是线性值），asset extras 里注明了 `color_0: "srgb"`。Godot 用 8 位存顶点色，存 sRGB 能保住暗部；共享 shader 里 `vertex_color_srgb = true` 负责解码回线性。Godot 导入时生成的 StandardMaterial3D（默认不用顶点色，所以显示成白模）会被查看器整体替换，那套材质不参与渲染。

## 3. 查看器（`lshu_tile_viewer.gd`）

参数（写在 `--` 之后）：
- `--recipe=<ID>`
- `--light=<morning|day|sunset|night>`，缺省用地块的烘焙光照
- `--variant=<name>`，缺省 baseline
- `--capture=<png>`：预热 120 帧，记录 180 帧帧耗（p50/p95/max），读 draw call，存 PNG 和同名 JSON 后退出
- `--park=<slot>`
- `--motion-freeze`：把全部动作定在 `motion.freeze_time_s`

截图流程借用 `tools/traveler/capture_traveler.gd`：1920×1080 的 SubViewport，MSAA 4×。

**组装顺序**：
1. 创建相机（harness 在实例化后立刻取相机，所以相机必须在任何 await 之前建好）
2. 高度场纹理
3. 环境
4. 太阳和补光
5. 程序化 GLB
6. 素材实例
7. 火和灯
8. L叔
9. 台面
10. 包围盒和机位
11. 按光照应用参数
12. extra_scripts
13. 动作初始化
14. 截图

**截图 JSON（schema `lshu.capture.v1`）字段**：
- 渲染统计：`draw_calls`（全局）、`viewport_draw_calls`、`shadow_draw_calls`、`rendered_primitives`
- `frame_ms`：`{p50, p95, max, samples[180]}`
- `camera`：机位规则的求解结果
- `character`：pose、人物像素高 `projection.height_px`，以及坐姿或捧物模块自带的 evidence
- `backdrop`：目标色、实测角点色、误差
- `roles`、`instances`
- `extra_scripts`：各模块的返回值；`extra`：模块用 `add_report` 写入的内容
- `config`：本次生效的完整配置

### 3.1 姿势映射（L叔用的是其他幕里的真人模型）

| web 动作（配景） | Godot 姿势 | 复用的资源 |
|---|---|---|
| `look`（轻装远望；扎营歇脚时站在帐篷旁；拾花待发在非沙漠地块） | standing，`idle` 循环 | `scenes/traveler/action2_character.tscn` 加 `scripts/traveler/character_style.gd`（toon 着色 + 描边壳） |
| `tea`（坐下喝茶，坐具 C05/C07） | seated，`seated_idle` 循环 | `assets/traveler/panti/camp/character/sitting-animated.glb`、`scripts/traveler/panti/panti_seated_actor.gd`、`panti_seated_style.gd`。臀部锚点对到 `character.seat_top`，锚点修正误差约 0.0013 |
| `bloom`（拾花待发，沙漠或花地） | carrying，捧土豆 | `scripts/traveler/baghdad/baghdad_carrying_pose.gd`（`carrying_animated.glb` + 手掌跟随的土豆束）。查看器提供 `character`、`character_model`、`character_body`、`character_geometry`、`stage_point()` 供它使用；`turn_right_degrees = 0`；土豆束按 身高 / 0.6375（巴格达 L叔身高）缩放 |

- 朝向直接用 web 的 yaw。web 相机在 yaw 0.70 方向，所以 L叔大多面向镜头。
- 身高由 `character.height_m` 控制，缺省 1.15 m，和 web 替身相当，在 1080p 画面里约 93–128 px。
- 映射表可以在 variant 的 `character.pose_map` 里改。

### 3.2 机位规则（所有地块共用）

- yaw、pitch、fov 和 16:9 宽高比固定，缺省 40.1°、37.8°、22°，对应 web 相机的 yaw 0.70、pitch 0.66 rad。
- 取整块地块的包围盒：底座 8×8、地表、程序化构件、全部实例和 L叔。解出相机目标点和距离，让包围盒在 16:9 画面里居中，四周各留 `margin`。
- 支持 `projection: "orthographic"`。
- 太阳阴影范围也按规则计算：`max_distance = 相机距离 + 包围盒半径 + shadow_extra_distance`；`split_1: "auto"` 让第一级阴影刚好覆盖地块，第二级延伸到台面。

### 3.3 背景与台面

- 背景是屏幕空间的平涂渐变，和 web 一样只是一块纯色。颜色先按 Godot 的 ACES 曲线求逆，保证显示出来的就是 web 色板：实测误差白天 0/255，夜晚 4/255。
- 天空的辐射和辐照度通道单独输出一个半球渐变（`ambient_top/horizon/bottom`），作为环境光和水面反射。
- 台面位于 y = -0.92，放在独立的渲染层（`FLOOR_LAYER`）上，只有太阳照得到它。它不受环境光影响。受光处的颜色和背景完全一致，阴影处乘以 `shadow_value`（缺省 0.72，和 web 相同），用来复现 web 预览里投在背景上的影子。
- 注意：不能改用 `shadow_to_opacity`。那种模式下不带阴影的补光会把透明度抹成 0，影子就几乎看不见了。

## 4. Variant 格式（`variants/<name>.json`）

```jsonc
{
  "base": "baseline",              // 继承。字典递归合并；数组和标量整体替换
  "description": "…",
  "common": { <section>: {…} },    // 四档光照共用
  "lights": { "morning": {…}, "day": {…}, "sunset": {…}, "night": {…} },  // 每档光照覆盖的部分
  "extra_scripts": [ {"script": "res://…gd", "cfg": {…}, "lights": ["night"]?} ],
  "extra_scripts_replace": false   // 缺省把父级模块和本级模块拼接；true 则只用本级
}
```

**生效配置 = merge(common, lights[当前光照])**，模块通过 `host.cfg` 读取。颜色一律写 sRGB，可以是 `"#rrggbb"` 或 `[r,g,b]`（0–1）。例外是 shader 里没有 `source_color` 的 vec3 uniform，按原值传入。

| section | 键（baseline 的值） |
|---|---|
| `camera` | `projection`(perspective) `fov_deg`(22) `yaw_deg`(40.1) `pitch_deg`(37.8) `margin`(.05) `aspect` `target_offset` `near/far` `focus_on_character` `dof{far_enabled,far_offset,far_transition,near_enabled,near_offset,near_transition,amount}`（对焦距离取包围盒中心，也可改成对焦到 L叔） |
| `sun` | `position`（从原点指向光源的向量，web 的 sunPos） `color` `energy` `indirect_energy` `angular_distance_deg` `shadow` `shadow_mode`(parallel_2/parallel_4/orthogonal) `shadow_bias` `shadow_normal_bias` `shadow_blur` `shadow_opacity` `shadow_extra_distance` `shadow_split_1`(auto) `shadow_fade_start` `shadow_blend_splits` |
| `fill` | `enabled` `direction`(6,4,-6) `color` `energy` `shadow` `specular`，对应 web 的补光 |
| `env` | `tonemap`(aces/agx/filmic/reinhard/linear) `exposure` `white`(6) `ambient_source`(sky/color) `ambient_energy` `ambient_sky_contribution` `ambient_color` `ssao{enabled,radius,intensity,power,detail,horizon,sharpness,light_affect,ao_channel_affect}` `ssil{enabled,radius,intensity}` `glow{enabled,intensity,strength,bloom,hdr_threshold,hdr_scale,blend_mode,levels[7]}` `fog{enabled,color,density,sky_affect,height,height_density}` `adjust{enabled,brightness,contrast,saturation}` |
| `sky` | `backdrop` `theme_backdrop{desert,snow,harbor,autumn}`（按主题覆盖；baseline 只在 day 里用，和 web 一致） `top_mult/bottom_mult`（上下渐变） `vignette` `glow_amount` `compensate_tonemap` `ambient_top/horizon/bottom` `ambient_energy` |
| `floor` | `enabled` `y` `size` `shadow_value` `shadow_tint` |
| `surface` | 见 §5 |
| `fires` | `enabled` `flame` `flame_emission` `light_color` `light_energy` `light_range` `light_attenuation` `light_lift` `flicker` `shadow` |
| `lamps` | `enabled` `light_color` `light_energy` `light_range` `light_attenuation` `shadow` |
| `character` | `height_m`(1.15) `yaw_offset_deg` `offset` `outline_multiplier` `seated_outline_multiplier` `pose_map` `standing_animation` `idle_offset_s` `seat_offset` `carrying_turn_deg` `carrying_bundle_scale` |
| `motion` | `wind_strength`(.015) `sway_scale` `boat_bob` `rotor` `freeze_time_s`(2.5) |
| `scatter` | 保留给散布模块，查看器本身不读，模块自己从 `host.cfg.scatter` 取 |

## 5. 共享表面材质与扩展

**每个 role 一个 ShaderMaterial，所有地块共用。**
- 程序化部件的 role 取自材质名 `lshu_<role>`。
- 素材 surface 的处理：`glow`、`water`、`metal` 保持原 role；`matte` 按 `surface.group_roles` 映射。baseline 的映射是 tree→`tree`、rock→`rock`、scenery 和 city_scenery→`landmark`、camp、prop 和 harbor→`prop`、vegetation→`vegetation`、terrain→`matte`。
- 所以当前的 role 全集是：ground、skirt、cliff、structure、steps、grass、glow、water、water_side、foam、ripple、matte、tree、rock、landmark、prop、vegetation、metal。

**uniform 取值** = `surface.uniforms`（公共部分）⊕ `surface.roles.<role>`（按 role 覆盖），两处都可以放进 `lights.<光照>.surface` 按光照改写。每次切换光照都会重新绑定一遍。

`lshu_surface.gdshader` 的 uniform：

| 分组 | uniform |
|---|---|
| 颜色 | `vertex_color_srgb` `albedo_tint` `albedo_gain` `saturation` |
| 响应 | `roughness` `metallic` `specular_amount` `emission_strength`（glow 用，baseline 按光照为 .13 / .13 / .5 / 1.7） `emission_tint` |
| 细节（素材没有 UV，都在世界空间计算） | `noise_amount` `noise_scale` `facet_jitter` `top_tint_amount` `top_tint` |
| 边缘光 | `rim_strength` `rim_power` `rim_color` |
| 贴地 AO | `contact_ao` `contact_ao_height` `ao_light_affect`。查看器自动绑定 `height_tex`（53×53 高度纹理）、`height_rect` 和 `height_grid_n`，所以任何物体都能算出自己离地多高 |
| 水 | `water_mode` `water_sky` `water_fresnel` `water_ripple` |
| 风 | `wind_strength`（从 `motion.wind_strength` 注入） `anim_time`（查看器每帧写入，冻结时不变），以及实例 uniform `sway` / `sway_phase`（anim=sway 的树由查看器设置） |

baseline 里细节和边缘光类 uniform 全部是 0，也就是 web 原貌，留给各条外观线去打开。

**怎么扩展（不需要改本目录的文件）**：
1. **只调参数**：新建 variant，`"base": "baseline"`，写需要改的 `surface.uniforms` 或 `surface.roles.X`。
2. **换 shader**：把 `lshu_surface.gdshader` 复制到自己的前缀文件里，在 variant 里设 `surface.shader`（全部 role）或 `surface.roles.<role>.shader`（单个 role）。尽量保留原有 uniform 名，这样 baseline 的参数还能用。写了查看器不认识的 role uniform 会打 `push_warning`，不算错误。
3. **半透明**：把 role 放进 `surface.overlay_roles`，它就改用 `surface.overlay_shader`。
4. **新 role**：改 `surface.group_roles`，例如把 tree 拆成 `conifer`，再在 `roles` 里给出参数。

## 6. extra_scripts 接口（模块契约）

```gdscript
extends RefCounted   # 也可以 extends Node：查看器会把 Node 加为自己的子节点
func build(host: Node3D, cfg: Dictionary) -> Variant:   # 返回值会记进截图 JSON 的 extra_scripts
```

- **调用时机**：地块、L叔、光照、机位都已就绪，第一次按光照应用参数也已完成，截图预热还没开始。`lights: [...]` 可以限定模块只在某几档光照下加载。
- **生命周期**：查看器会持有模块对象，RefCounted 不会被提前释放。
- **host 的方法**：
  - `register_tick(cb)`：每帧回调 `cb(t, delta)`，`--motion-freeze` 时 t 固定不变
  - `register_light_callback(cb)`：每次应用光照后回调 `cb(light_name)`。查看器会先按 cfg 重新绑定所有 role uniform，所以模块改过的 uniform 要在这里重新设一遍
  - `set_role_uniform(role, name, value)`
  - `role_material(role)`
  - `terrain_height(x, z)`
  - `set_light(name)`
  - `add_report(key, value)`：写进截图 JSON 的 `extra`
  - `projected_bounds(mesh, geometry)`
  - `stage_point(v)`：恒等变换，给从巴格达复制过来的模块用
- **host 的属性**：
  - 数据：`tile`（烘焙 JSON）、`cfg`、`variant`、`light_name`、`variant_name`、`recipe_id`
  - 节点：`world`、`tile_root`、`proc_root`、`instances_root`、`fx_root`
  - 相机与环境：`camera`、`camera_attributes`、`camera_fit`、`sun`、`fill`、`environment`、`world_env`、`sky_material`、`floor_node`
  - 材质与几何：`materials`、`proc_nodes{role: MeshInstance3D}`、`instance_nodes[{node, data, meshes}]`、`height_texture`、`tile_bounds`
  - 动态效果：`fire_lights`、`lamp_lights`、`flames`、`rotors`、`bobbers`、`sway_nodes`
  - L叔：`character`、`character_model`、`character_body`、`character_pose`、`character_height_m`、`seated_actor`、`carrying_pose`
  - 时间：`anim_t`、`motion_frozen`
- 示例：`modules/example_rim_hook.gd` + `variants/example_hook.json`。它按光照给 landmark、tree、rock、prop 设边缘光，已实测 0 错误。
- **从盘橐或巴格达复制脚本时，必须去掉或改名 `class_name`**，否则会和原脚本冲突（盘橐篝火曾因此加载失败）。

## 7. baseline 实测（Mac Studio，1920×1080，MSAA 4×，冻结动作）

- 12 个样板加 3 块 × 4 档光照，再加 6 个非样板配方（J218 夜、J531 夕照、J891 日、J076 晨、J467 夜、J793 日），总计 **errors = 0**。
- p50 为 2–5 ms。p95 通常在 3–8 ms；机器上同时有别的 Godot 在渲染时，180 帧里会有 10–27 帧卡到约 20 ms，此时 p95 约 19–21 ms，仍低于 33.3 ms。
- 全局 draw call 24–57（Godot 会把同网格同材质的实例自动合并）。
- 背景色误差：白天、晨光、夕照为 0/255，夜晚为 4/255。

## 8. 已知缺口（留给后续外观线或 Codex）

1. **烟**：`smoke[]` 只记录了位置，没有渲染（web 的 D01 有烟囱烟）。
2. **水**：只有不透明的基础水面，靠菲涅尔和法线涟漪；没有深浅色、透明度和泡沫动画。主景自带的水区域也走同一个 role。夜里强高光已经压低（specular .04）。
3. **火**：用 web 同款的三个发光二十面体，加一个闪烁的 OmniLight；没有接入盘橐或巴格达的篝火模块（复制时要处理 `class_name`）。
4. **自发光**：glow 只按光照调强度。窗户本身不发光，但 web 里的灯位（`lamps[]`）已经放了 OmniLight。
5. **风摆**：树用 shader 实例 uniform，幅度很小（web 960 路径本来也几乎不动）；草丛在程序化 GLB 里，还不能摆动；没有叶片级的摆动。
6. **转子和船**：S03 风车转子、船只上下起伏已经做了。
7. **散布**：没有自动散布，`scatter` section 是空的。web 的草丛稀疏，留给散布模块，可以用 `grass[]`、`reservations` 和 `terrain_height()`。
8. **细节与贴地 AO**：shader 已支持，baseline 没打开。web 的接触阴影贴片已经去掉，改由真实阴影和 SSAO 承担。
9. **全局光照**：没有 LightmapGI 和 SDFGI（素材没有 UV2），SSIL 关闭。
10. **构图**：16:9 固定机位下，地块两侧会空出大片背景色（r07 的担心依然成立）。怎么处理背景是产品决定。
11. **捧物姿势**：web 的「拾花」换成了巴格达的捧土豆动作，土豆束没有加花。
12. **坐姿**：盘橐的坐姿动画原本配矮树桩，放到 web 的坐具上（坐面高约 0.4 m）目测正常，但没有做脚底贴地检查。
13. **960 全量**：960 份全部烘焙约 11 分钟，程序化 GLB 每份 0.65–1.2 MB，全量约 0.6–1 GB，不建议入库，按需烘焙即可。
14. **`--import` 的副作用**：它会给仓库里其他缺 `.uid` 的脚本补生成 `.uid` 文件（Godot 4.4+ 的行为）。
