class_name AIDifficulty
extends RefCounted

## 电脑商旅的三档难度（Carlos 2026-09-25）：
##   轻装启程 · 7 岁  —— 知道进城做买卖，但想不远：就近进城、能买就买、常按 1 银/件卖，偶尔走错、忘了交易
##   山海独旅 · 12 岁 —— 原有 AI：只做算得过来的赚钱买卖，会把货运到别城卖更好的价
##   万里商途 · 16 岁 —— 原有 AI 再加终局意识：知道时间/白银快到头时停止进货、先变现，路线看得更远
## 未指定时为山海独旅（与原有 AI 完全一致，正式测试基准不变）。

const EASY := "qingzhuang"
const MEDIUM := "shanhai"
const HARD := "wanli"
const DEFAULT := MEDIUM
const ORDER := [EASY, MEDIUM, HARD]

const INFO := {
	EASY: {"name": "轻装启程", "age": "7 岁", "blurb": "知道进城做买卖，但想不远"},
	MEDIUM: {"name": "山海独旅", "age": "12 岁", "blurb": "只做算得过来的赚钱买卖"},
	HARD: {"name": "万里商途", "age": "16 岁", "blurb": "精打细算，知道何时收手变现"},
}


static func normalize(id: String) -> String:
	return id if INFO.has(id) else DEFAULT


static func of(player: PlayerState) -> String:
	return normalize(player.ai_difficulty) if player != null else DEFAULT


static func display_name(id: String) -> String:
	return String(INFO[normalize(id)]["name"])


static func age_text(id: String) -> String:
	return String(INFO[normalize(id)]["age"])
