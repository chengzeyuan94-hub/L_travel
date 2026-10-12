# 第四幕「L叔在哪儿」· 循环逻辑（loop/）

L叔按自己的真实时钟旅行（旅蛙式）：在一块地上待 30–60 分钟，收拾离开，路上 4–12 分钟（15% 走远路 30–60 分钟），换到下一块地，他从路口走进来。21:30 以后不出发，就地过夜；一趟 12–24 站，走满后 16:00 以后的下一站是家，在家过夜，次日 08:00–11:00 再出门。

这一层只有纯逻辑，不依赖任何场景，也不写任何地块、地点或素材编号。地块清单作为参数传进来。所有数值都在 `data/traveler/lshu/loop.json`，都是起点，可以随时调，不是验收门槛。

按推荐默认做（Carlos 还没拍板）：
- 决定 1：旅蛙式。点到他只算鞠躬彩蛋，没有找人玩法。
- 决定 2：每站 30–60 分钟。
- 家：pool.json 的 `home` 条目，默认是雪林木屋那块现成地块。
- 路上：屏幕上留着他刚离开的那块空地。

## 文件

| 文件 | 内容 |
|---|---|
| `lshu_clock.gd` | `resolve(save, now_unix, places, cfg)` 纯函数：第 k 站由 `hash(seed, k)` 加存档里的规划状态确定性生成；光照插值；本地时间 |
| `lshu_save.gd` | 存档：原子写、`.bak` 回退、lock、日志压缩、明信片读写标记 |
| `lshu_pool_adapter.gd` | 把 `pool.json` 和 `tiles/<id>.json` 转成 `resolve()` 要的 `places` 数组 |
| `lshu_postcard_text.gd` | 明信片背面：按句库的组合规则挑 1–2 句（`compose_card()`），并给出邮戳（`stamp()`）。和 Python 参考实现 `postcard_lines_check.py` 逐张一致，见下文「明信片句子」 |
| `lshu_postcard_context.gd` | 把一站（leg）换成句库要的输入上下文；站上没有的地形、城市、`postcard_terrain` 从 `pool.json` 和 `tiles/<id>.json` 只读补上 |
| `lshu_hash.gd` | 稳定的 32 位整数哈希，不依赖 Godot 版本 |
| `data/traveler/lshu/loop.json` | 节奏数值 |
| `data/traveler/lshu/postcard_lines.json` | 明信片句库，Claude 起草，等 Carlos 改定。富格式（带 `compose` 规则）按全部规则组合；旧的简单格式仍按旧规则（`normalize_library()` + `compose()`） |
| `tools/traveler/lshu/tests/test_loop.gd`、`run_loop_tests.sh` | 无头测试 |
| `tools/traveler/lshu/tests/test_postcard_rules.gd`、`run_postcard_rules_tests.sh`、`postcard_rules_export.py` | 明信片规则：GDScript 和 Python 参考实现逐张对比 |

这些脚本都没有 `class_name`，用的时候 `preload`：

```gdscript
const LshuClock := preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const LshuSave := preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const LshuPoolAdapter := preload("res://scripts/traveler/lshu/loop/lshu_pool_adapter.gd")
```

## 导演脚本怎么用

```gdscript
var cfg: Dictionary = LshuClock.load_config()        # loop.json，并附上 postcard_lines.json
var places: Array = LshuPoolAdapter.load_places()     # pool.json 加 tiles/*.json
var store := LshuSave.new()                           # 调试时钟用 LshuSave.new(LshuSave.default_dir(true))
var opened: Dictionary = store.open()                 # {ok, data, source, read_only, error}
var save: Dictionary = opened.data                    # 新玩家为 {}

func _tick() -> void:                                 # Timer，每 2 秒一次
	var r: Dictionary = LshuClock.resolve(save, Time.get_unix_time_from_system(), places, cfg)
	if not r.ok:
		return
	save = r.save
	for e in r.events:
		_handle(e)                                    # 见下面的事件表
	_apply_state(r)                                   # r.leg.tile、r.substate、r.light ...
	if _substate_changed(r) or _five_minutes_passed():
		store.write(save)                             # 只读实例会返回 false，不写
```

- 时间一律取 `Time.get_unix_time_from_system()`，不累加帧间隔。窗口被挡或 App Nap 降频时，`resolve()` 结果不变。
- 写档时机：每次子状态切换、每 5 分钟一次，以及收到 `NOTIFICATION_WM_CLOSE_REQUEST` 时；退出时调用 `store.close()` 释放 lock。
- 大约每分钟调用一次 `store.heartbeat()`，让 lock 保持新鲜。只读实例可以定期调用 `store.try_acquire()`，另一个实例的 lock 过期（900 秒没有心跳）后就能接管。
- `resolve()` 不改传入的 `save`，新状态在 `r.save` 里。同一个 seed、同一份地块池，程序开着还是关着，走出来的路线都一样。
- `r.save` 和传入的 `save` 共用没有变化的日志行和明信片记录（只复制会变的容器，这样每 2 秒一次的开销不随明信片越攒越多而变大）。所以 `mark_read`、`complete_render` 只对最新的 `save` 调用，旧的那份直接丢掉。

## `resolve()` 返回什么

| 字段 | 含义 |
|---|---|
| `ok`、`error`、`warnings[]` | 地块池为空时 `ok=false, error="empty_pool"`，不会崩。警告包括 `no_home_tile`（池里没有家，按规则选一个）、`tile_replaced`（当前地块已从池里去掉，换成同一地点的另一块；这个地点一块都不剩时才换地点）、`duplicate_tile:<id>`、`bad_leg_reset`（存档能解析但当前这一站坏了：他回到家，5–15 分钟后出门，日志、明信片和到访次数都保留，站号和趟号接着往后数） |
| `save` | 要存的新存档 |
| `now` | 实际使用的时间。时钟回拨时它等于 `last_seen` |
| `clock_held` | 时钟被往回拨了：停在 `last_seen`，等真实时间追上来，这期间没有事件 |
| `fresh` | 第一次启动 |
| `live` | 距上次调用 ≤ 180 秒：按实时处理，逐个给出事件。超过就按离线补算处理，只给一条 `catchup` |
| `leg` | 当前这一站，屏幕上显示的就是 `leg.tile`。字段见下文 |
| `substate`、`substate_t`、`substate_len` | 子状态，进入它多少秒，这一段一共多长 |
| `night_phase` | 子状态为 `NIGHT` 时是 `doze`（火边打盹）或 `tent`（进了帐篷），其余时候为空 |
| `activity` | `wander` 表示他正走到主景那边转一圈（可选玩法，不需要就忽略） |
| `character_visible` | `ROAD` 和进帐篷后为 false |
| `fire` | `none`（这块地没火）、`lit`、`low`（进帐篷后）、`embers`（他走了，在路上） |
| `light` | `{preset_a, preset_b, blend, band, weights}`，按 `preset_a` 到 `preset_b` 以 `blend`（0–1，已做 smoothstep）插值。不在过渡时两者相同，`blend = 0` |
| `local` | 本地时间：`{year, month, day, hour, minute, weekday, sod, day_index, date_label, time_label}` |
| `next_change_unix` | 下一次状态变化的时刻，可以用来排 Timer |
| `next_tile` | 只在 `LEAVE`、`ROAD` 时有值：`{tile, place, name, kit, home, arrive}`，拿它在后台预载下一块地（`ResourceLoader.load_threaded_request`） |
| `catchup` | 离线补算的摘要，也作为 `catchup` 事件发出 |
| `new_postcards[]`、`dropped_postcards[]` | 这次新加的明信片 id；因为待渲队列超过 3 张而丢掉的 id |

**`leg` 字段**：`index, trip, trip_stop, trip_target, home, initial, night, tile, place, name, kit, layout, layout_class, biome, fire, sub, arrive, settle, depart, road_start, road_end, road_s, long_road, after_long_road, night_start, tent_in, night_end, postcard_at, postcard_shot, line_seed, wanders[[start, end]]`。时刻都是整数 unix 秒；不适用的字段为 -1。`long_road` 是这一站之后的路，`after_long_road` 是到这一站之前的路（明信片「走完远路刚到」用它；旧存档里没有这个字段，按 false）。

## 子状态

| 子状态 | 时段 | 场景做什么 |
|---|---|---|
| `ARRIVE` | `arrive → settle`（20–40 秒） | 新地块已经换上。他从路径起点淡入，走到营地点。刚到站时地名显示 12 秒 |
| `STAY` | 停留 | 按配景做事：look 站立，tea 盘橐坐姿，encounter 巴格达捧物，camp 站在火边 |
| `HOME` | 在家停留 | 和 `STAY` 一样，只是这一站是家 |
| `NIGHT` | `night_start → night_end` | `doze`：坐在火边打盹（21:30 起）；`tent`：进帐篷，人不显示（23:30 到 06:30） |
| `LEAVE` | `depart → road_start`（20–40 秒） | 起身、转身，沿路径走出地块边缘并淡出 |
| `ROAD` | `road_start → road_end` | 地块留在屏上、空着，火变成余烬；后台预载 `next_tile`。结束时用 2–3 秒过渡换到下一块 |

## 事件（`r.events`，按时间排好）

每个事件都带 `{type, at, leg, tile, place, name, kit, home, night}`。

| type | 什么时候 | 场景做什么 |
|---|---|---|
| `first_launch` | 第一次启动 | 直接搭好当前状态：他已经在家，5–15 分钟后出门（夜里启动就等到次日 08:00–11:00） |
| `catchup` | 离线超过 180 秒后第一次调用 | 直接跳到当前状态，不补放动画。带 `{from, to, gap_s, legs_passed, far_jump, places[<=8], places_total, postcards[], postcards_dropped, show_away_card}`；`show_away_card` 为真（离开 ≥ 2 小时）就弹「你不在的时候」小卡 |
| `arrive` | 到一站（ARRIVE 开始） | 换上 `tile`，他走进来，显示地名 |
| `home_arrive` | 到家。家的这一站用它代替 `arrive` | 同上 |
| `settle` | 走到营地点 | 进入配景动作 |
| `wander_start`、`wander_end` | 可选的走一走 | 走到主景抵达点站 1–3 分钟再回来；穿模就忽略这两个事件 |
| `postcard` | 拍明信片的时刻，带 `{postcard, shot}` | 用当前世界渲一帧（`shot`：far / mid / back），成功后 `LshuSave.complete_render(save, id, path)`；2 秒超时就留在 `pending_renders` |
| `night_start` | 开始过夜（21:30 或到站时） | 坐到火边打盹 |
| `tent_in` | 23:30 | 进帐篷，人隐藏，火调低 |
| `night_end` | 06:30 | 回到火边 |
| `leave` | 离开一站（LEAVE 开始） | 起身，沿路走出去 |
| `home_leave` | 离开家。代替 `leave` | 同上 |
| `road_start` | 走出地块边缘 | 地块空着，火转余烬，开始预载下一块 |
| `road_end` | 路走完 | 同一秒紧跟着下一站的 `arrive` 或 `home_arrive` |
| `light_blend` | 光照过渡开始，带 `{from, to, duration_s}` | 可以忽略：每次 `resolve()` 都会给出 `light` |

## `places`：集成方要提供的字段

`resolve()` 的 `places` 参数是一个 Dictionary 数组，每个元素一块地。

| 字段 | 必需 | 含义 |
|---|---|---|
| `id` | 是 | 地块 id，唯一。循环不解析它，只在事件和存档里原样传回 |
| `place` | 是 | 地点 id。「最近 4 处不重复」「没去过的优先」都按地点算。缺省时每块地算一个地点 |
| `kit` | 是 | 配景：`look` / `camp` / `tea` / `encounter`（`bloom` 视为 `encounter`），也可以写 0–3，按 `loop.json` 的 `kits.names` 换算 |
| `layout` | 建议 | 布局，整数或字符串。用来让相邻两站的画面位置有变化 |
| `layout_class` | 可选 | `left` / `center` / `right`。缺省时按 `loop.json` 的 `planner.layout_classes` 由 `layout` 换算 |
| `biome` | 建议 | `snow` / `desert` / `harbor` / `autumn`，明信片地貌句用 |
| `is_home` | 至少一块 | 家。同一地点的其他地块也算家（`home.whole_place`），家所在的地点不作为旅途站。池里没有家时会按规则挑一个，并给出警告 |
| `night_ok` | 可选，缺省 true | false 表示这块地不在夜里出现（夜里 L叔认不出来之类） |
| `fire` | 可选 | 这块地有没有火。缺省时 camp、tea 算有火。过夜站、夜里到的站、夜里的家只选有火的地块 |
| `name` | 可选 | 邮戳上的地名，缺省为 `place` |
| `sub` | 可选 | 自然地点自带的一句话，印在明信片邮戳上（城市地点不用，那里是称号） |
| `blocked` | 可选 | true 就跳过 |

`LshuPoolAdapter.load_places()` 会自动填这些字段：
1. 先读 `data/traveler/lshu/tiles/<id>.json`（lshu.tile.v1）：`place.id`、`place.name`、`place.theme`、`layout.id`、`kit.mode`，`fires[]` 非空就算有火。
2. 如果地块 JSON 还没烘出来，就按 `composition_id` 查网页目录的副本 `tools/traveler/lshu/web_src/config/journey960.json`。这一步只在开发时有效，导出包里没有这个目录，会自动跳过。自然地点的 `sub` 也从这里来；城市地点的 `sub` 是建模说明，不用。
3. `pool.json` 里每块地块上显式写的字段优先：`place, kit, layout, layout_class, biome, is_home, night_ok, fire, place_name, sub, blocked`。

`pool.json` 顶层：`home`（地块 id、地点 id，或它们的数组）；`blocklist`（地块、地点或配方 id，跳过）；可选 `night_blocklist`（这些地块不在夜里出现）。

## 规则摘要（数值都在 loop.json）

- **一站**：到站走进 20–40 秒，停留 30–60 分钟，离开走出 20–40 秒，路上 4–12 分钟，15% 概率走远路 30–60 分钟。
- **夜里**：离开时刻如果落在 21:30 到 07:00 之间，这一站就成为过夜站：21:30 起打盹，23:30 进帐篷，06:30 回到火边，次日 07:00–08:30 出发。所以 21:30 以后不会出发；已经在路上的可能 21:30 以后才到站，到了就过夜。
- **一趟**：出门时按 `hash(seed, 趟序号)` 定 12–24 站。走满以后，16:00 以后到的下一站就是家。硬上限 40 站，到了就回家。
- **家**：当晚过夜，次日 08:00–11:00 出门。
- **第一次启动**：他在家，5–15 分钟后出门；如果那时已经是夜里，就等到次日 08:00–11:00。
- **选下一站**（移植网页规划器）：先排除最近 4 个地点；过夜或夜里到站时，只留有火（且 night_ok）的地点；再只留去得最少的地点，也就是没去过的优先；最后按 `hash(seed ^ 地点, k)` 排序取第一。这样和地块池的顺序无关。
- **选地块**：在这个地点的地块里按到站时刻的配景权重抽（早上偏远望，中午偏拾花，下午偏喝茶，傍晚偏扎营；需要火时只用 camp / tea 的权重）；和上一站 `layout_class` 相同的权重乘 0.25，去过的次数越多权重越低。
- **明信片**：白天站 25%，过夜站和家 40%，时刻落在停留窗口的 20%–80%。过夜站只在入帐篷之前拍，这样画面里有火。取景按 far / mid / back 40 / 40 / 20 抽。第一次启动那一站不拍。
- **离线补算**：从上次那一站一直推到现在，日志照记。补出来的明信片只留最后 3 张，待渲队列最多 3 张，超出就丢最旧的。一次最多推 3000 站，超过就记一行 `long_way`，他从现在起到一个新地点。
- **时钟回拨**（`now < last_seen`）：按 `last_seen` 算，不发事件，等真实时间追上来。
- **光照**：晨 05:30、昼 08:00、昏 17:00、夜 19:30。每个档的起点前后各用一半过渡时长做 smoothstep（晨 40、昼 30、昏 30、夜 40 分钟）。
- **本地时间**：`Time.get_datetime_dict_from_unix_time(unix + 时区偏移)`。偏移由 `LshuClock.system_tz_offset_s()` 从本机的本地时间反推，不用 `Time.get_time_zone_from_system().bias`：Godot 4.7 在负的半小时时区里会差一小时（纽芬兰给 -90 分钟，实际是 -150）。测试可以在 cfg 里设 `tz_offset_minutes` 固定时区。
- **夏令时（已知限制）**：已经生成的站按绝对时刻存着，不受影响；新生成的站按生成那一刻的偏移算。程序关着跨过夏令时切换，补算出来的站全部按新偏移算，所以之后的路线可能和一直开着时不同（模拟 20 个种子，关着跨过切换的有 5 个最后停在不同的站）。Godot 拿不到历史时区，这一点无法做到完全一致。中国没有夏令时，Carlos 的机器不受影响。

## 存档（`lshu_save.gd`）

- 目录 `OS.get_data_dir()/ShanheLvren/lshu_where/`：`save.json`、`save.json.bak`、`save.json.tmp`、`save.lock`、`postcards/<id>.jpg`。
- **写**：先写 `.tmp`，读回来和写入的文本逐字比较（不再整份重新解析），再把能解析的 `save.json` 改名成 `.bak`，最后把 `.tmp` 改名成 `save.json`。已经坏掉的 `save.json` 不会被轮换进 `.bak`。每次写入带一个递增的 `save_seq`，判断哪份更新只看它，不看墙上时钟。
- **读**：先读 `save.json`；如果旁边有一份完整、`save_seq` 更大的 `.tmp`（进程死在校验之后、改名之前），就用 `.tmp`（`source = "tmp"`）。`save.json` 缺失或解析失败时，取 `.tmp` 和 `.bak` 中较新的一份。都不能用就把坏文件另存成 `.corrupt-<时间>` 再从头开始。路线是确定性的，从旧一份恢复也会走出同样的路线，只少最后几分钟的明信片和已读标记。
- **存档变大以后**：明信片记录一年约 1800 条，`save.json` 约 0.9 MB。`write()` 在 1800 条时约 19 毫秒，9000 条（约五年）时约 91 毫秒，都在主线程上。建议导演脚本只在子状态切换、每 5 分钟和退出时写。如果以后要更平滑，可以把旧明信片记录挪到单独的文件。
- **schema** `lshu.where.save.v1`。遇到不认识的 schema（比如更新的版本写的），只读，绝不覆盖。
- **lock**：`{pid, token, heartbeat_unix}`。第二个实例发现一个 900 秒内有心跳、而且记录的进程还在运行的 lock，就以只读方式打开：照样能算、能显示，只是 `write()` 返回 false。如果记录的进程已经不在了（崩溃、强退），就立刻接管，不用等 15 分钟。进程是否还在由 `LshuSave.pid_state()` 判断：有 `/proc` 的系统（Android、Linux）查 `/proc/<pid>`，macOS 调一次 `/bin/ps -p`，判断不了时仍按心跳时间。不用 `OS.is_process_running()`，它在 Unix 上只认本进程的子进程。
- **字段**：`schema, seed, origin_unix, leg_index, current_leg, recent_places[], visited{地点: 次数}, visited_tiles{}, last_layout_class, trip{index, stops, target, started}, log[], postcards[], pending_renders[], last_seen_unix, stats{legs, far_jumps, home_nights}, saved_unix`。
- **log**：每走完一站记一条 `{type:"leg", k, trip, tile, place, name, kit, home, night, arrive, depart, road_end}`，另有 `{type:"long_way"}`。超过 500 条时，最旧的一趟压成一行 `{type:"trip", trip, from, to, stops, home, nights, places[<=8]}`。最新的两趟（正在走的和上一趟）始终一站一行；更早的都压完以后，就删最旧的汇总行（约 500 趟、两年以后才会发生）。旅行本按 `trip` 分组，明信片按 `leg` 挂到对应的站上，已经压成汇总的趟按 `trip` 挂。
- **明信片**：`{id, leg, trip, tile, place, name, kit, biome, home, night, shot, unix, band, date, time, line_seed, text[], signature, file, read}`，富格式句库另有 `line_ids[], categories[], city_id, stamp{title, home_mark, date, slot, slot_label, caption, caption_kind, city_id, city_blocked}`。
  - `line_ids` 是这张用过的句子编号，最近 20 张的 `line_ids` 就是下一张的去重历史。
  - `stamp.caption`：城市地点是 `city_lore_v1.json` 的称号（`CONTENT_BLOCKED` 且 `blocked_policy` 为 `omit` 时空着），自然地点是它的 `sub`。界面显示时调用 `LshuPostcardText.restamp(record, lib)`，这样 Carlos 以后把 `blocked_policy` 改成 `show`，旧明信片也会补上称号。
  - `id` 是 `pc_<seed 的 8 位十六进制>_<站号>`（`LshuClock.postcard_id(seed, k)`）。带上 seed，是为了让两份存档（坏档后重开、60 倍速调试存档）不会写出同名的 `postcards/<id>.jpg`，把旧图盖掉。另存到「图片」文件夹时也用这个 id 当文件名。
  - `file` 为空表示还没渲，它的 id 在 `pending_renders[]` 里。渲好以后调用 `LshuSave.complete_render(save, id, store.postcard_image_path(id))`。
  - 点开看过以后调用 `LshuSave.mark_read(save, id)`。
  - `LshuSave.unread(save)` 非空时，右下角显示小邮票。
- **启动时补渲**：`pending_renders` 里的明信片（最多 3 张），对应地块不在屏上，要在独立的 SubViewport（`own_world_3d = true`）里临时搭那块地渲一帧，放在开场淡入之前做完。

## 调试时钟 `--lshu-clock-scale=60`

```gdscript
var scale: float = LshuClock.clock_scale_from_args(OS.get_cmdline_user_args())
var cfg: Dictionary = LshuClock.scaled_config(LshuClock.load_config(), scale)
var anchor_real: float = Time.get_unix_time_from_system()
var anchor_logic: float = anchor_real
var now: float = LshuClock.scaled_now(Time.get_unix_time_from_system(), anchor_real, anchor_logic, scale)
```

`scaled_config` 把「实时 / 离线补算」的分界（`catchup.live_gap_s`，180 秒逻辑时间）乘上倍速。60 倍速下每 2 秒一次就是 120 秒逻辑时间，不乘的话，只要有一次 Timer 晚到 1 秒以上，这一跳就会被当成离线补算：他直接跳到下一站，不走出去也不走进来。

加速时钟会跑到真实时间前面，所以**必须**用 `LshuSave.new(LshuSave.default_dir(true))`（`lshu_where_scaled/`）。否则真实存档的 `last_seen` 会落在未来，之后几天都处于「时钟回拨」状态。

## 明信片句子（`lshu_postcard_text.gd`）

`LshuClock` 拍明信片时调用 `LshuPostcardText.fill_postcard(pc, leg, lines, seed, save.postcards, local_info)`：
上下文由 `LshuPostcardContext.for_leg()` 从这一站得出，历史是最近 20 张明信片的 `line_ids`，随机键是 `[seed, 站号, 0]`（0 是这一站的第几张，以后鞠躬彩蛋的那张用 1）。
规则全部来自句库的 `compose` / `limits` / `terrain_resolve` / `stamp`，逐条移植自 `postcard_lines_check.py`：

1. 归一：slot、kit 按别名；地貌标签 = `postcard_terrain`，否则 城 + `from_landform` + `from_biome`，都没有就用 `fallback`。
2. 主句类别：「你不在的时候」小卡 → road；在家 → home；走完远路且到站不超过 20 分钟 → 以 0.7 取 road；到站不超过 10 分钟 → 以 0.1 取 road；否则按 `weights`（过夜站用 `weights_overnight`）在 terrain、kit 之间抽。
3. 地貌组：城市地点以 `city_weight` 取「城」，其余在自然标签间平分。
4. 选句：去掉最近 20 张用过的和 `avoid` 命中的（拾花句不进雪地、回家句不在早上）；都去光了就取最久没用的一句。
5. 第二句：概率 `p`（家 `p_home`，小卡为 0），类别按 `weights_by_primary` 抽且不同于主句；不能和主句共享母题（第二句不做母题兜底，没有就不加）；两句超过 `max_card_chars` 就换一次，仍超就只留主句。
6. 按 `card_order` 排好，用 `joiner` 连接。

随机数和 Python 相同：`sha256("|".join(键, 步号))` 的前 8 字节 / 2^64；权重求和按 Python 3.12 的补偿求和。所以同一上下文、同一历史、同一键，两边出同一张卡。故意的不同只在 Python 会直接报错的地方：未知 slot 用 day，未知配景用第一个配景组，不是地貌组的 `postcard_terrain` 忽略，某组句子全被 `avoid` 去掉时主句改用时段句，`no_repeat_window_cards` ≤ 0 表示不去重（Python 的 `history[-0:]` 是全部历史）。现有句库一条都碰不到。

「你不在的时候」小卡的那一句：`LshuPostcardText.away_card(lib, history, [seed, "away", k])`。

## 测试

```bash
tools/traveler/lshu/tests/run_postcard_rules_tests.sh   # 明信片规则：GDScript 对 Python，逐张
tools/traveler/lshu/tests/run_loop_tests.sh
# 或只跑主测试
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/traveler/lshu/tests/test_loop.gd
```

输出 PASS / FAIL / METRIC 行和 `LSHU_LOOP_TESTS passed=N failed=M`。`run_loop_tests.sh` 接着在 6 个时区（含纽芬兰、马克萨斯这两个负的半小时时区）下各跑一次 `test_loop_tz.gd`，核对时钟的本地时间和系统时间一致，最后一行是 `LSHU_LOOP_TZ_SUMMARY zones=6 failed=K`。任何一项失败，退出码都非 0。

`run_postcard_rules_tests.sh` 先用 `postcard_rules_export.py`（调用 `postcard_lines_check.py` 本身）导出 Python 的卡片，再在 GDScript 里用同样的种子重新生成上下文和卡片，逐张比较：`sim`（参考实现 `simulate()` 的 2000 张）、`edge`（别名、数字配景、小卡、`postcard_terrain`，2000 张）、`tight`（`max_card_chars` 30、窗口 8，专门跑「超长换一次」，2000 张），外加只传最近 20 张历史的一遍、300 个随机数、300 个求和、真实地块池 4 个种子各 14 天的时钟明信片回放。最后一行 `LSHU_POSTCARD_RULES passed=N failed=M`。

`fixtures/postcard_lines_rich_recovered.json` 是文案 agent 写的富格式句库（102 句），它在 `data/` 里的那份被覆盖了，这里是从对话记录里恢复的副本，只给测试用：它的配景别名里有数字，`normalize_library()` 以前遇到数字会中断。测试用程序生成的地块（40 个地点 × 4 种配景），另有一组用真实的 `pool.json` 跑，编号在运行时读取，测试代码里也不写。

覆盖：
- 第一次启动在 5–15 分钟内出门；
- 出门途中关 3 小时（60 组，和一直开着逐一对比）；
- 隔夜重开；关 30 天；关 400 天（3000 站上限）；
- 时钟回拨 1 小时和 2 天；
- 同一 seed 两次结果一致，调用频率不影响结果；
- 写档中途被杀（写 .tmp 时、两次改名之间、save.json 被截断）；两份都坏；
- 第二个实例只读；过期 lock 被接管；未知 schema 不覆盖；log 500 条上限；
- 夜里不出发；每趟都回家；
- 抽 1000 站看分布；补出来的明信片最多 3 张；
- 每 2 秒调用一次时的实时事件；光照连续；night_ok 和有火的过滤；
- 从池里删掉当前地块；空池；池里没有家；
- 真实 P0 池；明信片句子；系统时区；循环代码里搜编号。
- 2026-09-24 对抗评审补的 9 项（`review_*`）：两份存档的明信片 id 不重名；明信片攒到 9000 条时每 2 秒一次的开销不变，而且不改传入的存档；约 500 趟以后最新两趟仍然一站一行；进程死在 `.tmp` 校验之后能读回最新的一份；当前这一站坏掉的存档能恢复；崩溃留下的 lock 立即接管；地块被移出池子时留在同一地点；60 倍速下晚到的一跳仍按实时处理；富格式句库里的数字别名。
