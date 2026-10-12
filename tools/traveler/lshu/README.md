# 第四幕「L叔在哪儿」· 正式版工具（P0）与运行方式

## 怎么运行第四幕（导演，integrate 2026-09-24）

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot

# 正常运行：真实时钟，真实存档（OS.get_data_dir()/ShanheLvren/lshu_where/），窗口在前台、失焦或最小化都是 30 帧（2026-09-27 Carlos：旅人模式像屏保一样开在别的程序旁边，失焦不降帧）
$GODOT --path . res://scenes/traveler/lshu_main.tscn

# 开发：60 倍速（8 分钟看完一天），用单独的调试存档（lshu_where_scaled/），打印导演的事件行，开 F1–F4 开发键
$GODOT --path . res://scenes/traveler/lshu_main.tscn -- --lshu-clock-scale=60 --lshu-dev

# 指定开始时刻和存档目录（测试用；--lshu-now 或倍速不为 1 时，没给 --lshu-save-dir 就用调试存档）
$GODOT --path . res://scenes/traveler/lshu_main.tscn -- --lshu-clock-scale=60 --lshu-now=1790204400 --lshu-save-dir=/tmp/lshu_try --lshu-dev
```

- **什么时候跑导演**：`lshu_main.tscn` 作为主场景打开、而且没给 `--tile / --light / --light-blend / --capture` 时，节点 `Director`（`scripts/traveler/lshu/lshu_director.gd`）接管：时钟挑地块和光照。给了这些参数（或者被 QA harness 装进 SubViewport）时，`Director` 节点被移除，就是原来的 P0 单块舞台，截图逐像素不变。`--lshu-director=on|off` 可强制。
- **参数**：`--lshu-clock-scale=N` 倍速（自动用调试存档）；`--lshu-save-dir=PATH` 存档目录；`--lshu-now=UNIX` 开场时刻（倍速或指定时刻时，时钟在启动期间停住，从画面出来那一刻开始走，所以开场就是这个时刻）；`--lshu-dev` 开发键和事件日志；`--lshu-fps-cap=off` 只给 QA 测帧耗（不限帧、关垂直同步，退出恢复）。
- **按键**：L 旅行本（界面）；点到他：鞠躬（坐着 / 捧物时点头），转向玩家后顺手拍一张。开发键只在 `--lshu-dev` 下有：双击画面任意处镜头凑近他 8 秒（2026-09-27 Carlos：玩家双击不推镜头），F1 光照在「跟时钟 → 晨 → 昼 → 昏 → 夜 → 跟时钟」之间切换，F2 冻结 / 解冻动作，F3 / F4 预览池里的下一块 / 上一块（他坐定在那里，直到循环下一次换地）。
- **导演做什么**（数值都在 `data/traveler/lshu/director.json`，都是起点）：
  - 每 2 秒 `LshuClock.resolve()`（倍速下按倍速缩短，最短 0.05 秒）；存档走 `LshuSave`：原子写、lock、第二个实例只读（照样显示，不写档、不拍明信片），第一个实例退出后下一次心跳（60 秒）接管。写档时机：子状态切换、每 5 分钟、明信片渲好 / 看过、鞠躬照、关窗和退出。
  - 事件按顺序播放，换地时队列暂停：他离开时（LEAVE / ROAD）在旁边隐藏着预载下一块（后台读盘 + 每帧最多 6 ms 分帧组装），并把换地那一帧要做的重活提前做掉（见下面“换地帧”）；路上旧地块留在屏上、空着，火在 3 分钟（逻辑时间）里降到余烬，夜里他的营灯光 2 秒淡掉后收起；路走完时把上一帧在 GPU 上拷一份盖在屏上（`lshu_screen_fade.gd`，约 0.1 ms，不读回），在它下面换上新地块、绑定动作（他隐藏），2.5 秒溶解过去（倍速下不超过 150 逻辑秒），然后他从路口走进来，地名出现。
  - 第一次启动、离线补算（包括程序开着但机器睡了 3 小时以上）、舞台漏掉一站：在遮罩下直接搭好当前状态（不补放动画）；还没出图的明信片先各自在自己的地块上、按拍摄那一刻的光照、他坐定的样子补拍，再出「你不在的时候」小卡（离开 ≥ 2 小时）。
  - 光照：每次 `resolve()` 的 `light` 交给舞台的连续插值。夜里：21:30 打盹、23:30 进帐篷（地块有帐篷时；火降到 45%）、06:30 出来；这一站会待到天黑时，到站就把营灯摆好（夜灯模块 `set_hold`）。
  - 明信片：`postcard` 事件后等他坐定（动作模块处于 kit 或打盹）再拍；超时（窗口不画）留在待渲里，窗口重新获得焦点或 20 秒后重试。鞠躬照是 `type: "snap"` 的记录（id `snap_<seed>_<站号>_<n>`，每站最多 1 张），直接进 `save.postcards`，不进 `pending_renders`，循环的路线和明信片不受影响；旅行本里同一站有明信片时缩略图用明信片。
  - 界面：`configure(cfg, places)`；每次 tick `apply_resolve()`（事件由导演在舞台真正播放时再交给界面，所以地名在溶解完才出现）；`postcard_read` → `mark_read` + 写档。
  - 帧率：场景级 `Engine.max_fps`，前台、失焦、最小化都是 30（2026-09-27 起不降帧，`fps_for()` 也不许低于 30），退出时恢复原值。
- **舞台接口（`lshu_main.gd`）**：`stage_tile(id, budget_ms)` 在旁边隐藏着组装、`commit_staged()` 一帧换上、`discard_staged()`；`load_tile()` 仍是两者连用，行为和原来一样。`show_staged_under_cover()`：遮罩刚盖上、换地前一帧把预载好的地块在遮罩下画一次（首次绘制不和换地挤在同一帧）。`set_fire_level(level, shape)` 转给 `lshu_life.gd`（1 = 定稿的火，完全不动）。夜灯新增 `set_presence_fade(f)`。

- **换地帧（repair_r2，verify_r2 第 1 项）**：`stage_tile()` 组装完以后还在隐藏的地块上把换地帧的活做掉（`lshu_main.gd` 的 `_plan`，每块不超过一帧的预算）：P1 把他临时摆到新地块的位置，抄下坐具贴合要读的数据（`lshu_character.gd` 的 `save_placement` / `place_built` / `fit_inputs` / `restore_placement`，同一帧里放回去，画面上看不到），贴合本身（`fit_compute`，纯数据）在工作线程上算；P2 再摆一次、套上贴合结果，算地块包围盒、用一台不当前的“计划相机”套镜头规则、`finish()`，记下夜灯规则看到的他（`lshu_night_lamp.gd` 的 `subject_of`），放回去；P3 在隐藏的地块下按这些决定并搭好营灯。换地帧只重新摆他（很便宜，结果完全一样）、套上计划好的贴合（前提：他站的位置和计划时逐位相同，否则当场算）、重跑便宜的包围盒 / 镜头 / `finish()`、在他、相机、夜灯参数都和计划时逐位相同的时候直接用计划好的营灯（否则当场搭），然后绑定、显示。`place()` 每次都把角色节点的缩放设回建模时的值，所以摆放不受之前的变换影响。地块组装时合并阴影读到的三角形顺便在工作线程上做成动作模块要的碰撞三角形（`lshu_tile_assembler.gd` 的 `faces_for`，与 `Mesh.get_faces()` 逐位相同），换地后的 `bind_tile()` 不再从 GPU 读回；动作模块的网格 / 站点 / 路线规划也按 `route.main_slice_ms` 分帧。
  - 等价性：`day_run.gd --plan-check` 在每次换地帧上按老办法再算一遍贴合和营灯，逐位比较（`plan_equals_swap_frame`）；`qa/lshu_faces_check.gd` 比较预先做好的碰撞三角形和 `Mesh.get_faces()`；定帧截图逐像素不变（`lshu_batch.py` 前后对比）。
  - 计时：`lshu_main.gd` 的 `work_log` / `take_frame_work()` 记录每一帧里的分段耗时（`build`、`plan:*`、`commit:*`、`snapshot`、`colliders`、`route_plan`、`resolve`、`light`、`save`……），`day_run.gd` 把它和那一帧的间隔、当帧编译的渲染管线数放在一起，每个换地 / 预载窗口打一行 `LSHU_DAY_SWITCH_WINDOW`，最后 `LSHU_DAY_SWITCH_WORST`，逐帧明细在 `<out>/switch_frames.json`；导演的 `staged` / `switch` 事件行带 `parts` / `commit_parts`。

### 导演的测试

```bash
tools/traveler/lshu/tests/run_director_tests.sh          # 无头规则测试 + 窗口冒烟（第 24 号窗口位）
tools/traveler/lshu/tests/run_day_run.sh                  # 600 倍速跑一整天（第 24 号窗口位），出 day_48.png
tools/traveler/lshu/tests/run_day_run.sh OUT SHEET --date=2026-10-06
```

- `tests/test_director.gd`（无头）：参数、存档目录选择、倍速下的 tick 与溶解时长、帧率策略、火的旺度、鞠躬照记录和循环一起跑 10 天（路线、循环明信片 id、待渲队列都和不拍时一样；旅行本缩略图优先明信片）。最后一行 `LSHU_DIRECTOR_TESTS passed=N failed=M`。
- `tests/director_smoke.gd`（窗口）：帧率跟焦点变、退出恢复；L 开关旅行本；F1、F3；开着程序时钟跳 5 小时 → 补算 + 补拍 + 小卡；退出（写档、放锁）后 6 小时再开 → 开场补算、补拍、小卡。最后一行 `LSHU_DIRECTOR_SMOKE checks=C failed=F`。
- `tests/day_run.gd` + `day_run_sheet.py`：全新存档、600 倍速、从 07:00 跑 24 小时，每 30 分钟截一帧（48 帧），中途点他一次（鞠躬照）、打开并收起一张明信片（已读写档）。导演不限帧（`--lshu-fps-cap=off`），帧耗和 P0 换地测试同一个定义。输出 `day_run_report.json`、`events.jsonl`、`frames/`、`save/`（含 `postcards/*.jpg`）和拼图。最后一行 `LSHU_DAY_RUN ... failed=F`，外加 `LSHU_DAY_RUN_SUMMARY`（严格日志判定）。夜里的检查 `night_lamp_rule` 按营灯规则判：夜里凡是画面上有他的帧，营灯亮着，或营灯记录的原因是地块自己的火 / 灯在 `near_radius_m`（1.5 米）内，才算过；实际放灯的帧数只报告不拦（取决于当天停在哪几站），默认日期和别的日期都应 0 失败。另输出每个换地 / 预载窗口的逐帧分段耗时（`LSHU_DAY_SWITCH_WINDOW`、`LSHU_DAY_SWITCH_WORST`、`switch_frames.json`，见上面“换地帧”）；加 `--plan-check` 多一项 `plan_equals_swap_frame`（QA 用，不作计时）。


派工单 `docs/design/shanhe-luren/lshu-where-act4-card.md`，方案 `lshu-where-act4-godot-plan.md`。探针 `tools/traveler/lookdev_lshu/` 只读，外观定稿是它的 `variants/m_final.json`，已展平成 `data/traveler/lshu/look.json`。

## 文件

| 位置 | 内容 |
|---|---|
| `web_src/`（.gdignore） | 网页源码逐字节副本（与探针 web_src 相同，无 serve.py、无密钥） |
| `bake/bake_recipes.cjs` | 离线烘焙：`--assets` 转 140 个素材；`--pool[=A,B]` 烘池内地块；`--check[=A,B]` 同配方建两次比字节 |
| `bake/lshu_post_import.gd` | 导入时给素材和地块的 structure/steps/cliff 算一次棱边数据（CUSTOM0） |
| `bake/precompute_tiles.gd` | 离线算地面信息和散布实例，追加到地块 JSON 的 `precompute` |
| `bake/run_bake.sh` | 整条链：烘焙 → `--import` → 预算；`--pool-file=` 先烘暂存的池清单，全部通过后才装成 `pool.json`；`--log-dir=` 留每步完整日志 |
| `bake/make_look.py` / `make_pool.py` | 生成 `look.json`（m_final 展平）/ `pool.json`（默认池 160 块 = 40 地点 × 4 配景，25 块验收地块保留原位；布局按 `pool_rule` 的种子全局规则分摊左 / 中 / 右三类；明信片字段 `city_id`、`sub`、`postcard_terrain` 按 `postcard_rule` 全局表生成） |
| `qa/lshu_batch.py` | 批量截图，严格错误判定（任何含 ERROR / WARNING 的行、非零退出码、capture_error） |
| `qa/lshu_pool_qa.py` | 池验收：每个地点按种子抽一块、一档光照，再随机抽 N 块四档光照，严格判定 + p95，出拼图 |
| `qa/lshu_pool_load_probe.gd` | `LshuPoolAdapter.load_places()` 在真实池上的耗时和字段覆盖（只报告） |
| `qa/lshu_sheets.py` | 拼图、和探针对比（`parity`）、四光照、全矩阵 |
| `qa/lshu_id_grep.py` | 编号 grep：代码、shader、look.json 里不许出现任何地块 / 配方 / 素材 / 地点编号 |
| `qa/lshu_determinism.py` | 确定性：烘两次逐字节、定帧截两次平均像素差 |
| `qa/lshu_switch_test.gd` | 连续换地 N 次，记录主线程每帧耗时 |
| `qa/lshu_faces_check.gd` | 按导演的方式（分帧）装入 N 块地块，预先做好的碰撞三角形（`faces_for`）必须与 `Mesh.get_faces()` 逐位相同；最后一行 `LSHU_FACES_CHECK ... mismatches=0` |
| `qa/lshu_qa_capture.gd` + `qa/lshu_findability.gd` | QA 截图，可加 `--findability`（L叔色差等，原探针预热期测量，已移出场景） |
| `qa/lshu_acts_snapshot.py` | 前三幕对照截图与逐像素比较 |
| `qa/lshu_seat_check.py` + `qa/lshu_seat_capture.gd` + `qa/lshu_seat_scan.gd` | 修复 1 验收：池内全部坐姿地块，按实际绘制的网格量脚底到脚下支撑的间隙（整段待机、分左右脚、是否嵌进坐具）；两只脚各自整段待机里的最大间隙都要 ≤ 0.03 米；`--seat-fit=off` 截修前；`--sheet=` 出前后特写拼图 |

## 命令（在仓库根目录）

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
UVPY="$HOME/.local/bin/uv run -q --with pillow --with numpy python"

# 烘焙（素材变了才加 --assets）
tools/traveler/lshu/bake/run_bake.sh

# 重新生成池（先暂存、烘好、再装上；地块 JSON 烘焙部分没变的不重写，预算保留）
python3 tools/traveler/lshu/bake/make_pool.py --out=OUT/pool_staged.json --report=OUT/pool_report.json
tools/traveler/lshu/bake/run_bake.sh --pool --pool-file=OUT/pool_staged.json --log-dir=OUT/bake_logs
python3 tools/traveler/lshu/bake/make_pool.py --check

# 池验收（40 地点各一张 + 随机 10 块 × 4 档光照）
$UVPY tools/traveler/lshu/qa/lshu_pool_qa.py --out=OUT/qa --slot=1 --sheet=OUT/pool_sheet.png

# 单块地块的舞台（P0 查看器，不跑循环；加 --lshu-dev 才有开发键：F1 换光照，F2 冻结，F3 / F4 换下一块 / 上一块）
$GODOT --path . res://scenes/traveler/lshu_main.tscn -- --tile=D05 --light=sunset --lshu-dev

# 单张截图（1920×1080，MSAA 4×）
$GODOT --path . --script res://tools/traveler/capture_traveler.gd -- --capture-scene=res://scenes/traveler/lshu_main.tscn \
  --tile=D01 --light=night --motion-freeze --park=1 --capture=$PWD/out/D01_night.png

# 验收
python3 tools/traveler/lshu/qa/lshu_batch.py --out=OUT --slot=1 --tiles=all --lights=all --modes=freeze,live
$GODOT --path . --script res://tools/traveler/lshu/qa/lshu_switch_test.gd -- --park=1 --switches=20 --out=$PWD/OUT/switch_test.json
python3 tools/traveler/lshu/qa/lshu_id_grep.py
python3 tools/traveler/lshu/qa/lshu_determinism.py bake
$UVPY tools/traveler/lshu/qa/lshu_determinism.py capture --out=OUT --tiles=D01,J315 --lights=night,day
$UVPY tools/traveler/lshu/qa/lshu_sheets.py parity OUT/port_parity.png OUT/matrix -
python3 tools/traveler/lshu/qa/lshu_summary.py OUT/matrix --json=OUT/matrix_summary.json
```

窗口位 `--park=N`：窗口缩成 400×225 停在屏幕右下角，N=0–3 第一排、4–7 第二排；并行渲染各用一个位，macOS 被挡住的窗口会停止绘制。

## 连续光照与夜里的营灯（integrate 2026-09-24）

- **连续光照**：`lshu_look.gd` 的 `set_light_blend(a, b, t)` / `set_light_state(时钟的 r.light)` 把两档预设逐项插值（太阳、补光、天空 / 背景、环境、雾、景深、各 role 的 shader 参数含窗灯自发光、火光、灯光、光晕、烟、台面、L叔的轮廓光）；`t = 0 / 1` 与 `set_light(a / b)` 完全一致。场景入口 `lshu_main.gd` 的 `set_light_state(r.light)` 只在光照变了时才重新应用；命令行 `--light-blend=a,b,t` 直接开一个过渡中的光照。`look.json` 里凡是某一档单独覆盖的键，`common` 都有显式值（`make_look.py` 的 `BLEND_FALLBACKS`，取值就是原来代码 / shader 的缺省值，四档画面不变），所以插值两端不会缺键。
- **夜里的营灯（决定 4 推荐默认）**：`scripts/traveler/lshu/lshu_night_lamp.gd`，数值在 `look.json common.night_lamp`，四种提灯在 `pool.json night_lamp.assets`。夜的权重 > 0 且他 1.5 米内没有火或灯时生效：他身边镜头一侧 75° 内有没点亮的提灯就给它点上，否则按全局规则在他身边摆一盏（镜头一侧的一圈候选点，避开地块边、路、水、素材、火、他的脚、保留区，地面要平，不挡他，也不被更靠近镜头的素材挡住；他站在栈桥上就摆在栈桥上）。光 = 一盏不投影的小暖光（能量 × 夜的权重）+ 同一位置只照他的一盏（脚下是沙地时按沙的比例减弱）。导演到站时调 `set_hold(stay_needs_lamp(到站, 离开, 编译后的时钟配置))`，灯就随他到站摆好、不会在黄昏凭空出现；他在路上时 `set_present(false)`。`--night-lamp=off` 关掉营灯（做前后对照）。
- **QA**：
  - `qa/lshu_light_sweep.gd` + `qa/lshu_light_sweep.py`：模拟 24 小时、每分钟一帧，分析每分钟亮度变化、和旧的硬切对比、过渡两端和改动前截图逐像素比较。
  - `qa/lshu_light_blend_check.gd`：属性级检查，每档预设走过一圈插值后回到 `t = 1` / `t = 0` 与直接设定逐项相等；每段插值首尾 1‰ 的变化占整段的比例。
  - `qa/lshu_night_lamp_qa.py`：地块夜里无灯 / 有灯各截一张，量 L叔色差（`qa/lshu_findability.gd`），出前后对照图。
  - `qa/lshu_night_lamp_tune.gd`：只在内存里改 `night_lamp` 数值，逐组量色差（调参用，不改 `look.json`）。
  - `qa/lshu_rim_ghost_check.gd`：他隐藏时原地不许留下边缘光轮廓（verify_r1 的“幽灵”）。和 day_run 一样的全新存档、600 倍速，停在“在路上 / 进帐篷 / 走进来之前或走出去之后（两个人物都透明）”各一次，整棵树暂停后比较“原样”和“所有边缘光强度设为 0”两帧，全帧不许有差（暂停后仍在收敛的像素按“原样 ↔ 恢复边缘光后”的差扣掉）；夜里他在画面上时作正对照（必须看得到边缘光），并把 `rim_fade` 临时改回 1 复现修复前的轮廓，证明探针不是瞎的。输出 `rim_ghost_report.json` 和每种时刻的裁切对照图。

```bash
python3 tools/traveler/lshu/qa/lshu_light_sweep.py run --out=OUT/sweep --slot=22 --tiles=D01,J257 --extra=--hold-lamp
$UVPY tools/traveler/lshu/qa/lshu_light_sweep.py analyse --out=OUT/sweep --ref=OUT/baseline --json=OUT/sweep_summary.json
$GODOT --path . --script res://tools/traveler/lshu/qa/lshu_light_blend_check.gd -- --tile=D01 --light=night --motion-freeze --park=22 --out=$PWD/OUT/blend_check_D01.json
python3 tools/traveler/lshu/qa/lshu_night_lamp_qa.py run --out=OUT/findability --slot=22 --tiles=all
python3 tools/traveler/lshu/qa/lshu_night_lamp_qa.py summary --out=OUT/findability --json=OUT/findability_summary.json
$GODOT --path . --script res://tools/traveler/lshu/qa/lshu_rim_ghost_check.gd -- --park=26 --out=$PWD/OUT/rim_ghost   # 最后一行 LSHU_RIM_GHOST checks=C failed=F
```
