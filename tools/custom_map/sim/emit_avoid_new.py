#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""emit_avoid_new.py — 从仓库当前的 scripts/ai/ai_policy.gd 生成真人代理 2「从不进新城」的策略副本（DESIGN 4.4）。

旧做法只在 AIPolicy.choose_move 已经选中新城之后才换一个候选，而电脑的打分、远端寻路、变现估价仍把新城当最好的去处：
代理一回合回合想进新城又退回来原地不动，量到的是「被自己卡住的玩家」，不是「换一种简单打法的真人」（复查实测：
B7 上想进新城 329/699 次，其中 304 次退成原地；真人回合原地结束 380/720，proxy_same 只有 135/720）。

这里改的是代理自己眼里的地图——新城和新商道上的道路点根本不存在：
  1. _build_move_candidates：不把新城、新商道道路点当移动候选（站在上面时的「原地」除外）；
  2. _score_destination：新城、新商道道路点极低分；
  3. _best_future_city_score：跨回合寻路的 BFS 不走进新城、新商道；
  4. _best_liquidation_value / _best_liquidation_city：变现估价（买入估价、持货比较、万里商途终局都经过它）不看新城的市场。
其余与电脑（山海独旅）逐字相同。没有新城的对局里上面四处都不生效，与 AIPolicy 逐局相同（plan_smoke 自检）。
新城 = content.custom_map_new_cities；新商道道路点 = 从新城节点沿道路点一直走到第一座原城之前经过的点（不靠 id 命名规则）。

写到仓库外（默认本次运行的输出目录），仓库里不留副本；只给 tools/custom_map/sim 用，不进仓库的 AI。
用法：python3 emit_avoid_new.py <输出 .gd 路径>
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]

# (函数名, 旧片段, 新片段)：每条都必须在该函数体里恰好出现一次
PATCHES = [
    ("_build_move_candidates",
     "\tfor node_id in node_ids:\n\t\tvar steps: int = destinations[node_id]\n",
     "\tfor node_id in node_ids:\n"
     "\t\tif _avoid_node(String(node_id)) and String(node_id) != player.current_node_id:\n"
     "\t\t\tcontinue\n"
     "\t\tvar steps: int = destinations[node_id]\n"),
    ("_score_destination",
     "\tvar content: Dictionary = GameState.content\n\tvar score := 0\n",
     "\tif _avoid_node(node_id):\n\t\treturn -1000000\n\tvar content: Dictionary = GameState.content\n\tvar score := 0\n"),
    ("_best_future_city_score",
     "\t\t\tif not distance.has(other):\n",
     "\t\t\tif not distance.has(other) and not _avoid_node(other):\n"),
    ("_best_liquidation_value",
     "\t\tif city_id == excluded_city_id:\n\t\t\tcontinue\n",
     "\t\tif city_id == excluded_city_id or _avoid_city(city_id):\n\t\t\tcontinue\n"),
    ("_best_liquidation_city",
     "\t\tif city_id == excluded_city_id:\n\t\t\tcontinue\n",
     "\t\tif city_id == excluded_city_id or _avoid_city(city_id):\n\t\t\tcontinue\n"),
]

HELPERS = '''

# ---------- 真人代理「从不进新城」（emit_avoid_new.py 追加）----------

static var _avoid_key := ""
static var _avoid_nodes := {}


static func _avoid_city(city_id: String) -> bool:
	return (GameState.content.get("custom_map_new_cities", {}) as Dictionary).has(city_id)


## 新城节点，以及从新城沿道路点走到第一座原城之前经过的道路点（新商道）。按对局缓存。
static func _avoid_node(node_id: String) -> bool:
	var content: Dictionary = GameState.content
	var newc: Dictionary = content.get("custom_map_new_cities", {})
	if newc.is_empty():
		return false
	var key := "%d|%s|%d" % [GameState.session_generation, String(content.get("custom_map", {}).get("topology_key", "")), newc.size()]
	if key != _avoid_key:
		_avoid_key = key
		_avoid_nodes = {}
		for city_id in newc.keys():
			var start := String(content["cities"][city_id].get("board_node_id", city_id))
			_avoid_nodes[start] = true
			var frontier: Array[String] = [start]
			while not frontier.is_empty():
				var cur := String(frontier.pop_front())
				for edge in GameData.get_edges_from(content, cur):
					var other := GameData.edge_other_node(edge, cur)
					if _avoid_nodes.has(other) or GameData.is_city_node(content, other):
						continue
					_avoid_nodes[other] = true
					frontier.append(other)
	return _avoid_nodes.has(node_id)
'''


def func_span(src: str, name: str) -> tuple[int, int]:
    head = "static func %s(" % name
    if src.count(head) != 1:
        raise ValueError("找不到或不唯一：%s" % head)
    a = src.index(head)
    b = src.find("\nstatic func ", a + len(head))
    return a, (len(src) if b < 0 else b)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    src = (REPO / "scripts" / "ai" / "ai_policy.gd").read_text(encoding="utf-8")
    if not src.startswith("class_name AIPolicy\n"):
        print("ai_policy.gd 已变化（开头不是 class_name AIPolicy），avoid_new 补丁需要重新核对")
        sys.exit(1)
    out = src.replace("class_name AIPolicy\n",
                      "## 模拟用副本（emit_avoid_new.py 生成）：真人代理「从不进新城」——新城和新商道在它眼里不存在。\n", 1)
    for name, old, new in PATCHES:
        try:
            a, b = func_span(out, name)
        except ValueError as e:
            print("ai_policy.gd 已变化，avoid_new 补丁需要重新核对：%s" % e)
            sys.exit(1)
        body = out[a:b]
        if body.count(old) != 1:
            print("ai_policy.gd 已变化，avoid_new 补丁需要重新核对：%s 里的片段出现 %d 次" % (name, body.count(old)))
            sys.exit(1)
        out = out[:a] + body.replace(old, new, 1) + out[b:]
    out = out.rstrip("\n") + "\n" + HELPERS
    Path(sys.argv[1]).write_text(out, encoding="utf-8")
    print("写出 %s" % sys.argv[1])


if __name__ == "__main__":
    main()
