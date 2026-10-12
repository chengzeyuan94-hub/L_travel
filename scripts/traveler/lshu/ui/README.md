# 第四幕「L叔在哪儿」· 界面（ui/）

全部用代码搭的 Control，没有 `.tscn`。只吃三样数据：存档字典、明信片记录、`LshuClock.resolve()` 的事件。不认识任何地块、地点或素材编号，不写存档。

默认屏幕上什么都没有：

| 部件 | 什么时候出现 | 怎么消失 |
|---|---|---|
| 地名（左下） | 到站时显示 12 秒；鼠标一动再露 4 秒 | 淡出 |
| 小邮票（右下） | 有未读明信片时；不显示数字 | 没有未读就淡出；翻旅行本时暂时收起 |
| 明信片 | 点邮票（最早那张未读）或点旅行本/小卡里的缩略图 | 点空白处、Esc、再点邮票，或 20 秒没有操作；飞回邮票（或飞回缩略图），这张记为已读 |
| 旅行本 | 按 L | 再按 L、Esc、点书外面，或 60 秒没有操作 |
| 「你不在的时候」 | 离开 2 小时以上后第一次 `resolve()`；写离开多久、最多 8 个路过的地点、他现在在哪、L叔的一句、这期间寄回的明信片 | 15 秒（鼠标停在卡上时暂停）；点一下也会收起 |

## 文件

| 文件 | 内容 |
|---|---|
| `lshu_ui.gd` | 根节点（CanvasLayer，layer 20）。导演只跟它打交道 |
| `lshu_ui_data.gd` | 纯数据：日期、趟分组、路线文字、邮戳、地名副题、「你不在的时候」文字。无节点，可无头测试 |
| `lshu_ui_style.gd` | 配色、字体、尺寸、模糊 shader、邮票/邮戳画法、中文断行 |
| `lshu_ui_images.gd` | 明信片图片缓存；缩略图在 WorkerThreadPool 上解码缩小 |
| `lshu_place_caption.gd` | 左下地名 |
| `lshu_stamp_indicator.gd` | 右下小邮票 |
| `lshu_postcard_view.gd`、`lshu_postcard_card.gd` | 明信片查看器和卡片正反面 |
| `lshu_postcard_thumb.gd` | 缩略图（旅行本、小卡） |
| `lshu_travel_book.gd` | 旅行本 |
| `lshu_away_card.gd` | 「你不在的时候」 |

和 loop/ 一样，这些脚本都没有 `class_name`，用 `preload`。

## 导演脚本怎么接

```gdscript
const LshuUi := preload("res://scripts/traveler/lshu/ui/lshu_ui.gd")

var ui: CanvasLayer = LshuUi.new()
add_child(ui)                                   # 作为导演节点的子节点，按键先到它这里
ui.configure(cfg, places)                       # cfg = LshuClock.load_config()，places = LshuPoolAdapter.load_places()
ui.postcard_read.connect(func(id: String) -> void:
	LshuSave.mark_read(save, id)                # 只对最新的 save 调用
	store.write(save))

func _tick() -> void:                           # 每 2 秒
	var r: Dictionary = LshuClock.resolve(save, now, places, cfg)
	if not r.ok:
		return
	save = r.save
	# ……导演自己处理事件、换地块、渲明信片（complete_render）……
	ui.apply_resolve(r)                         # 一次调用：存档、他在哪、是否在路上、本轮事件、未读明信片
```

`apply_resolve(r)` 等于依次调用 `set_save(r.save)`、`set_place(r.leg, 在路上?)`、对 `r.events` 逐个 `handle_event(e)`、`set_unread(LshuSave.unread(r.save))`。想逐项控制时直接调下面这些。

**明信片渲好以后**：先 `LshuSave.complete_render(save, id, path)`，下一次 `apply_resolve` 自然会把它算进未读，邮票就出来了。`LshuSave.unread()` 只返回已经有图片的明信片。

## 调用

| 调用 | 作用 |
|---|---|
| `configure(cfg := {}, places := [])` | 可选。时区取 `cfg.tz_offset_minutes`（没有就用本机时区，和时钟同一算法）；句库取 `cfg.postcard_lines`（邮戳的时段字、日期格式、城市称号规则）；`places` 给地名副题兜底 |
| `apply_resolve(r)` | 见上 |
| `handle_event(e)` | `arrive` / `home_arrive` / `first_launch` → 显示地名；`leave` / `home_leave` → 地名淡出；`road_start` → 地名改成「在路上 / 刚离开…」（鼠标动时显示）；`catchup` → 露一下当前地名，`show_away_card` 为真时弹「你不在的时候」。其余事件忽略 |
| `show_arrival(place)` | 左下显示地名 12 秒后淡出。`place` 可以是事件、`r.leg`、`places[]` 里的一项，或手写的 `{name, sub}`；给了 `caption_sub` 就直接用它 |
| `set_place(place, on_road := false)` | 只更新鼠标移动时显示的内容，不弹出 |
| `hide_caption()` | 立即隐藏地名 |
| `set_unread(records)` | 未读明信片记录（`LshuSave.unread(save)`）。非空时显示邮票；点邮票打开最早那张。UI 已经报过已读、但存档还没跟上的会被忽略 |
| `set_unread_count(n)` | 只要邮票、不给记录时用：n > 0 显示邮票，点击只发 `stamp_pressed` |
| `open_postcard(record, from_rect := Rect2())` | 打开一张明信片（正面朝上）。`from_rect` 为缩略图的全局矩形时从它放大、关时飞回它；空的时候从下方滑上来、关时飞进邮票 |
| `close_postcard()`、`flip_postcard()` | 收起 / 翻面 |
| `open_book()`、`close_book()`、`toggle_book()` | 旅行本 |
| `show_away(catchup, records := [])` | 「你不在的时候」。`records` 为空时按 `catchup.postcards` 从存档里找有图片的那几张 |
| `hide_away()` | 收起小卡 |
| `notify_activity()` | 导演自己的输入处理可以调它：地名露一下、各个空闲计时清零 |
| `is_busy()` | 明信片或旅行本开着（这时点击不会落到场景里，导演也可以借此暂停点人鞠躬） |
| `is_any_visible()` | 屏幕上有没有任何界面 |
| `state()` | QA 用的快照：每个部件是否可见、矩形、缩放 |

**信号**

| 信号 | 什么时候 |
|---|---|
| `postcard_read(id)` | 一张未读明信片被看过后收起（点空白、Esc、再点邮票、20 秒空闲都算）。每张只发一次。导演据此 `LshuSave.mark_read(save, id)` 并写档 |
| `postcard_opened(id)`、`postcard_closed(id, reason)` | reason：`click` / `idle` / `key` / `api` |
| `stamp_pressed` | 点了邮票（有记录时 UI 自己打开明信片，这个信号只是通知） |
| `book_toggled(is_open)` | 旅行本开关 |
| `busy_changed(is_busy)` | 明信片或旅行本打开（true）/ 都收起（false）。这期间点击不会落到场景里，导演可以借它暂停「点他鞠躬」 |
| `away_line_shown(line_ids)` | 「你不在的时候」小卡印了 L叔的一句（句库编号）。UI 不存它；导演想让这句也进 20 张去重，就自己记下这些编号 |

**可调参数**（`@export`，都是起点）：`caption_hold_s = 12`、`caption_hover_s = 4`、`postcard_idle_s = 20`、`book_idle_s = 60`、`away_hold_s = 15`、`handle_book_key = true`、`book_keycode = KEY_L`。

## 注意

- **L 键**：已接入导演（2026-09-24）：L 只开旅行本；原来的开发键挪到 F1–F4，而且只在 `--lshu-dev` 下有（见 `tools/traveler/lshu/README.md`）。UI 在 `_unhandled_key_input` 里处理 L 并标记已处理。
- **鞠躬照**：导演把点他拍的照片记成 `type: "snap"` 的明信片记录；旅行本（`build_trips`）里同一站既有明信片又有鞠躬照时，缩略图用明信片。
- **不写存档**：已读只通过 `postcard_read` 信号交给导演。
- **背面文字**：只印明信片记录里的 `text[]`（组句在 loop 的 `LshuPostcardText` 里完成）和 `signature`，UI 不自己编句子。
- **邮戳**：优先用记录里的 `stamp{}`（循环拍明信片时由 `LshuPostcardText.stamp()` 算好）：地名（「城 · 景」只取城名）、时段字、「家」；日期按明信片的 `unix` 和本地时区、句库 `stamp.date_format` 算。没有 `stamp{}` 的旧记录按同一套规则现算。
- **「你不在的时候」那一句**：句库 `compose.away_card` 规定小卡带一句 road 类的话。UI 用 `LshuPostcardText.away_card(句库, 最近 20 张的 line_ids, [seed, "away", catchup.to])` 现算，同一次补算永远是同一句，不和最近 20 张明信片重复；用蓝黑墨水印在「现在他在…」下面，落款「—— L」。这句不写进存档（见信号 `away_line_shown`）。
- **地名副题**（句库 `stamp.caption` 规则）：城市地点显示 `city_lore_v1.json` 的称号，称号处于 `CONTENT_BLOCKED` 时不写；自然地点显示自带的一句 `sub`；城市地点从不显示 `sub`（那是建模说明）。城市由地块 JSON 的 `place.city` 经 `cities.json` 换算，只读、按地块缓存。
- **旅行本**：按 `trip` 分组，最新的在上，每页 12 趟，底下「更早的旅程」再加载 12 趟。每个「→」和它前面的地点绑在一起换行，进行中那趟末尾的「→ …」跟着最后一站，所以换行后的行首不会是箭头。已经被日志压成一行的旧趟显示其中最多 8 个地点，明信片挂在趟上。第一次启动那一站（只在家）不列。没有张数、完成度。
- **缩放**：尺寸按 1920×1080 的物理像素设计，按 `min(宽/1920, 高/1080)` 缩放，下限 0.5、上限 4；小字不低于 11 物理像素。项目的 `canvas_items` 拉伸（1280×720 基准）已经算进去：先求每个逻辑单位对应几个物理像素，再换算。3440×1440 按高度算（1.333）。明信片占屏高 60%（640×360 小窗口里 80%），宽度不超过屏宽 86%。
- **字体**：项目现成的 `assets/game/ui/fonts/hud_*.tres`（PingFang SC 等系统字体，只读引用），字距用 FontVariation 叠在上面。
- **背景模糊**：画布 shader 读屏幕纹理的 mipmap（Forward+）。移动端 Compatibility 渲染器没测。明信片查看器前面放了一个 `BackBufferCopy`：Godot 每帧只自动拷一次屏幕，没有它的话，从旅行本里点开的明信片会用旅行本之前的那份屏幕当背景，旅行本就看不见了；有了它，背后是模糊的旅行本。
- **滚轮**：明信片开着时滚轮不会把它收起，也不会漏到场景里。
- **图片**：点开明信片时正面在主线程读（1080p JPG 约 10–20 毫秒）；有未读时会提前在后台线程预读第一张。缩略图全部在后台线程解码缩小（最长边 320）。缓存最多 96 张。
- 鼠标指针的显示和隐藏不归 UI 管。

## 测试

```bash
tools/traveler/lshu/tests/run_ui_tests.sh
```

- `tools/traveler/lshu/tests/test_ui.gd`（无头）：数据层（日期、分组、路线、邮戳、副题规则、断行、压缩日志、远路）、真实输入事件驱动的行为（缩短计时）、三种分辨率 × 有无拉伸的缩放、一年规模存档的开销、UI 代码里搜编号。最后一行 `LSHU_UI_TESTS passed=N failed=M`。
- `tools/traveler/lshu/tests/ui_harness.tscn`（开窗口，停在第 10 号位）：用真实循环跑出一份两天多的存档，界面叠在场景渲染图上，用真实点击和按键走一遍，截图写到 `docs/reports/traveler-lshu-ui-20260924/`：`ui_caption.png`、`ui_stamp.png`、`ui_postcard_front.png`、`ui_postcard_back.png`、`ui_book.png`、`ui_away.png`，3440×1440 和 640×360 各一组，`ui_sheet.png` 拼图，`ui_harness_report.json`。最后一行 `LSHU_UI_HARNESS errors=N warnings=W checks=C failed=F`。
- `tools/traveler/lshu/tests/ui_sample_data.gd`：两边共用的样例存档生成器。明信片正面用 `docs/reports/traveler-lshu-20260923/` 里同一地块的渲染图裁成 3:2，没有就用 P0 矩阵里完整的 PNG，再没有就生成一张渐变图，都写在 `user://`。
