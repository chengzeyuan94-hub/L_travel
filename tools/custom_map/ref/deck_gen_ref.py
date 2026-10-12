#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""deck_gen_ref.py — 贸易卡生成器 tradegen_v1 的 Python 参考实现（WP2，冻结）。

来源：docs/design/map-editor-20260930/work/economy/deck_gen.py（经济组 v4 生成器 + 循环护栏），本文件在它上面加了
  - 近源封顶（DESIGN R13，生成器第 10 步）；
  - 槽位代号（R18）：新城 id = x_<槽位>，新货先用 x_<槽位> 当代号，生成完才换成真实 id；
  - 冻结参数的导出与读取（data/custom_map/tradegen_v1_params.json，浮点另存 IEEE 位，两种语言读到的值逐位相同）；
  - 规范槽位的接法枚举（一对 / 两对，DESIGN 3.4、R6、R9）与参考牌堆夹具（tests/fixtures/custom_map/tradegen_ref/）；
  - 跨语言一致要用的两条统一做法（DESIGN 3.14.5）：浮点排序键先按 1e-9 取整（k9）；生成路径里的均值一律
    「从左到右求和再除」（Python statistics.mean 按分数精确求和，GDScript 做不到，改成两边同一种写法）。
    crosscheck 命令证明这两处改动在全部接法上都不改变输出。

scripts/custom_map/trade_gen_v1.gd 是它的 GDScript 移植，全部接法逐字节相同（tests/custom_map_tradegen_tests.gd T-G3a）。

用法
  python3 deck_gen_ref.py params [--check]        # 从原版 80 张卡拟合参数，写出（或核对）冻结参数 JSON；产品旋钮从现有文件拷贝
  python3 deck_gen_ref.py topologies [--list]     # 规范槽位下的全部接法：一对 46 种、两对 721 种
  python3 deck_gen_ref.py fixtures [--check]      # 写出（或核对）参考牌堆夹具、留一回测夹具、金样（金样写出后不覆盖，见 GOLDEN_NAME）
  python3 deck_gen_ref.py generate --topology 'topo_v1|e1:changan:LAND:w1|w1:aden:SEA:e1' [--goods e1=kaolin,w1=coral]
  python3 deck_gen_ref.py sweep                   # 全部接法的统计：封顶张数、护栏次数、循环最大值、白银均值、搭档收购价
  python3 deck_gen_ref.py extra-loops             # T-G3d 的三项补查（全部接法）：以物易物三角、期望单程、原地买卖；超原版退出码 1
  python3 deck_gen_ref.py crosscheck              # k9 取整 / 朴素均值 与原写法在全部接法上输出相同
  python3 deck_gen_ref.py backtest | loops | selftest   # 保留 ECONOMY 的三个回归命令

纯 Python 3 标准库；只读规则集；写文件只写到上面说的仓库路径。
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import itertools
import json
import math
import statistics
import struct
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
RULESET_DIR = REPO / "data" / "rulesets" / "lshu_configurable_v1"
PARAMS_PATH = REPO / "data" / "custom_map" / "tradegen_v1_params.json"
FIXTURE_DIR = REPO / "tests" / "fixtures" / "custom_map" / "tradegen_ref"

VERSION = "tradegen_v1"
LAND, SEA = "LAND", "SEA"
WAREHOUSE = 4
S_MIN, S_MAX = 2, 5
Q_MAX = 4
MAP_MID_X = 2048.0          # 东西按宿主城 cities.json 的 map_position.x 判定（R8）

# 跨语言统一做法的开关：只给 crosscheck 用，正式输出永远是 True
USE_K9 = True
USE_NAIVE_MEAN = True

# 生成器真正读的参数键（params_from_doc 只看这些）。夹具和金样只绑定这些键（外加版本号 generator）的规范文本
# generator_params_sha256；产品旋钮不在里面——改 D1 的 max_pairs / max_user、S7 标定的银库 k（bank_delta_per_city）
# 不改变生成器输出，也不触发「生成器变了」的门禁。GDScript 版 TradeGenV1.GENERATOR_KEYS 必须与这里逐项相同。
GENERATOR_KEYS = ("price_coef", "appear", "max_count", "silk_slots", "silk_price_by_deck", "silk_price_global",
                  "q_multiset", "q_pattern_by_s_rank", "s_templates", "unit_floor", "n_local_single", "forced_min",
                  "rank_jitter", "no_silver_cards", "near_source_steps", "near_source_silver_cap", "loop_cap_one_way",
                  "loop_cap_two_way", "loop_cap_eps", "loop_guard_max_iter", "turns_table")
# 产品旋钮：params 命令从现有参数文件原样拷贝（没有文件时用下面的默认值），不在这里写死；params --check 只核对取值范围。
#   max_pairs / max_user：D1（任务给的默认是两对）；bank_delta_per_city：R20 的 k，默认 0，只在 S7 标定时按人数调；
#   topology_rules：接法规则的记录，必须与本文件 enumerate_topologies 用的常量相同（改规则要一起改代码）。
PRODUCT_KEYS = ("bank_delta_per_city", "max_pairs", "max_user", "topology_rules")
TOPOLOGY_RULES = {"host_max_degree_before": 3, "pair_min_host_steps": 9, "pair_sym_max": 2.0,
                  "map_mid_x": MAP_MID_X, "corridor_steps": 3}
PRODUCT_DEFAULTS = {"bank_delta_per_city": {"2": 0, "3": 0, "4": 0}, "max_pairs": 2, "max_user": 2,
                    "topology_rules": TOPOLOGY_RULES}
BANK_K_ALLOWED = (0, -1, -2, -3, -4)
# 金样文件名跟着版本号走（tradegen_v1 → golden_v1.json）。发布过的版本冻结保留（R19）：金样一旦写出就不覆盖，
# 生成器输出或生成器参数变了只能出新版本（改 VERSION，另起 trade_gen_v2.gd），新版本写自己的 golden_v2.json。
GOLDEN_NAME = "golden_%s.json" % VERSION.rsplit("_", 1)[-1]


def stable_hash(*parts) -> int:
    h = hashlib.sha1("\x1f".join(str(p) for p in parts).encode("utf-8")).hexdigest()
    return int(h[:12], 16)


def round_half_up(x: float) -> int:
    return int(math.floor(x + 0.5))


def k9(x) -> int:
    """浮点排序键按 1e-9 取整后再比较（DESIGN 3.14.5）：floor(x·1e9 + 0.5)，两种语言同一串 IEEE 运算。"""
    if not USE_K9:
        return x
    return int(math.floor(x * 1e9 + 0.5))


def gmean(xs) -> float:
    """生成路径里的均值：从左到右求和再除以个数（整数先按整数求和）。GDScript 版写法相同。"""
    xs = list(xs)
    if not USE_NAIVE_MEAN:
        return statistics.mean(xs)
    s = 0
    for x in xs:
        s = s + x
    return s / len(xs)


# ---------------------------------------------------------------------------
# 棋盘
# ---------------------------------------------------------------------------

class Board:
    """节点 + 边 + 城市交通属性。只用于算步数，不关心坐标。"""

    def __init__(self):
        self.nodes: dict[str, dict] = {}
        self.edges: list[tuple[str, str, str]] = []

    @staticmethod
    def from_ruleset(rdir: Path = RULESET_DIR) -> "Board":
        b = Board()
        cities = {c["id"]: c for c in json.load(open(rdir / "cities.json"))["items"]}
        for n in json.load(open(rdir / "board_nodes.json"))["items"]:
            cid = n.get("city_id")
            if n["node_type"] == "CITY":
                c = cities[cid]
                b.nodes[n["id"]] = {
                    "kind": "CITY", "city_id": cid,
                    "routes": set(c["allowed_routes"]),
                    "interchange": bool(c["is_transport_interchange"]),
                }
            else:
                b.nodes[n["id"]] = {"kind": "ROAD", "city_id": None, "routes": set(), "interchange": False}
        for e in json.load(open(rdir / "board_edges.json"))["items"]:
            b.edges.append((e["a"], e["b"], e["route_type"]))
            for end in (e["a"], e["b"]):
                if b.nodes[end]["kind"] == "ROAD":
                    b.nodes[end]["routes"].add(e["route_type"])
        return b

    def cities(self) -> list[str]:
        return sorted(n["city_id"] for n in self.nodes.values() if n["kind"] == "CITY")

    def city_node(self, city_id: str) -> str:
        for nid, n in self.nodes.items():
            if n["city_id"] == city_id:
                return nid
        raise KeyError(city_id)

    def with_leaf(self, city_id: str, anchor_city: str, route: str, allow_existing: bool = False) -> "Board":
        """新城只做叶子：1 条新商道（2 个新道路点、3 条新边）接到 1 座已有城市；新城不是换乘城。
        商道 id = <land|sea>_<宿主>_<新城 id>，与 DESIGN 3.4 的 land_changan_x_e1 相同。"""
        if route not in (LAND, SEA):
            raise ValueError("route must be LAND or SEA")
        exists = any(n["city_id"] == city_id for n in self.nodes.values())
        if exists and not allow_existing:
            raise ValueError("city id already on board: %s" % city_id)
        if exists and self.nodes[self.city_node(city_id)]["routes"] != {route}:
            raise ValueError("extra connection must use the city's transport")
        anchor = self.city_node(anchor_city)
        if route not in self.nodes[anchor]["routes"]:
            raise ValueError("anchor %s has no %s access (allowed %s)" % (anchor_city, route, sorted(self.nodes[anchor]["routes"])))
        b = copy.deepcopy(self)
        pre = "%s_%s_%s" % (route.lower(), anchor_city, city_id)
        r1, r2 = pre + "_01", pre + "_02"
        if r1 in b.nodes or r2 in b.nodes:
            raise ValueError("duplicate corridor: %s" % pre)
        if not exists:
            b.nodes[city_id] = {"kind": "CITY", "city_id": city_id, "routes": {route}, "interchange": False}
        b.nodes[r1] = {"kind": "ROAD", "city_id": None, "routes": {route}, "interchange": False}
        b.nodes[r2] = {"kind": "ROAD", "city_id": None, "routes": {route}, "interchange": False}
        b.edges += [(anchor, r1, route), (r1, r2, route), (r2, city_id, route)]
        return b

    def city_distances(self) -> dict[str, dict[str, int]]:
        """交通规则下的城市间最短步数：状态 = (节点, 交通)，只有换乘城能 0 步换乘。"""
        adj = defaultdict(list)
        for a, b, t in self.edges:
            adj[a].append((b, t))
            adj[b].append((a, t))
        out = {}
        city_nodes = {nid: n["city_id"] for nid, n in self.nodes.items() if n["kind"] == "CITY"}
        for src, src_city in city_nodes.items():
            dist = {}
            dq = deque()
            for t in sorted(self.nodes[src]["routes"]):
                dist[(src, t)] = 0
                dq.append((src, t))
            while dq:
                u, t = dq.popleft()
                du = dist[(u, t)]
                if self.nodes[u]["interchange"]:
                    for t2 in (LAND, SEA):
                        if t2 != t and t2 in self.nodes[u]["routes"] and du < dist.get((u, t2), math.inf):
                            dist[(u, t2)] = du
                            dq.appendleft((u, t2))
                for v, et in adj[u]:
                    if et != t:
                        continue
                    if du + 1 < dist.get((v, t), math.inf):
                        dist[(v, t)] = du + 1
                        dq.append((v, t))
            row = {}
            for nid, cid in city_nodes.items():
                ds = [d for (n, _t), d in dist.items() if n == nid]
                if ds:
                    row[cid] = min(ds)
            out[src_city] = row
        return out

    def degree(self, city_id: str) -> int:
        nid = self.city_node(city_id)
        return sum(1 for a, b, _t in self.edges if a == nid or b == nid)


# ---------------------------------------------------------------------------
# 经济数据（货物、产地、牌堆）
# ---------------------------------------------------------------------------

class Economy:
    def __init__(self):
        self.goods: dict[str, int] = {}            # good -> supply
        self.good_names: dict[str, str] = {}
        self.producer: dict[str, str] = {}         # good -> producing city
        self.specialty: dict[str, str | None] = {} # city -> good (None = 白银起始)
        self.start_silver: dict[str, int] = {}
        self.city_names: dict[str, str] = {}
        self.decks: list[dict] = []                # {id, city_ids, cards:[{id, card_number, entries}]}
        self.city_deck: dict[str, str] = {}

    @staticmethod
    def from_ruleset(rdir: Path = RULESET_DIR) -> "Economy":
        e = Economy()
        for g in json.load(open(rdir / "goods.json"))["items"]:
            e.goods[g["id"]] = int(g["supply_total"])
            e.good_names[g["id"]] = g["display_name"]
        for c in json.load(open(rdir / "cities.json"))["items"]:
            e.city_names[c["id"]] = c["display_name"]
            e.city_deck[c["id"]] = c["trade_color_id"]
        for cc in json.load(open(rdir / "city_cards.json"))["items"]:
            ent = cc["starting_grant"]["entries"][0]
            if ent["resource_kind"] == "GOOD":
                e.specialty[cc["city_id"]] = ent["resource_id"]
                e.producer[ent["resource_id"]] = cc["city_id"]
            else:
                e.specialty[cc["city_id"]] = None
                e.start_silver[cc["city_id"]] = int(ent["quantity"])
        for d in json.load(open(rdir / "trade_decks.json"))["decks"]:
            e.decks.append({"id": d["id"], "city_ids": list(d["city_ids"]), "cards": copy.deepcopy(d["cards"])})
        return e

    def deck(self, deck_id: str) -> dict:
        return next(d for d in self.decks if d["id"] == deck_id)

    def add_city(self, city_id: str, name: str, specialty: str, specialty_name: str, supply: int = 10) -> None:
        if specialty in self.goods:
            raise ValueError("新特产必须是新货物（不能与原版 15 种或已有新货重复）：%s" % specialty)
        self.goods[specialty] = supply
        self.good_names[specialty] = specialty_name
        self.producer[specialty] = city_id
        self.specialty[city_id] = specialty
        self.city_names[city_id] = name


# ---------------------------------------------------------------------------
# 卡面读取工具
# ---------------------------------------------------------------------------

def card_silver(card) -> int | None:
    s = [e["quantity"] for e in card["entries"] if e["resource_kind"] == "SILVER"]
    return s[0] if s else None


def deck_locals(econ: Economy, city_ids) -> list[str]:
    return [econ.specialty[c] for c in city_ids if econ.specialty.get(c)]


def good_distance(econ: Economy, D, city_ids, good) -> int | None:
    if good not in econ.producer:
        return None
    return min(D[c][econ.producer[good]] for c in city_ids)


def card_foreign(econ: Economy, D, deck, card):
    """返回 (外地有产地×1 货的距离列表, 丝绸格数, 是否含本地特产格)"""
    locs = set(deck_locals(econ, deck["city_ids"]))
    ds, nsilk, has_local = [], 0, False
    for e in card["entries"]:
        if e["resource_kind"] != "GOOD":
            continue
        g = e["resource_id"]
        if g in locs:
            has_local = True
        elif g == "silk" or g not in econ.producer:
            nsilk += 1
        elif e["quantity"] == 1:
            ds.append(good_distance(econ, D, deck["city_ids"], g))
    return ds, nsilk, has_local


# ---------------------------------------------------------------------------
# 参数拟合（只在导出冻结参数、留一回测时用；运行时永远读冻结文件，不再拟合）
# ---------------------------------------------------------------------------

def lstsq(X, Y):
    n = len(X[0])
    A = [[sum(x[i] * x[j] for x in X) for j in range(n)] + [sum(x[i] * y for x, y in zip(X, Y))] for i in range(n)]
    for i in range(n):
        p = max(range(i, n), key=lambda r: abs(A[r][i]))
        A[i], A[p] = A[p], A[i]
        for r in range(n):
            if r != i and A[i][i] != 0:
                f = A[r][i] / A[i][i]
                for k in range(i, n + 1):
                    A[r][k] -= f * A[i][k]
    return [A[i][n] / A[i][i] for i in range(n)]


def isotonic_increasing(xs, ws):
    """带权保序回归（PAV），用于"越远出现次数越多"。"""
    blocks = [[x, w, 1] for x, w in zip(xs, ws)]
    i = 0
    while i < len(blocks) - 1:
        if blocks[i][0] > blocks[i + 1][0]:
            a, b = blocks[i], blocks[i + 1]
            w = a[1] + b[1]
            blocks[i] = [(a[0] * a[1] + b[0] * b[1]) / w, w, a[2] + b[2]]
            del blocks[i + 1]
            i = max(i - 1, 0)
        else:
            i += 1
    out = []
    for v, _w, k in blocks:
        out += [v] * k
    return out


class Params:
    pass


def fit_params(econ: Economy, D, deck_ids) -> Params:
    """与 deck_gen.py 的 fit_params 逐行相同（拟合只在 Python 里做，结果冻结成 JSON）。"""
    P = Params()
    decks = [econ.deck(d) for d in deck_ids]
    X, Y = [], []
    for dk in decks:
        for card in dk["cards"]:
            S = card_silver(card)
            if S is None:
                continue
            ds, _ns, has_local = card_foreign(econ, D, dk, card)
            if not ds:
                continue
            X.append([1.0, statistics.mean(ds), 1.0 if has_local else 0.0])
            Y.append(S)
    P.price_coef = lstsq(X, Y)
    by_d = defaultdict(list)
    for dk in decks:
        cnt = Counter(e["resource_id"] for c in dk["cards"] for e in c["entries"] if e["resource_kind"] == "GOOD")
        for g, pc in econ.producer.items():
            if pc in dk["city_ids"]:
                continue
            by_d[good_distance(econ, D, dk["city_ids"], g)].append(cnt[g])
    ks = sorted(by_d)
    iso = isotonic_increasing([statistics.mean(by_d[k]) for k in ks], [len(by_d[k]) for k in ks])
    P.appear = dict(zip(ks, iso))
    P.max_count = max(max(v) for v in by_d.values())
    silk_slots = [sum(1 for c in dk["cards"] for e in c["entries"] if e["resource_id"] == "silk") for dk in decks]
    P.silk_slots = round_half_up(statistics.median(silk_slots))
    P.silk_price_by_deck = {}
    for dk in decks:
        v = [card_silver(c) for c in dk["cards"] if card_silver(c) is not None and any(e["resource_id"] == "silk" and e["quantity"] == 1 for e in c["entries"])]
        if v:
            P.silk_price_by_deck[dk["id"]] = statistics.mean(v)
    P.silk_price_global = statistics.mean(P.silk_price_by_deck.values())
    multisets = Counter()
    joint = Counter()
    for dk in decks:
        for L in deck_locals(econ, dk["city_ids"]):
            qs = []
            for c in dk["cards"]:
                for e in c["entries"]:
                    if e["resource_id"] == L:
                        qs.append(e["quantity"])
                        S = card_silver(c)
                        if S is not None:
                            joint[(S, e["quantity"])] += 1
            if len(qs) == 5:
                multisets[tuple(sorted(qs))] += 1
    P.q_multiset = list(multisets.most_common(1)[0][0])
    best = None
    for perm in sorted(set(itertools.permutations(P.q_multiset))):
        score = 0.0
        s_sorted = sorted(S for (S, q), n in joint.items() for _ in range(n))
        for i, q in enumerate(perm):
            S = s_sorted[min(len(s_sorted) - 1, int((i + 0.5) / len(perm) * len(s_sorted)))]
            num = joint.get((S, q), 0) + 0.5
            den = sum(n for (s2, _q), n in joint.items() if s2 == S) + 0.5 * 3
            score += math.log(num / den)
        if best is None or score > best[0] + 1e-12:
            best = (score, perm)
    P.q_pattern_by_s_rank = list(best[1])
    P.s_templates = []
    for dk in decks:
        sv = sorted(card_silver(c) for c in dk["cards"] if card_silver(c) is not None)
        P.s_templates.append((statistics.mean(sv), sv, dk["id"], len(dk["cards"]) - len(sv)))
    P.s_templates.sort()
    P.unit_floor = min(card_silver(c) / e["quantity"] for dk in decks for c in dk["cards"] if card_silver(c) is not None
                       for e in c["entries"] if e["resource_id"] in deck_locals(econ, dk["city_ids"]))
    P.n_local_single = 5
    P.forced_min = 3
    P.rank_jitter = 1.5
    P.no_silver_cards = 0
    P.train = list(deck_ids)
    return P


def predict_price(P: Params, dbar: float, is_local: bool) -> float:
    a, b, c = P.price_coef
    return a + b * dbar + (c if is_local else 0.0)


def template_values(P: Params, mu: float, n: int, no_silver: int = 0) -> tuple[list[int], str]:
    """按预测价位 mu 选最接近的原版白银分布模板（并列取较低的），按分位重采样到 n 张。
    只用"无银卡张数"相同的原版牌堆当模板。"""
    pool = [t for t in P.s_templates if t[3] == no_silver] or P.s_templates
    mean, sv, src, _k = min(pool, key=lambda t: (k9(abs(t[0] - mu)), k9(t[0])))
    return [sv[min(len(sv) - 1, int((k + 0.5) / n * len(sv)))] for k in range(n)], src


def virtual_distance(P: Params, price: float, is_local: bool) -> float:
    a, b, c = P.price_coef
    return (price - a - (c if is_local else 0.0)) / b


def appear_target(P: Params, d: int) -> float:
    ks = sorted(P.appear)
    if d <= ks[0]:
        return P.appear[ks[0]]
    if d >= ks[-1]:
        return P.appear[ks[-1]]
    lo = max(k for k in ks if k <= d)
    hi = min(k for k in ks if k >= d)
    if lo == hi:
        return P.appear[lo]
    t = (d - lo) / (hi - lo)
    return P.appear[lo] * (1 - t) + P.appear[hi] * t


# ---------------------------------------------------------------------------
# 冻结参数：导出 / 读取
# ---------------------------------------------------------------------------

def f64_hex(x: float) -> str:
    """IEEE 754 双精度的 8 个字节（小端）写成 16 位十六进制；GDScript 用 hex_decode().decode_double(0) 还原。"""
    return struct.pack("<d", float(x)).hex()


def f64_from_hex(h: str) -> float:
    return struct.unpack("<d", bytes.fromhex(h))[0]


def move_budget_distribution(rdir: Path = RULESET_DIR) -> dict[int, float]:
    """每回合最多能走几步的分布（与 deck_gen.py 相同）：骰面 1–5 各 1/6；事件面 1/6，抽到"移动 0–N 步"的事件就最多走 N 步。
    陆、海两副事件牌分别统计后取平均。字典的插入顺序参与浮点求和，冻结时按这个顺序写出。"""
    rs = json.load(open(rdir / "ruleset.json"))
    faces = rs["dice_faces"]
    ev = json.load(open(rdir / "event_definitions.json"))["items"]
    dist = Counter()
    pf = 1.0 / len(faces)
    for f in faces:
        if isinstance(f, int):
            dist[f] += pf
        else:
            for deck_type in ("LAND", "SEA"):
                cards = [e for e in ev if e["deck_type"] == deck_type]
                for e in cards:
                    k = 0
                    for eff in e["effects"]:
                        if eff["op"] == "MOVE_BY_RANGE":
                            k = int(eff["max_steps"])
                    dist[k] += pf * 0.5 / len(cards)
    return dict(dist)


def expected_turns_table(max_d: int, budget) -> list[float]:
    """T[d] = 走完 d 步平均要几回合（每回合可走 0..N 步，到城就停）。budget 是 [(k, p)] 或 dict，按给定顺序求和。"""
    items = list(budget.items()) if isinstance(budget, dict) else [tuple(x) for x in budget]
    p0 = 0.0
    for k, pk in items:
        if k == 0:
            p0 = pk
    T = [0.0] * (max_d + 1)
    for d in range(1, max_d + 1):
        acc = 1.0
        for k, pk in items:
            if k >= 1:
                acc += pk * T[max(0, d - k)]
        T[d] = acc / (1.0 - p0)
    return T


def market_offers(econ: Economy, deck: dict) -> dict[str, list[tuple[int, int, str]]]:
    """每种货在这一堆里能按什么比例和白银互换：[(S, q, card_id)]。"""
    out = defaultdict(list)
    for c in deck["cards"]:
        S = card_silver(c)
        if S is None:
            continue
        for e in c["entries"]:
            if e["resource_kind"] == "GOOD":
                out[e["resource_id"]].append((S, e["quantity"], c["id"]))
    return out


def load_profit(buy, sell) -> tuple[int, int]:
    """在 buy 卡用白银买满 4 格货仓、到 sell 卡按牌面卖出；余下不够一份的按直售 1 银/件。返回 (利润, 本金)。"""
    Sb, qb, _ = buy
    Ss, qs, _ = sell
    times = WAREHOUSE // qb
    units, cost = times * qb, times * Sb
    t2 = units // qs
    revenue = t2 * Ss + (units - t2 * qs)
    return revenue - cost, cost


def all_loops(econ: Economy, D, T, city_filter=None) -> list[dict]:
    """所有"甲城买、乙城卖"的单程循环（空车回程）：利润 / (2·T[d])。只算两张牌同时翻开时的最好情况。"""
    offers = {d["id"]: market_offers(econ, d) for d in econ.decks}
    deck_of = econ.city_deck
    cities = sorted(c for c in deck_of if c in D)
    loops = []
    for A in cities:
        oa = offers[deck_of[A]]
        for B in cities:
            if A == B:
                continue
            if city_filter and not city_filter(A, B):
                continue
            ob = offers[deck_of[B]]
            d = D[A][B]
            for g, buys in oa.items():
                sells = ob.get(g)
                if not sells:
                    continue
                best, nb, ns, cost, arg = None, set(), set(), 0, None
                for bo in buys:
                    for so in sells:
                        if deck_of[A] == deck_of[B] and bo[2] == so[2]:
                            continue  # 同一堆的两座城同时翻开的是两张不同的卡
                        pr, c0 = load_profit(bo, so)
                        if best is None or pr > best:
                            best, nb, ns, cost, arg = pr, {bo[2]}, {so[2]}, c0, (bo[2], so[2])
                        elif pr == best:
                            nb.add(bo[2]); ns.add(so[2])
                if best is None or best <= 0:
                    continue
                cyc = 2 * T[d]
                loops.append({"buy": A, "sell": B, "good": g, "d": d, "profit": best, "cost": cost,
                              "turns": cyc, "rate": best / cyc, "avail": len(nb) / 10 * len(ns) / 10,
                              "buy_card": arg[0], "sell_card": arg[1]})
    loops.sort(key=lambda x: (-k9(x["rate"]), -x["profit"], x["buy"], x["sell"], x["good"]))
    return loops


def two_way_loops(one_way: list[dict], T) -> list[dict]:
    """往返都装货：甲→乙卖一趟、在乙多停 1 回合买乙的货、回甲卖、在甲多停 1 回合买。周期 2·T[d]+2。"""
    best = {}
    for l in one_way:
        k = (l["buy"], l["sell"])
        if k not in best or l["profit"] > best[k]["profit"]:
            best[k] = l
    out = []
    for (A, B), l1 in best.items():
        if A >= B or (B, A) not in best:
            continue
        l2 = best[(B, A)]
        cyc = 2 * T[l1["d"]] + 2
        out.append({"a": A, "b": B, "d": l1["d"], "good_ab": l1["good"], "good_ba": l2["good"],
                    "profit": l1["profit"] + l2["profit"], "turns": cyc, "rate": (l1["profit"] + l2["profit"]) / cyc,
                    "avail": l1["avail"] * l2["avail"]})
    out.sort(key=lambda x: (-k9(x["rate"]), x["a"], x["b"]))
    return out


def export_params() -> dict:
    """从原版 80 张卡拟合，写成冻结参数（readable 值给人看；f64 段是每个浮点的 IEEE 位，两种语言都以它为准）。"""
    econ = Economy.from_ruleset()
    board = Board.from_ruleset()
    D = board.city_distances()
    P = fit_params(econ, D, [d["id"] for d in econ.decks])
    budget = move_budget_distribution()
    budget_items = [[int(k), float(v)] for k, v in budget.items()]
    T = expected_turns_table(60, budget_items)
    L = all_loops(econ, D, T)
    W = two_way_loops(L, T)
    cap1, cap2 = L[0]["rate"], W[0]["rate"]
    doc = {
        "generator": VERSION,
        "note": "tradegen_v1 冻结参数（DESIGN 3.14.2）。由 tools/custom_map/ref/deck_gen_ref.py params 从原版 80 张卡拟合写出；"
                "运行时只读、不再拟合。f64 段是每个浮点数的 IEEE 754 位（小端 16 位十六进制），两种语言都以它为准。",
        "ruleset_id": "lshu_configurable_v1",
        "price_coef": list(P.price_coef),
        "appear": {str(k): v for k, v in sorted(P.appear.items())},
        "max_count": int(P.max_count),
        "silk_slots": int(P.silk_slots),
        "silk_price_by_deck": {k: P.silk_price_by_deck[k] for k in sorted(P.silk_price_by_deck)},
        "silk_price_global": P.silk_price_global,
        "q_multiset": list(P.q_multiset),
        "q_pattern_by_s_rank": list(P.q_pattern_by_s_rank),
        "s_templates": [{"mean": m, "values": list(sv), "deck": src, "no_silver": k} for m, sv, src, k in P.s_templates],
        "unit_floor": P.unit_floor,
        "n_local_single": P.n_local_single,
        "forced_min": P.forced_min,
        "rank_jitter": P.rank_jitter,
        "no_silver_cards": P.no_silver_cards,
        "near_source_steps": 6,
        "near_source_silver_cap": 3,
        "loop_cap_one_way": cap1,
        "loop_cap_two_way": cap2,
        "loop_cap_eps": 1e-9,
        "loop_guard_max_iter": 60,
        "move_budget": budget_items,
        "turns_table": T,
    }
    doc.update(product_knobs())
    doc["f64"] = collect_f64(doc)
    return doc


def product_knobs() -> dict:
    """产品旋钮从现有参数文件原样拷贝（没有文件、或缺某一项时用默认值），不重新写死。"""
    cur = json.loads(PARAMS_PATH.read_text(encoding="utf-8")) if PARAMS_PATH.exists() else {}
    return {k: copy.deepcopy(cur.get(k, PRODUCT_DEFAULTS[k])) for k in PRODUCT_KEYS}


def check_product_knobs(doc: dict) -> list[str]:
    """产品旋钮的取值范围：max_pairs ∈ {1, 2}、1 ≤ max_user ≤ max_pairs、k 按人数 2/3/4 各一个且 ∈ {0, −1, …, −4}（R20）、
    topology_rules 与接法枚举常量相同。"""
    bad = []
    mp, mu = doc.get("max_pairs"), doc.get("max_user")
    if not (isinstance(mp, int) and not isinstance(mp, bool) and mp in (1, 2)):
        bad.append("max_pairs 必须是 1 或 2：%r" % (mp,))
    if not (isinstance(mu, int) and not isinstance(mu, bool) and isinstance(mp, int) and 1 <= mu <= mp):
        bad.append("max_user 必须是 1 到 max_pairs 之间的整数：%r" % (mu,))
    k = doc.get("bank_delta_per_city")
    if not isinstance(k, dict) or sorted(k) != ["2", "3", "4"]:
        bad.append("bank_delta_per_city 必须恰好有 \"2\"、\"3\"、\"4\" 三个键：%r" % (k,))
    else:
        for n, v in sorted(k.items()):
            if not (isinstance(v, int) and not isinstance(v, bool) and v in BANK_K_ALLOWED):
                bad.append("bank_delta_per_city[%s] 必须 ∈ %s：%r" % (n, list(BANK_K_ALLOWED), v))
    if doc.get("topology_rules") != TOPOLOGY_RULES:
        bad.append("topology_rules 与 enumerate_topologies 的常量不一致：%r" % (doc.get("topology_rules"),))
    return bad


def generator_doc(doc: dict) -> dict:
    """参数文档里只留生成器读的键（外加版本号 generator），f64 段也只留这些键下面的路径。"""
    keep = ("generator",) + GENERATOR_KEYS
    out = {k: doc[k] for k in keep if k in doc}
    out["f64"] = {p: h for p, h in doc.get("f64", {}).items() if p.split("/")[0] in keep}
    return out


def _neutral_numbers(v):
    """跨语言中立的数：整数值写成整数，非整数写成 "f64:<IEEE 位>"。Godot 解析 JSON 的数一律是浮点，Python 分 int / float，
    两边按这条规则写出来才能逐字节相同（非整数先经 apply_f64 取到位级精确值）。"""
    if isinstance(v, bool) or v is None or isinstance(v, str):
        return v
    if isinstance(v, (int, float)):
        x = float(v)
        if x == math.floor(x) and abs(x) < 2 ** 53:
            return int(x)
        return "f64:" + f64_hex(x)
    if isinstance(v, dict):
        return {str(k): _neutral_numbers(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_neutral_numbers(x) for x in v]
    raise TypeError(type(v))


def generator_params_sha256(doc: dict) -> str:
    """夹具和金样绑定的参数指纹：只覆盖生成器读的键（GENERATOR_KEYS + generator）。GDScript 版 TradeGenV1 同名函数逐字节相同。"""
    d = apply_f64(generator_doc(doc))
    d.pop("f64", None)
    return sha256_text(canon(_neutral_numbers(d)))


def collect_f64(doc) -> dict:
    """把文档里每个 float 的位写成 {路径: 十六进制}；路径用 / 连接（数组下标、字典键）。"""
    out = {}

    def walk(v, path):
        if isinstance(v, bool):
            return
        if isinstance(v, float):
            out[path] = f64_hex(v)
        elif isinstance(v, dict):
            for k in v:
                if k in ("f64", "note"):
                    continue
                walk(v[k], k if not path else path + "/" + k)
        elif isinstance(v, list):
            for i, x in enumerate(v):
                walk(x, str(i) if not path else path + "/" + str(i))

    walk(doc, "")
    return out


def apply_f64(doc: dict) -> dict:
    """读冻结参数：按 f64 段把每个浮点换成位级精确值（Python 的 json 本来就能精确往返，这里与 GDScript 走同一条路）。"""
    doc = copy.deepcopy(doc)
    for path, hx in doc.get("f64", {}).items():
        parts = path.split("/")
        cur = doc
        for p in parts[:-1]:
            cur = cur[int(p)] if isinstance(cur, list) else cur[p]
        last = parts[-1]
        val = f64_from_hex(hx)
        if isinstance(cur, list):
            cur[int(last)] = val
        else:
            cur[last] = val
    return doc


def params_from_doc(doc: dict) -> Params:
    # 生成器只看得见 GENERATOR_KEYS：产品旋钮怎么改都进不了生成器
    doc = apply_f64(generator_doc(doc))
    P = Params()
    P.price_coef = list(doc["price_coef"])
    P.appear = {int(k): v for k, v in doc["appear"].items()}
    P.max_count = int(doc["max_count"])
    P.silk_slots = int(doc["silk_slots"])
    P.silk_price_by_deck = dict(doc["silk_price_by_deck"])
    P.silk_price_global = doc["silk_price_global"]
    P.q_multiset = [int(x) for x in doc["q_multiset"]]
    P.q_pattern_by_s_rank = [int(x) for x in doc["q_pattern_by_s_rank"]]
    P.s_templates = [(t["mean"], [int(x) for x in t["values"]], t["deck"], int(t["no_silver"])) for t in doc["s_templates"]]
    P.unit_floor = doc["unit_floor"]
    P.n_local_single = int(doc["n_local_single"])
    P.forced_min = int(doc["forced_min"])
    P.rank_jitter = doc["rank_jitter"]
    P.no_silver_cards = int(doc["no_silver_cards"])
    P.near_source_steps = int(doc.get("near_source_steps", 6))
    P.near_source_silver_cap = int(doc.get("near_source_silver_cap", 3))
    P.loop_cap_one_way = doc.get("loop_cap_one_way")
    P.loop_cap_two_way = doc.get("loop_cap_two_way")
    P.loop_cap_eps = doc.get("loop_cap_eps", 1e-9)
    P.loop_guard_max_iter = int(doc.get("loop_guard_max_iter", 60))
    P.turns_table = list(doc.get("turns_table", []))
    return P


def params_to_doc_loo(P: Params) -> dict:
    """留一回测用的参数（只含生成一堆需要的字段），同样带 f64 段。"""
    doc = {
        "price_coef": list(P.price_coef),
        "appear": {str(k): v for k, v in sorted(P.appear.items())},
        "max_count": int(P.max_count),
        "silk_slots": int(P.silk_slots),
        "silk_price_by_deck": {k: P.silk_price_by_deck[k] for k in sorted(P.silk_price_by_deck)},
        "silk_price_global": P.silk_price_global,
        "q_multiset": list(P.q_multiset),
        "q_pattern_by_s_rank": list(P.q_pattern_by_s_rank),
        "s_templates": [{"mean": m, "values": list(sv), "deck": src, "no_silver": k} for m, sv, src, k in P.s_templates],
        "unit_floor": P.unit_floor,
        "n_local_single": P.n_local_single,
        "forced_min": P.forced_min,
        "rank_jitter": P.rank_jitter,
        "no_silver_cards": P.no_silver_cards,
    }
    doc["f64"] = collect_f64(doc)
    return doc


_FROZEN = None


def frozen_params() -> Params:
    global _FROZEN
    if _FROZEN is None:
        _FROZEN = params_from_doc(json.load(open(PARAMS_PATH, encoding="utf-8")))
    return _FROZEN


# ---------------------------------------------------------------------------
# 生成器
# ---------------------------------------------------------------------------

def silk_target_price(P: Params, econ: Economy, D, city_ids, exclude_deck=None) -> float:
    """丝绸价格按"邻堆"取：本堆城市 3 步内的其它城市所在牌堆的丝绸均价；新叶子城只有宿主这一个邻居。"""
    neigh = set()
    for c in city_ids:
        for o, d in D[c].items():
            if d == 3 and o not in city_ids and o in econ.city_deck:
                dk = econ.city_deck[o]
                if dk != exclude_deck and dk in P.silk_price_by_deck:
                    neigh.add(dk)
    if not neigh:
        return P.silk_price_global
    return gmean(P.silk_price_by_deck[d] for d in sorted(neigh))


def fill_cards(queue: list[str], needs: list[int], deck_id: str) -> list[list[str]]:
    """按队列顺序装卡：同一张卡不放同一种货；整张卡的外地货组合不与已有卡重复。
    贪心装到卡不下时，和前面的卡交换一格（从最近的卡往前找）来修复。确定性。"""
    queue = list(queue)
    cards: list[list[str]] = []

    def ok(card):
        return len(set(card)) == len(card)

    def sig_clash(card, idx):
        f = frozenset(card)
        return any(j != idx and len(c) == len(card) and frozenset(c) == f for j, c in enumerate(cards))

    for need in needs:
        got: list[str] = []
        cards.append(got)
        idx = len(cards) - 1
        while len(got) < need:
            placed = False
            for i, g in enumerate(queue):
                if g in got:
                    continue
                if len(got) == need - 1 and sig_clash(got + [g], idx):
                    continue
                got.append(queue.pop(i))
                placed = True
                break
            if placed:
                continue
            if not queue:
                raise RuntimeError("装卡失败（格数不够）：%s" % deck_id)
            g = queue[0]
            done = False
            for j in range(idx - 1, -1, -1):
                c = cards[j]
                for k, x in enumerate(c):
                    if x == g or x in got or g in c:
                        continue
                    c2 = c[:k] + [g] + c[k + 1:]
                    got2 = got + [x]
                    if not ok(c2) or not ok(got2):
                        continue
                    cards[j] = c2
                    if sig_clash(c2, j) or (len(got2) == need and sig_clash(got2, idx)):
                        cards[j] = c
                        continue
                    queue.pop(0)
                    got.append(x)
                    done = True
                    break
                if done:
                    break
            if not done:
                raise RuntimeError("装卡失败：%s" % deck_id)
    return cards


def generate_deck(econ: Economy, D, P: Params, deck_id: str, city_ids: list[str],
                  forced: dict[str, int] | None = None, exclude_deck_for_silk: str | None = None,
                  foreign_pool: list[str] | None = None, spread: str = "template", no_silver: int = 0) -> dict:
    """生成 10 张卡（DESIGN 3.14.3 第 3–9、12 步）。forced = {货物: 最少出现次数}（搭档新城的特产）。"""
    forced = dict(forced or {})
    locs = deck_locals(econ, city_ids)
    if len(locs) > 2:
        raise ValueError("一堆最多 2 种特产")
    n_cards = 10
    if len(locs) == 2:
        types = ["L"] * 10
    elif len(locs) == 1:
        types = ["A"] * (n_cards - P.n_local_single) + ["L"] * P.n_local_single
    else:
        types = ["A"] * n_cards
    n_slots = sum(2 if t == "L" else 3 for t in types) + no_silver
    n_silk = P.silk_slots if "silk" in econ.goods else 0
    n_other = n_slots - n_silk

    # --- 外地货需求次数 ---
    pool = foreign_pool if foreign_pool is not None else sorted(g for g in econ.producer if econ.producer[g] not in city_ids)
    dist = {g: good_distance(econ, D, city_ids, g) for g in pool}
    if len(pool) > n_other:
        raise ValueError("外地货种类（%d）多于可用格数（%d）" % (len(pool), n_other))
    w = {g: appear_target(P, dist[g]) for g in pool}
    total_w = 0.0
    for g in pool:
        total_w = total_w + w[g]
    raw = {g: w[g] * n_other / total_w for g in pool}
    cnt = {g: max(1, forced.get(g, 1), min(P.max_count, int(math.floor(raw[g])))) for g in pool}
    guard = 0
    while sum(cnt.values()) < n_other and guard < 1000:
        cands = [g for g in sorted(pool, key=lambda g: (k9(cnt[g] - raw[g]), -dist[g], stable_hash(deck_id, g))) if cnt[g] < P.max_count]
        if not cands:
            cands = sorted(pool, key=lambda g: (k9(cnt[g] - raw[g]), -dist[g], stable_hash(deck_id, g)))
        cnt[cands[0]] += 1
        guard += 1
    while sum(cnt.values()) > n_other and guard < 2000:
        cands = [g for g in sorted(pool, key=lambda g: (k9(raw[g] - cnt[g]), dist[g], stable_hash(deck_id, g))) if cnt[g] > max(1, forced.get(g, 1))]
        cnt[cands[0]] -= 1
        guard += 1

    # --- 排队：按距离从远到近，丝绸按"虚拟距离"插队 ---
    silk_price = silk_target_price(P, econ, D, city_ids, exclude_deck_for_silk)
    slots = []
    for g in pool:
        for k in range(cnt[g]):
            slots.append((float(dist[g]), stable_hash(deck_id, g, k), g))
    vd_silk = virtual_distance(P, silk_price, is_local=("L" in types))
    for k in range(n_silk):
        slots.append((vd_silk, stable_hash(deck_id, "silk", k), "silk"))
    slots.sort(key=lambda s: (-k9(s[0]), s[1]))

    # --- 顺序装卡 ---
    queue = [s[2] for s in slots]
    L_positions = [i for i, t in enumerate(types) if t == "L"]
    barter = set(L_positions[len(L_positions) - no_silver:]) if no_silver else set()
    needs = [3 if (t == "A" or ci in barter) else 2 for ci, t in enumerate(types)]
    cards_goods = fill_cards(queue, needs, deck_id)

    # --- 卡价 ---
    cards = []
    for ci, (t, gs) in enumerate(zip(types, cards_goods)):
        ds = [dist[g] for g in gs if g != "silk"]
        dbar = gmean(ds) if ds else vd_silk
        pred = predict_price(P, dbar, t == "L")
        cards.append({"type": t, "goods": gs, "pred": pred, "dbar": dbar, "barter": ci in barter})
    priced = [i for i, c in enumerate(cards) if not c["barter"]]
    ranked = sorted(priced, key=lambda i: (k9(cards[i]["pred"] + P.rank_jitter * ((stable_hash(deck_id, "jit", i) % 1000) / 1000.0 - 0.5)),
                                           stable_hash(deck_id, "rank", i)))
    template_src = None
    if spread == "template":
        vals, template_src = template_values(P, gmean(cards[i]["pred"] for i in priced), len(priced), no_silver)
        for k, i in enumerate(ranked):
            cards[i]["S"] = vals[k]
    else:
        raise ValueError("tradegen_v1 只用 template 分配")
    for i, c in enumerate(cards):
        if c["barter"]:
            c["S"] = None

    # --- 本地特产卡：数量按"S 排名 -> q 图样" ---
    L_idx = [i for i, c in enumerate(cards) if c["type"] == "L"]
    L_sorted = sorted(L_idx, key=lambda i: (k9(cards[i]["pred"] if cards[i]["S"] is None else cards[i]["S"]), k9(cards[i]["dbar"]), stable_hash(deck_id, "L", i)))
    per_spec = {L: [] for L in locs}
    if len(locs) == 2:
        first = sorted(locs, key=lambda L: stable_hash(deck_id, L))
        for k, i in enumerate(L_sorted):
            per_spec[first[k % 2]].append(i)
    elif len(locs) == 1:
        per_spec[locs[0]] = list(L_sorted)
    for L, idxs in per_spec.items():
        pattern = P.q_pattern_by_s_rank
        if len(idxs) != len(pattern):
            pattern = [P.q_multiset[min(len(P.q_multiset) - 1, int((k + 0.5) / len(idxs) * len(P.q_multiset)))] for k in range(len(idxs))]
        for k, i in enumerate(idxs):
            q = pattern[k]
            S = cards[i]["S"]
            if S is not None:
                while q > 2 and S / q < P.unit_floor - 1e-9:
                    q -= 1
            cards[i]["local"] = (L, q)

    # --- 组装条目 ---
    out_cards = []
    order = sorted(range(len(cards)), key=lambda i: stable_hash(deck_id, "order", i))
    for n, i in enumerate(order, start=1):
        c = cards[i]
        gs = sorted(c["goods"], key=lambda g: (g == "silk", -(dist.get(g, 0)), g))
        ent = []
        if c["type"] == "L":
            L, q = c["local"]
            ent.append({"resource_kind": "GOOD", "resource_id": gs[0], "quantity": 1})
            ent.append({"resource_kind": "GOOD", "resource_id": L, "quantity": q})
            for g in gs[1:]:
                ent.append({"resource_kind": "GOOD", "resource_id": g, "quantity": 1})
        else:
            for g in gs:
                ent.append({"resource_kind": "GOOD", "resource_id": g, "quantity": 1})
        if c["S"] is not None:
            ent.append({"resource_kind": "SILVER", "resource_id": "silver", "quantity": c["S"]})
        out_cards.append({"id": "%s_card_%02d" % (deck_id, n), "card_number": n, "entries": ent})
    return {"id": deck_id, "city_ids": list(city_ids), "cards": out_cards,
            "_meta": {"silk_target_price": silk_price, "counts": cnt, "dist": dist, "template": template_src}}


# ---------------------------------------------------------------------------
# 近源封顶（R13，第 10 步）与循环护栏（R14，第 11 步）
# ---------------------------------------------------------------------------

def source_cities(econ: Economy, base_deck_ids: list[str], new_codes: dict[str, str]) -> dict[str, list[str]]:
    """货源城：一种货出现在哪一堆的整批格（数量 ≥ 2）里，那一堆的全部城都是它的货源城（丝绸不算）。
    例：沉香 → 真腊、大光。新特产（代号）的货源城就是它自己的新城。"""
    out: dict[str, set] = defaultdict(set)
    for dk_id in base_deck_ids:
        dk = econ.deck(dk_id)
        for c in dk["cards"]:
            for e in c["entries"]:
                if e["resource_kind"] == "GOOD" and e["resource_id"] != "silk" and int(e["quantity"]) >= 2:
                    out[e["resource_id"]] |= set(dk["city_ids"])
    for code, city in new_codes.items():
        out[code] = {city}
    return {g: sorted(v) for g, v in out.items()}


def near_source_good(P: Params, D, card: dict, city_id: str, own_code: str, sources: dict[str, list[str]]) -> str | None:
    """Same predicate as the existing initial cap, shared by guard and final reader."""
    for entry in card["entries"]:
        if entry["resource_kind"] != "GOOD":
            continue
        good = entry["resource_id"]
        if good == "silk" or good == own_code:
            continue
        origins = sources.get(good, [])
        if origins and min(D[city_id][origin] for origin in origins) <= P.near_source_steps:
            return good
    return None


def near_source_cap(P: Params, D, deck: dict, city_id: str, own_code: str, sources: dict[str, list[str]]) -> list[dict]:
    """一张卡上只要有一件外地货到货源城 ≤ near_source_steps 步（丝绸、本城特产不算），这张卡白银 S ≤ near_source_silver_cap；
    特产卡同时把数量调到 S/q ≥ 2/3。就地修改 deck，返回改动记录。"""
    log = []
    for card in deck["cards"]:
        near = near_source_good(P, D, card, city_id, own_code, sources)
        if near is None:
            continue
        silver = next((e for e in card["entries"] if e["resource_kind"] == "SILVER"), None)
        if silver is None or silver["quantity"] <= P.near_source_silver_cap:
            continue
        silver["quantity"] = P.near_source_silver_cap
        for e in card["entries"]:
            if e["resource_kind"] == "GOOD" and e["resource_id"] == own_code:
                q = e["quantity"]
                while q > 2 and silver["quantity"] / q < P.unit_floor - 1e-9:
                    q -= 1
                e["quantity"] = q
        log.append({"deck": deck["id"], "card": card["id"], "good": near})
    return log


def near_source_silver_limits(econ: Economy, D, new_ids: list[str], P: Params) -> dict[str, int]:
    """Keep the original bulk-slot/shared-deck source definition, not city-card origins."""
    new_decks = {econ.city_deck[cid] for cid in new_ids}
    base_deck_ids = [deck["id"] for deck in econ.decks if deck["id"] not in new_decks]
    sources = source_cities(econ, base_deck_ids, {cid: cid for cid in new_ids})
    return {card["id"]: min(S_MAX, P.near_source_silver_cap)
            for cid in new_ids for card in econ.deck(econ.city_deck[cid])["cards"]
            if near_source_good(P, D, card, cid, cid, sources) is not None}


def final_economic_errors(econ: Economy, D, new_ids: list[str], P: Params) -> list[str]:
    """Read-only closure for existing cap and silver loops; no barter-profit threshold."""
    errors = []
    limits = near_source_silver_limits(econ, D, new_ids, P)
    for cid in new_ids:
        for card in econ.deck(econ.city_deck[cid])["cards"]:
            silver = card_silver(card)
            if card["id"] in limits and silver is not None and silver > limits[card["id"]]:
                errors.append("%s: 近源白银 %d > %d" % (card["id"], silver, limits[card["id"]]))
    only = set(new_ids)
    loops = all_loops(econ, D, P.turns_table, city_filter=lambda a, b: not only or a in only or b in only)
    for loop in loops:
        if loop["rate"] > P.loop_cap_one_way + P.loop_cap_eps:
            errors.append("单程循环超限：%s>%s:%s" % (loop["buy"], loop["sell"], loop["good"]))
    for loop in two_way_loops(loops, P.turns_table):
        if loop["rate"] > P.loop_cap_two_way + P.loop_cap_eps:
            errors.append("往返循环超限：%s>%s" % (loop["a"], loop["b"]))
    return errors


def enforce_loop_cap(econ: Economy, D, new_ids: list[str], P: Params) -> tuple[list[dict], bool]:
    """Only the existing same-good silver-buy/silver-sell and two-way model, not all barter chains.
    经过新城的这些循环不许比原版模型上限更赚（比较一律 rate > cap + eps）。超了就改新牌堆上那张卡：
    卖出卡在新牌堆 → 白银 -1；否则买入卡在新牌堆 → 整批数量 -1，数量已是 2 就白银 +1。返回 (记录, 是否全部修好)。"""
    cap1, cap2, eps = P.loop_cap_one_way, P.loop_cap_two_way, P.loop_cap_eps
    T = P.turns_table
    silver_limits = near_source_silver_limits(econ, D, new_ids, P)
    card_home = {c["id"]: (dk["id"], c) for dk in econ.decks for c in dk["cards"]}
    new_set = set(new_ids)
    new_decks = {econ.city_deck[c] for c in new_ids}
    log = []
    for _ in range(P.loop_guard_max_iter):
        L = all_loops(econ, D, T, city_filter=lambda A, B: A in new_set or B in new_set)
        W = two_way_loops(L, T)
        bad = [l for l in L if l["rate"] > cap1 + eps]
        if not bad:
            badw = [w for w in W if w["rate"] > cap2 + eps]
            if not badw:
                return log, True
            w = badw[0]
            cand = [l for l in L if {l["buy"], l["sell"]} == {w["a"], w["b"]}]
            bad = sorted(cand, key=lambda l: -l["profit"])[:1]
        l = bad[0]
        changed = False
        for role in ("sell_card", "buy_card"):
            dk_id, card = card_home[l[role]]
            if dk_id not in new_decks:
                continue
            silver = next(e for e in card["entries"] if e["resource_kind"] == "SILVER")
            if role == "sell_card" and silver["quantity"] > S_MIN:
                silver["quantity"] -= 1
                for e in card["entries"]:
                    if e["resource_kind"] == "GOOD" and e["quantity"] >= 2:
                        e["quantity"] = max(2, min(e["quantity"], int(math.floor(silver["quantity"] * 1.5 + 1e-9))))
                log.append(_guard_entry(dk_id, card["id"], "SILVER_MINUS_1", l))
                changed = True
                break
            if role == "buy_card":
                ent = next(e for e in card["entries"] if e["resource_id"] == l["good"])
                if ent["quantity"] > 2:
                    ent["quantity"] -= 1
                    log.append(_guard_entry(dk_id, card["id"], "QTY_MINUS_1", l))
                    changed = True
                    break
                if silver["quantity"] < silver_limits.get(card["id"], S_MAX):
                    silver["quantity"] += 1
                    log.append(_guard_entry(dk_id, card["id"], "SILVER_PLUS_1", l))
                    changed = True
                    break
        if not changed:
            log.append(_guard_entry("?", "?", "UNFIXABLE", l))
            return log, False
    return log, False


def _guard_entry(deck_id, card_id, change, l) -> dict:
    return {"deck": deck_id, "card": card_id, "change": change,
            "loop": "%s>%s:%s" % (l["buy"], l["sell"], l["good"]), "rate_e9": k9(l["rate"])}


# ---------------------------------------------------------------------------
# 硬不变量（recon/01 §4 + ECONOMY §2.3 + DESIGN R15 补充项）
# ---------------------------------------------------------------------------

UNIT_FLOOR = 2 / 3   # 原版 80 张卡里特产整批最低单价（S=2, q=3）


def validate_deck(deck: dict, goods, existing_card_ids=frozenset(), expect_cards: int = 10,
                  local_goods=None, strict: bool = False) -> list[str]:
    """deck_gen.py:627-675 的检查；strict=True 时加上 DESIGN R15 对新牌堆的补充项
    （恰好 1 项白银、数量 1–4、本城特产只在第 2 格、白银均值 ∈ [2.8, 4.0]、货种 ≥ 13、丝绸正好 4 格）。"""
    errs = []
    if len(deck["cards"]) != expect_cards:
        errs.append("%s: 卡数 %d != %d" % (deck["id"], len(deck["cards"]), expect_cards))
    signatures = set()
    seen = set()
    for c in deck["cards"]:
        cid = c["id"]
        if cid in seen or cid in existing_card_ids:
            errs.append("%s: 卡 id 重复" % cid)
        seen.add(cid)
        ent = c["entries"]
        if len(ent) != 4:
            errs.append("%s: 不是 4 项" % cid)
        kinds = [e["resource_kind"] for e in ent]
        if any(k not in ("GOOD", "SILVER") for k in kinds):
            errs.append("%s: 无效资源类型" % cid)
        if all(k == "SILVER" for k in kinds):
            errs.append("%s: 全是白银" % cid)
        if kinds.count("SILVER") > 1:
            errs.append("%s: 白银多于 1 项" % cid)
        for e in ent:
            if int(e["quantity"]) <= 0:
                errs.append("%s: 数量必须为正" % cid)
            if e["resource_kind"] == "GOOD":
                if e["resource_id"] not in goods:
                    errs.append("%s: 货物 %s 不存在" % (cid, e["resource_id"]))
                if int(e["quantity"]) > Q_MAX:
                    errs.append("%s: %s×%d 超过货仓 4 格" % (cid, e["resource_id"], e["quantity"]))
        ids = [e["resource_id"] for e in ent]
        if len(set(ids)) != len(ids):
            errs.append("%s: 同一卡上资源重复" % cid)
        sig = tuple(sorted((e["resource_id"], int(e["quantity"])) for e in ent))
        if sig in signatures:
            errs.append("%s: 与同堆另一张卡完全相同" % cid)
        signatures.add(sig)
        S = card_silver(c)
        if local_goods and S is not None:
            for e in ent:
                if e["resource_id"] in local_goods and S / int(e["quantity"]) < UNIT_FLOOR - 1e-9:
                    errs.append("%s: 特产 %s 单价 %d/%d 低于 2/3" % (cid, e["resource_id"], S, e["quantity"]))
        if strict:
            if kinds.count("SILVER") != 1:
                errs.append("%s: 不是恰好 1 项白银" % cid)
            for k, e in enumerate(ent):
                if e["resource_kind"] == "GOOD" and local_goods and e["resource_id"] in local_goods and k != 1:
                    errs.append("%s: 本城特产不在第 2 格" % cid)
    if strict:
        svals = [card_silver(c) for c in deck["cards"] if card_silver(c) is not None]
        if svals:
            m = sum(svals) / len(svals)
            if m < 2.8 - 1e-9 or m > 4.0 + 1e-9:
                errs.append("%s: 白银均值 %d/%d 不在 [2.8, 4.0]" % (deck["id"], sum(svals), len(svals)))
        kinds_set = set(e["resource_id"] for c in deck["cards"] for e in c["entries"] if e["resource_kind"] == "GOOD")
        if len(kinds_set) < 13:
            errs.append("%s: 货种 %d < 13" % (deck["id"], len(kinds_set)))
        n_silk = sum(1 for c in deck["cards"] for e in c["entries"] if e["resource_id"] == "silk")
        if n_silk != 4:
            errs.append("%s: 丝绸 %d 格，不是 4 格" % (deck["id"], n_silk))
    return errs


# ---------------------------------------------------------------------------
# 接法（拓扑）：规范槽位、拓扑键、枚举
# ---------------------------------------------------------------------------

def base_city_info(rdir: Path = RULESET_DIR) -> dict:
    cities = {c["id"]: c for c in json.load(open(rdir / "cities.json"))["items"]}
    return {cid: {"x": float(c["map_position"][0]), "routes": list(c["allowed_routes"])} for cid, c in cities.items()}


def side_of_host(info, host) -> str:
    return "W" if info[host]["x"] < MAP_MID_X else "E"


def topology_key(topology: list[dict]) -> str:
    """Same canonical segments as CustomMapSchema, including extra/interchange."""
    if not topology:
        return ""
    parts = ["%s:%s:%s:%s" % (t["slot"], t["host"], t["route_type"], t["partner"]) for t in sorted(topology, key=lambda t: t["slot"])]
    for t in topology:
        parts += ["extra:%s:%s:%s" % (t["slot"], link["host"], link["route_type"])
                  for link in t.get("extra_connections", [])]
        if t.get("host_interchange", False) and t["host"] == "cairo" and t["route_type"] == LAND:
            if "interchange:cairo:LAND" not in parts:
                parts.append("interchange:cairo:LAND")
    return "topo_v1|" + "|".join(sorted(parts))


def parse_topology_key(key: str) -> list[dict]:
    if not key:
        return []
    head, *rest = key.split("|")
    if head != "topo_v1" or not rest:
        raise ValueError("无效拓扑键头或空段")
    out, extra, by_slot, seen = [], [], {}, set()
    interchange = False
    for r in rest:
        if not r or r in seen:
            raise ValueError("空段或重复拓扑段")
        seen.add(r)
        f = r.split(":")
        if f[0] == "interchange":
            if r != "interchange:cairo:LAND":
                raise ValueError("不支持的换乘段")
            interchange = True
        elif f[0] == "extra":
            if len(f) != 4 or f[1] not in ("e1", "e2", "w1", "w2") or not f[2] or f[3] not in (LAND, SEA):
                raise ValueError("无效额外连接段")
            extra.append({"slot": f[1], "host": f[2], "route_type": f[3]})
        else:
            if len(f) != 4 or f[0] not in ("e1", "e2", "w1", "w2") or not f[1] or f[2] not in (LAND, SEA):
                raise ValueError("未知或无效新城段")
            slot, host, route, partner = f
            if slot in by_slot or (partner and (partner not in ("e1", "e2", "w1", "w2") or partner == slot)):
                raise ValueError("重复槽位或无效搭档")
            entry = {"slot": slot, "host": host, "route_type": route, "partner": partner}
            out.append(entry)
            by_slot[slot] = entry
    if not out:
        raise ValueError("非空拓扑键没有新城")
    for entry in out:
        if entry["partner"] and entry["partner"] not in by_slot:
            raise ValueError("搭档槽位不存在")
    for link in extra:
        if link["slot"] not in by_slot:
            raise ValueError("额外连接引用不存在槽位")
        entry = by_slot[link["slot"]]
        if link["route_type"] != entry["route_type"] or link["host"] == entry["host"]:
            raise ValueError("额外连接必须同交通且不同宿主")
        entry.setdefault("extra_connections", []).append({"host": link["host"], "route_type": link["route_type"]})
    if interchange:
        matched = False
        for entry in out:
            if entry["host"] == "cairo" and entry["route_type"] == LAND:
                entry["host_interchange"] = True
                matched = True
        if not matched:
            raise ValueError("换乘段缺少开罗LAND宿主")
    for entry in out:
        if "extra_connections" in entry:
            entry["extra_connections"].sort(key=lambda link: link["host"])
    return sorted(out, key=lambda entry: entry["slot"])


def canonical_topology(pairs: list[tuple[tuple[str, str], tuple[str, str]]], info) -> list[dict]:
    """pairs: [((西宿主, 类型), (东宿主, 类型))]。规范槽位（DESIGN 3.4 / 3.14.5）：一对里西侧的是 w、东侧的是 e；
    两对时按西侧宿主 id 排序，第一对 w1/e1，第二对 w2/e2。断言 w* 的宿主 x < 2048、e* 的宿主 ≥ 2048。"""
    out = []
    for n, (west, east) in enumerate(sorted(pairs, key=lambda p: p[0][0]), start=1):
        assert side_of_host(info, west[0]) == "W", west
        assert side_of_host(info, east[0]) == "E", east
        out.append({"slot": "w%d" % n, "host": west[0], "route_type": west[1], "partner": "e%d" % n})
        out.append({"slot": "e%d" % n, "host": east[0], "route_type": east[1], "partner": "w%d" % n})
    for t in out:
        want = "W" if t["slot"].startswith("w") else "E"
        assert side_of_host(info, t["host"]) == want, t
    return sorted(out, key=lambda t: t["slot"])


def enumerate_topologies():
    """R6 + R9 下的全部接法。一对：宿主挂之前度数 ≤ 3、类型在宿主的 allowed_routes 里、两宿主相距 ≥ 9 步、
    两宿主「到其余 15 座原城的平均步数」相差 ≤ 2.0。两对：两个一对接法，四座宿主互不相同。"""
    board = Board.from_ruleset()
    D = board.city_distances()
    info = base_city_info()
    originals = board.cities()
    avg = {c: sum(D[c][o] for o in originals if o != c) / (len(originals) - 1) for c in originals}
    host_opts = []
    for c in originals:
        if board.degree(c) > 3:
            continue
        for r in sorted(info[c]["routes"]):
            host_opts.append((c, r))
    west = [h for h in host_opts if side_of_host(info, h[0]) == "W"]
    east = [h for h in host_opts if side_of_host(info, h[0]) == "E"]
    one = []
    for w in west:
        for e in east:
            if D[w[0]][e[0]] < 9:
                continue
            if abs(avg[w[0]] - avg[e[0]]) > 2.0 + 1e-9:
                continue
            one.append((w, e))
    one_topos = [canonical_topology([p], info) for p in one]
    two_topos = []
    for i in range(len(one)):
        for j in range(i + 1, len(one)):
            hosts = {one[i][0][0], one[i][1][0], one[j][0][0], one[j][1][0]}
            if len(hosts) != 4:
                continue
            two_topos.append(canonical_topology([one[i], one[j]], info))
    one_topos.sort(key=topology_key)
    two_topos.sort(key=topology_key)
    return one_topos, two_topos, host_opts


# B 档 6 张 + 两对 2 张（DESIGN 4.4）：地图由这些接法的默认原型、默认特产生成
B_TOPOLOGIES = {
    "B1": [(("aden", SEA), ("changan", LAND))],
    "B2": [(("rome", SEA), ("heijokyo", SEA))],
    "B3": [(("baghdad", LAND), ("simhala", LAND))],
    "B4": [(("panti", LAND), ("dagon", SEA))],
    "B5": [(("cairo", SEA), ("geumseong", SEA))],
    "B6": [(("jeddah", LAND), ("yumenguan", LAND))],
    "B7": [(("aden", SEA), ("changan", LAND)), (("rome", SEA), ("heijokyo", SEA))],
    "B8": [(("baghdad", LAND), ("simhala", LAND)), (("cairo", SEA), ("geumseong", SEA))],
}


def b_topology(name: str) -> list[dict]:
    return canonical_topology(B_TOPOLOGIES[name], base_city_info())


# ---------------------------------------------------------------------------
# tradegen_v1：generate(topology, goods_map)
# ---------------------------------------------------------------------------

def tradegen_generate(topology: list[dict], goods_map: dict | None = None, P: Params | None = None,
                      rdir: Path = RULESET_DIR) -> dict:
    """DESIGN 3.14 的 generate：只看拓扑。返回 {ok, decks: [{id, city_id, cards}], guard_log, cap_log, errors}；
    goods_map = {槽位: 真实货物 id}，缺省时保留代号 x_<槽位>（参考夹具就是代号版）。"""
    P = P or frozen_params()
    topo = sorted(topology, key=lambda t: t["slot"])
    econ = Economy.from_ruleset(rdir)
    board = Board.from_ruleset(rdir)
    base_deck_ids = [d["id"] for d in econ.decks]
    originals = set(board.cities())
    errors = []
    for t in topo:
        if t["host"] not in originals:
            return {"ok": False, "decks": [], "guard_log": [], "cap_log": [], "errors": ["宿主不是原版城：%s" % t["host"]]}
    codes = {}
    for t in topo:
        cid = "x_" + t["slot"]
        if t.get("host_interchange", False):
            if t["host"] != "cairo" or t["route_type"] != LAND:
                return {"ok": False, "decks": [], "guard_log": [], "cap_log": [], "errors": ["宿主换乘扩展仅支持开罗LAND"]}
            node = board.nodes[board.city_node("cairo")]
            node["routes"].add(LAND)
            node["interchange"] = True
        try:
            board = board.with_leaf(cid, t["host"], t["route_type"])
            for connection in t.get("extra_connections", []):
                if connection.get("route_type") != t["route_type"] or connection.get("host") not in originals:
                    raise ValueError("额外连接必须同交通且连接原版城")
                board = board.with_leaf(cid, connection["host"], connection["route_type"], allow_existing=True)
        except ValueError as error:
            return {"ok": False, "decks": [], "guard_log": [], "cap_log": [], "errors": [str(error)]}
        econ.add_city(cid, cid, cid, cid)          # 新货代号 = x_<槽位>
        codes[cid] = cid
    D = board.city_distances()
    sources = source_cities(econ, base_deck_ids, codes)
    new_decks = []
    existing_ids = {c["id"] for d in econ.decks for c in d["cards"]}
    cap_log = []
    for t in topo:
        cid = "x_" + t["slot"]
        forced = {}
        if t.get("partner"):
            forced["x_" + t["partner"]] = P.forced_min
        deck_id = "deck_" + cid
        dk = generate_deck(econ, D, P, deck_id, [cid], forced=forced)
        cap_log += near_source_cap(P, D, dk, cid, cid, sources)
        errs = validate_deck(dk, econ.goods, existing_ids, local_goods={cid})
        if errs:
            errors += errs
        existing_ids |= {c["id"] for c in dk["cards"]}
        new_decks.append(dk)
        econ.decks.append({"id": deck_id, "city_ids": [cid], "cards": dk["cards"]})
        econ.city_deck[cid] = deck_id
    guard_log, fixed = enforce_loop_cap(econ, D, ["x_" + t["slot"] for t in topo], P)
    if not fixed:
        errors.append("循环护栏没能把全部循环压到上限以内")
    out_decks = []
    for t, dk in zip(topo, new_decks):
        cid = "x_" + t["slot"]
        errs = validate_deck(dk, econ.goods, local_goods={cid}, strict=True)
        errors += errs
        partner = "x_" + t["partner"] if t.get("partner") else ""
        if partner:
            n_partner = sum(1 for c in dk["cards"] for e in c["entries"] if e["resource_id"] == partner)
            if n_partner < P.forced_min:
                errors.append("%s: 搭档特产 %d 格 < %d" % (dk["id"], n_partner, P.forced_min))
        out_decks.append({"id": dk["id"], "city_id": cid, "cards": dk["cards"]})
    # Read-only: clamping again here could break the loop constraint just satisfied.
    errors += final_economic_errors(econ, D, ["x_" + t["slot"] for t in topo], P)
    if goods_map:
        rename = {"x_" + slot: gid for slot, gid in goods_map.items()}
        for dk in out_decks:
            for c in dk["cards"]:
                for e in c["entries"]:
                    if e["resource_kind"] == "GOOD" and e["resource_id"] in rename:
                        e["resource_id"] = rename[e["resource_id"]]
    return {"ok": not errors, "decks": out_decks, "guard_log": guard_log, "cap_log": cap_log, "errors": errors,
            "_econ": econ, "_D": D}


def public_result(res: dict) -> dict:
    return {k: v for k, v in res.items() if not k.startswith("_")}


# ---------------------------------------------------------------------------
# 规范文本（夹具与跨语言比对用）
# ---------------------------------------------------------------------------

def canon(v) -> str:
    """规范 JSON：键按字典序、无空白、整数按整数、字符串按 JSON 转义（不转义非 ASCII）。
    GDScript 版 TradeGenV1.canonical_text 写法相同，两边产出逐字节相同。"""
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        raise TypeError("规范文本里不允许浮点：%r" % v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(canon(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join(json.dumps(str(k), ensure_ascii=False) + ":" + canon(v[k]) for k in sorted(v, key=str)) + "}"
    raise TypeError(type(v))


def fixture_doc(topology: list[dict], res: dict) -> dict:
    return {"generator": VERSION, "topology_key": topology_key(topology),
            "topology": sorted(topology, key=lambda t: t["slot"]), "result": public_result(res)}


def fixture_name(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:16] + ".json"


# ---------------------------------------------------------------------------
# 回测（T-G3e）
# ---------------------------------------------------------------------------

def deck_stats(econ: Economy, D, deck: dict) -> dict:
    locs = deck_locals(econ, deck["city_ids"])
    st = {}
    S = [card_silver(c) for c in deck["cards"] if card_silver(c) is not None]
    st["S"] = sorted(S)
    st["n_no_silver"] = sum(1 for c in deck["cards"] if card_silver(c) is None)
    st["local_q"] = {L: sorted(e["quantity"] for c in deck["cards"] for e in c["entries"] if e["resource_id"] == L) for L in locs}
    unit = []
    for c in deck["cards"]:
        s = card_silver(c)
        for e in c["entries"]:
            if e["resource_id"] in locs and s is not None:
                unit.append(s / e["quantity"])
    st["unit"] = sorted(unit)
    bucket = defaultdict(list)
    per_good = defaultdict(list)
    for c in deck["cards"]:
        s = card_silver(c)
        if s is None:
            continue
        for e in c["entries"]:
            g = e["resource_id"]
            if e["resource_kind"] != "GOOD" or g in locs or e["quantity"] != 1:
                continue
            per_good[g].append(s)
            d = good_distance(econ, D, deck["city_ids"], g)
            if d is not None:
                bucket[d].append(s)
    st["bucket"] = {d: statistics.mean(v) for d, v in bucket.items()}
    st["bucket_n"] = {d: len(v) for d, v in bucket.items()}
    st["per_good"] = {g: statistics.mean(v) for g, v in per_good.items()}
    cnt = Counter(e["resource_id"] for c in deck["cards"] for e in c["entries"] if e["resource_kind"] == "GOOD" and e["resource_id"] not in locs)
    st["counts"] = cnt
    st["goods"] = set(e["resource_id"] for c in deck["cards"] for e in c["entries"] if e["resource_kind"] == "GOOD")
    return st


def quantile_align(a, b):
    if not a or not b:
        return float("nan")
    out = []
    for i, y in enumerate(b):
        x = a[min(len(a) - 1, int((i + 0.5) / len(b) * len(a)))]
        out.append(abs(x - y))
    return statistics.mean(out)


def compare(econ: Economy, D, gen: dict, real: dict) -> dict:
    g, r = deck_stats(econ, D, gen), deck_stats(econ, D, real)
    m = {}
    m["S_sorted_mae"] = quantile_align(g["S"], r["S"])
    m["S_mean_gen"], m["S_mean_real"] = statistics.mean(g["S"]), statistics.mean(r["S"])
    m["S_mean_err"] = m["S_mean_gen"] - m["S_mean_real"]
    qerr = []
    for L in r["local_q"]:
        qerr.append(quantile_align(g["local_q"].get(L, []), r["local_q"][L]))
    m["q_sorted_mae"] = statistics.mean(qerr) if qerr else float("nan")
    num = den = 0.0
    for d, v in r["bucket"].items():
        if d in g["bucket"]:
            num += abs(g["bucket"][d] - v) * r["bucket_n"][d]
            den += r["bucket_n"][d]
    m["bucket_mae"] = num / den if den else float("nan")
    common = [x for x in r["per_good"] if x in g["per_good"]]
    m["per_good_mae"] = statistics.mean(abs(g["per_good"][x] - r["per_good"][x]) for x in common) if common else float("nan")
    allg = set(g["counts"]) | set(r["counts"])
    m["count_mae"] = statistics.mean(abs(g["counts"].get(x, 0) - r["counts"].get(x, 0)) for x in allg)
    m["jaccard"] = len(g["goods"] & r["goods"]) / len(g["goods"] | r["goods"])
    silk_g = g["per_good"].get("silk")
    silk_r = r["per_good"].get("silk")
    m["silk_err"] = (silk_g - silk_r) if (silk_g is not None and silk_r is not None) else float("nan")
    return m


def baseline_deck(econ: Economy, D, real: dict) -> dict:
    """对照组：不看距离的"模板"生成——所有卡 S=4，特产 q=3，外地货按字母轮转。"""
    locs = deck_locals(econ, real["city_ids"])
    pool = sorted(g for g in econ.producer if econ.producer[g] not in real["city_ids"]) + ["silk"]
    types = ["L"] * 10 if len(locs) == 2 else (["A"] * 5 + ["L"] * 5 if locs else ["A"] * 10)
    cards, k = [], 0
    for n, t in enumerate(types, start=1):
        need = 2 if t == "L" else 3
        gs = []
        while len(gs) < need:
            g = pool[k % len(pool)]
            k += 1
            if g not in gs:
                gs.append(g)
        ent = [{"resource_kind": "GOOD", "resource_id": gs[0], "quantity": 1}]
        if t == "L":
            ent.append({"resource_kind": "GOOD", "resource_id": locs[n % len(locs)], "quantity": 3})
        for g in gs[1:]:
            ent.append({"resource_kind": "GOOD", "resource_id": g, "quantity": 1})
        ent.append({"resource_kind": "SILVER", "resource_id": "silver", "quantity": 4})
        cards.append({"id": "b%d" % n, "card_number": n, "entries": ent})
    return {"id": real["id"] + "_baseline", "city_ids": real["city_ids"], "cards": cards}


METRIC_KEYS = ["S_sorted_mae", "S_mean_err", "q_sorted_mae", "bucket_mae", "per_good_mae", "count_mae", "jaccard", "silk_err"]


def run_backtest():
    """留一：每次拿掉一堆，参数只用另外 7 堆拟合，再重建被拿掉的那堆（不开近源封顶、不开护栏）。"""
    econ = Economy.from_ruleset()
    board = Board.from_ruleset()
    D = board.city_distances()
    all_ids = [d["id"] for d in econ.decks]
    rows, rows_base = [], []
    for hold in all_ids:
        train = [d for d in all_ids if d != hold]
        P = params_from_doc(params_to_doc_loo(fit_params(econ, D, train)))
        real = econ.deck(hold)
        gen = generate_deck(econ, D, P, hold + "_gen", real["city_ids"], exclude_deck_for_silk=hold)
        errs = validate_deck(gen, econ.goods, local_goods=set(deck_locals(econ, real["city_ids"])))
        assert not errs, errs
        m = compare(econ, D, gen, real)
        m["deck"] = hold
        rows.append((m, gen, real, P))
        rows_base.append(compare(econ, D, baseline_deck(econ, D, real), real))
    return econ, D, rows, rows_base


def avg_metric(rs, k):
    v = [r[k] for r in rs if not (isinstance(r[k], float) and math.isnan(r[k]))]
    return statistics.mean(abs(x) if k in ("S_mean_err", "silk_err") else x for x in v)


def print_backtest():
    econ, D, rows, rows_base = run_backtest()
    print("# 留一回测（在另外 7 堆上拟合，重建被留出的一堆；不开近源封顶、不开护栏）")
    print("| deck | " + " | ".join(METRIC_KEYS) + " |")
    print("|" + "---|" * (len(METRIC_KEYS) + 1))
    for m, gen, real, P in rows:
        print("| %s | %s |" % (m["deck"], " | ".join("%.3f" % m[k] for k in METRIC_KEYS)))
    print("| 生成器 8 堆平均 | %s |" % " | ".join("%.3f" % avg_metric([r[0] for r in rows], k) for k in METRIC_KEYS))
    print("| 对照：不看距离 | %s |" % " | ".join("%.3f" % avg_metric(rows_base, k) for k in METRIC_KEYS))
    return rows


# ---------------------------------------------------------------------------
# 循环报告（保留 ECONOMY loops 的核心输出）与 T-G3d 三项补查
# ---------------------------------------------------------------------------

def base_loops():
    P = frozen_params()
    econ = Economy.from_ruleset()
    D = Board.from_ruleset().city_distances()
    L = all_loops(econ, D, P.turns_table)
    W = two_way_loops(L, P.turns_table)
    return econ, D, L, W


def loop_report():
    econ, D, L, W = base_loops()
    P = frozen_params()
    print("原版：单程最好 %.6f（冻结 %.6f），往返最好 %.6f（冻结 %.6f）" % (L[0]["rate"], P.loop_cap_one_way, W[0]["rate"], P.loop_cap_two_way))
    for name in sorted(B_TOPOLOGIES):
        topo = b_topology(name)
        res = tradegen_generate(topo)
        e2, D2 = res["_econ"], res["_D"]
        new = ["x_" + t["slot"] for t in topo]
        Ln = all_loops(e2, D2, P.turns_table, city_filter=lambda A, B: A in new or B in new)
        Wn = two_way_loops(Ln, P.turns_table)
        print("%s %s：经过新城单程最好 %.2f、往返最好 %.2f；近源封顶 %d 张、护栏 %d 次"
              % (name, topology_key(topo), Ln[0]["rate"] if Ln else 0, Wn[0]["rate"] if Wn else 0, len(res["cap_log"]), len(res["guard_log"])))


def barter_triangles(econ: Economy, D, T, new_ids=None) -> float:
    """以物易物三角（第二轮评审 critic1/barter.py 的口径）：甲地用白银按一张卡买满货仓 → 乙地用另一张卡把 g 换成 h
    （换 t 份，手上货不超过 4 格）→ 丙地按牌面卖 h（没有牌面就 1 银/件直售），剩下的 g 直售。三张牌同时翻开的最好情况；
    一轮 = T[甲乙] + T[乙丙] + T[丙甲]（丙 = 甲时改为多停 1 回合）。new_ids 非空时只算三站里至少一站是新城的。"""
    decks = {d["id"]: d for d in econ.decks}
    deck_of = econ.city_deck
    cs = sorted(c for c in deck_of if c in D)
    so = {c: market_offers(econ, decks[deck_of[c]]) for c in cs}
    bo = {}
    for c in cs:
        out = defaultdict(list)
        for card in decks[deck_of[c]]["cards"]:
            goods = [e for e in card["entries"] if e["resource_kind"] == "GOOD"]
            for x in goods:
                for y in goods:
                    if x is y:
                        continue
                    out[x["resource_id"]].append((x["quantity"], y["resource_id"], y["quantity"], card["id"]))
        bo[c] = out
    touch = set(new_ids or [])

    def sellv(C, h, units, excl):
        best = units
        for S, q, cid in so[C].get(h, []):
            if cid in excl:
                continue
            t = units // q
            best = max(best, t * S + (units - t * q))
        return best

    best = 0.0
    for A in cs:
        for g, buys in so[A].items():
            for Sb, qb, cb in buys:
                times = WAREHOUSE // qb
                units = times * qb
                cost = times * Sb
                for B in cs:
                    if B == A:
                        continue
                    for a, h, bq, cbar in bo[B].get(g, []):
                        if cbar == cb:
                            continue
                        for t in range(1, units // a + 1):
                            hold_g = units - a * t
                            hold_h = bq * t
                            if hold_g + hold_h > WAREHOUSE:
                                continue
                            for C in cs:
                                if C == B:
                                    continue
                                if touch and not (A in touch or B in touch or C in touch):
                                    continue
                                prof = sellv(C, h, hold_h, {cb, cbar}) + hold_g - cost
                                if prof <= 0:
                                    continue
                                turns = T[D[A][B]] + T[D[B][C]] + (T[D[C][A]] if C != A else 0) + (1 if C == A else 0)
                                best = max(best, prof / turns)
    return best


def expected_one_way(econ: Economy, D, T, new_ids=None) -> float:
    """按两张牌同时翻开的概率加权的期望单程（critic1/expect.py 的口径）：甲、乙两城各翻开本堆任一张卡，
    两张卡上能做的最好一趟（买满货仓、按牌面卖）求平均（同堆时去掉同一张卡），再 ÷ 2·T[d]。"""
    decks = {d["id"]: d for d in econ.decks}
    deck_of = econ.city_deck
    cs = sorted(c for c in deck_of if c in D)
    touch = set(new_ids or [])

    def card_offers(card):
        S = card_silver(card)
        if S is None:
            return {}
        return {e["resource_id"]: (S, e["quantity"], card["id"]) for e in card["entries"] if e["resource_kind"] == "GOOD"}

    best = 0.0
    for A in cs:
        for B in cs:
            if A == B:
                continue
            if touch and A not in touch and B not in touch:
                continue
            da = decks[deck_of[A]]["cards"]
            db = decks[deck_of[B]]["cards"]
            same = deck_of[A] == deck_of[B]
            oa = [card_offers(c) for c in da]
            ob = [card_offers(c) for c in db]
            tot = 0
            n = 0
            for i, ca in enumerate(oa):
                for j, cb in enumerate(ob):
                    if same and da[i]["id"] == db[j]["id"]:
                        continue
                    b = 0
                    for g, bo_ in ca.items():
                        so_ = cb.get(g)
                        if so_:
                            pr, _c = load_profit(bo_, so_)
                            b = max(b, pr)
                    tot += b
                    n += 1
            best = max(best, (tot / n) / (2 * T[D[A][B]]))
    return best


def camp_trade(econ: Economy, only_decks=None) -> int:
    """同一座城「先买、等翻牌再卖回」：同一堆里用卡 X 白银买满 4 格，换卡 Y 按牌面卖出，一轮最多赚多少银。"""
    best = 0
    for d in econ.decks:
        if only_decks and d["id"] not in only_decks:
            continue
        offers = market_offers(econ, d)
        for g, lst in offers.items():
            for bo in lst:
                for so in lst:
                    if bo[2] == so[2]:
                        continue
                    pr, _c = load_profit(bo, so)
                    best = max(best, pr)
    return best


def extra_loops_report(topologies=None) -> dict:
    P = frozen_params()
    econ, D, _L, _W = base_loops()
    out = {"base": {"barter": barter_triangles(econ, D, P.turns_table),
                    "expected": expected_one_way(econ, D, P.turns_table),
                    "camp": camp_trade(econ)}}
    one, two = enumerate_topologies()[:2]
    worst = {"barter": (0.0, ""), "expected": (0.0, ""), "camp": (0, "")}
    topologies = topologies or (one + two)
    out["n"] = len(topologies)
    for topo in topologies:
        res = tradegen_generate(topo)
        e2, D2 = res["_econ"], res["_D"]
        new = ["x_" + t["slot"] for t in topo]
        key = topology_key(topo)
        v = {"barter": barter_triangles(e2, D2, P.turns_table, new),
             "expected": expected_one_way(e2, D2, P.turns_table, new),
             "camp": camp_trade(e2, {"deck_" + c for c in new})}
        for k in worst:
            if v[k] > worst[k][0]:
                worst[k] = (v[k], key)
    out["new_worst"] = worst
    return out


# ---------------------------------------------------------------------------
# 全部接法统计（DESIGN R13、R14、R16、附录 B 的数字）
# ---------------------------------------------------------------------------

def sweep(topologies) -> dict:
    P = frozen_params()
    T = P.turns_table
    stats = {"n": 0, "fail": 0, "cap_cards": 0, "guard_changes": 0, "one_way_max": 0.0, "two_way_max": 0.0,
             "silver_mean_min": 9.0, "silver_mean_max": 0.0, "partner_prices": Counter(), "short_rates": [],
             "inv_violations": 0}
    for topo in topologies:
        res = tradegen_generate(topo)
        stats["n"] += 1
        if not res["ok"]:
            stats["fail"] += 1
            stats["inv_violations"] += len(res["errors"])
        stats["cap_cards"] += len(res["cap_log"])
        stats["guard_changes"] += len(res["guard_log"])
        e2, D2 = res["_econ"], res["_D"]
        new = ["x_" + t["slot"] for t in topo]
        L = all_loops(e2, D2, T, city_filter=lambda A, B: A in new or B in new)
        W = two_way_loops(L, T)
        if L:
            stats["one_way_max"] = max(stats["one_way_max"], L[0]["rate"])
        if W:
            stats["two_way_max"] = max(stats["two_way_max"], W[0]["rate"])
        for l in L:
            if l["d"] == 3:
                stats["short_rates"].append(l["rate"])
        by_slot = {t["slot"]: t for t in topo}
        for dk in res["decks"]:
            sv = [card_silver(c) for c in dk["cards"]]
            m = sum(sv) / len(sv)
            stats["silver_mean_min"] = min(stats["silver_mean_min"], m)
            stats["silver_mean_max"] = max(stats["silver_mean_max"], m)
            partner = "x_" + by_slot[dk["city_id"][2:]]["partner"]
            for c in dk["cards"]:
                for e in c["entries"]:
                    if e["resource_id"] == partner:
                        stats["partner_prices"][card_silver(c)] += 1
    sr = sorted(stats["short_rates"])
    stats["short_median"] = statistics.median(sr) if sr else 0.0
    stats["short_p90"] = sr[min(len(sr) - 1, int(0.9 * len(sr)))] if sr else 0.0
    del stats["short_rates"]
    stats["partner_prices"] = dict(sorted(stats["partner_prices"].items()))
    return stats


# ---------------------------------------------------------------------------
# 命令
# ---------------------------------------------------------------------------

def dump_json(path: Path, doc) -> str:
    text = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    return text


def cmd_params(args):
    doc = export_params()
    text = dump_json(PARAMS_PATH, doc)
    bad = check_product_knobs(doc)
    for b in bad:
        print("PARAMS_CHECK 产品旋钮不合格：%s" % b)
    if args.check:
        cur = PARAMS_PATH.read_text(encoding="utf-8")
        if cur != text:
            print("PARAMS_CHECK 不一致：%s 与重新拟合的结果不同（生成器参数被改过，或 f64 段没跟着改）" % PARAMS_PATH)
            sys.exit(1)
        if bad:
            sys.exit(1)
        print("PARAMS_CHECK ok %s generator_params_sha256=%s max_pairs=%d max_user=%d bank_delta_per_city=%s"
              % (PARAMS_PATH, generator_params_sha256(doc), doc["max_pairs"], doc["max_user"], doc["bank_delta_per_city"]))
        return
    if bad:
        sys.exit(1)
    PARAMS_PATH.parent.mkdir(parents=True, exist_ok=True)
    PARAMS_PATH.write_text(text, encoding="utf-8")
    print("写出 %s" % PARAMS_PATH)


def cmd_topologies(args):
    one, two, host_opts = enumerate_topologies()
    board = Board.from_ruleset()
    D = board.city_distances()
    by_steps = Counter()
    for t in one:
        by_slot = {x["slot"]: x for x in t}
        by_steps[D[by_slot["w1"]["host"]][by_slot["e1"]["host"]] + 6] += 1
    covered = set()
    for t in one:
        for x in t:
            covered.add((x["host"], x["route_type"]))
    print("宿主 × 路线类型：%d 种；有搭档的 %d 种" % (len(host_opts), len(covered)))
    print("一对接法 %d 种（两座新城相距：%s）；两对接法 %d 种" % (len(one), dict(sorted(by_steps.items())), len(two)))
    if args.list:
        for t in one + two:
            print(topology_key(t))


def sha256_text(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def build_fixture_texts() -> dict[str, str]:
    """{相对路径: 文本}：每种接法一个参考牌堆文件、index.json、留一回测夹具、金样。"""
    files = {}
    one, two, _h = enumerate_topologies()
    params_sha = generator_params_sha256(json.loads(PARAMS_PATH.read_text(encoding="utf-8")))
    index = {"generator": VERSION, "generator_params_sha256": params_sha, "note":
             "tradegen_v1 参考牌堆（Python 参考实现输出，代号版：新货 id = x_<槽位>）。每个文件的内容 = 规范文本"
             "（键按字典序、无空白、整数按整数）；GDScript 生成器的输出按同一规范文本必须逐字节相同（T-G3a）。"
             "WP1 在 WP2 合入前可以按拓扑键查这里当生成器桩：把 x_<槽位> 换成真实货物 id 即可。"
             "generator_params_sha256 只覆盖生成器读的参数键（产品旋钮 max_pairs / max_user / bank_delta_per_city 不在内）。",
             "one_pair": {}, "two_pairs": {}}
    for group, topos in (("one_pair", one), ("two_pairs", two)):
        for topo in topos:
            key = topology_key(topo)
            res = tradegen_generate(topo)
            if not res["ok"]:
                raise RuntimeError("生成失败：%s %s" % (key, res["errors"]))
            name = fixture_name(key)
            text = canon(fixture_doc(topo, res)) + "\n"
            files[name] = text
            index[group][key] = {"file": name, "sha256": sha256_text(text)}
    files["index.json"] = json.dumps(index, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
    # 金样：B1–B8
    golden = {"generator": VERSION, "generator_params_sha256": params_sha,
              "note": "%s 金样（DESIGN 4.3 T-G3g）：B1–B6 一对 + B7、B8 两对。输出或生成器参数一旦变化，就必须出新的生成器版本号，"
                      "新版本写自己的金样文件；这个文件不许改（R19：发布过的版本冻结保留）。" % VERSION,
              "maps": {}}
    for name in sorted(B_TOPOLOGIES):
        topo = b_topology(name)
        res = tradegen_generate(topo)
        golden["maps"][name] = {"topology_key": topology_key(topo),
                                "sha256": sha256_text(canon(fixture_doc(topo, res)) + "\n"),
                                "decks": res["decks"]}
    files[GOLDEN_NAME] = json.dumps(golden, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
    # 留一回测：8 组参数 + Python 生成的 8 堆（GDScript 用同样的参数重建，逐字节比对并算回测指标）
    econ, D, rows, rows_base = run_backtest()
    loo = {"generator": VERSION, "note": "留一回测夹具（T-G3e）：每组参数只用另外 7 堆拟合；gen 是 Python 参考实现重建的那一堆"
           "（不开近源封顶、不开护栏）。", "folds": [],
           "python_metrics": {k: avg_metric([r[0] for r in rows], k) for k in METRIC_KEYS},
           "baseline_metrics": {k: avg_metric(rows_base, k) for k in METRIC_KEYS}}
    for m, gen, real, P in rows:
        loo["folds"].append({"hold": m["deck"], "city_ids": real["city_ids"], "params": params_to_doc_loo(P),
                             "gen_text": canon({"id": gen["id"], "city_ids": gen["city_ids"], "cards": gen["cards"]}),
                             "metrics": {k: m[k] for k in METRIC_KEYS}})
    files["loo_backtest.json"] = json.dumps(loo, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
    return files


def cmd_fixtures(args):
    files = build_fixture_texts()
    golden_path = FIXTURE_DIR / GOLDEN_NAME
    # 别的版本的金样（golden_v2.json …）永远保留：不算多余文件，也不删（R19）
    other_goldens = sorted(p.name for p in FIXTURE_DIR.glob("golden_*.json") if p.name != GOLDEN_NAME)
    if args.check:
        bad = 0
        for name, text in files.items():
            p = FIXTURE_DIR / name
            if not p.exists() or p.read_text(encoding="utf-8") != text:
                print("FIXTURE_CHECK 不一致：%s" % p)
                bad += 1
        extra = {p.name for p in FIXTURE_DIR.glob("*.json")} - set(files) - set(other_goldens)
        for name in sorted(extra):
            print("FIXTURE_CHECK 多余文件：%s" % name)
            bad += 1
        print("FIXTURE_CHECK %s files=%d bad=%d" % ("ok" if bad == 0 else "FAILED", len(files), bad))
        sys.exit(1 if bad else 0)
    new_golden = json.loads(files[GOLDEN_NAME])
    if golden_path.exists():
        # 金样只比生成器输出（maps）和生成器参数指纹；这两样任何一个变了，都只能出新版本，这个文件不覆盖。
        # 旧格式的金样没有 generator_params_sha256（绑的是整份参数文件），maps 相同时允许换成新格式。
        old = json.loads(golden_path.read_text(encoding="utf-8"))
        old_sha = old.get("generator_params_sha256")
        if old.get("maps") != new_golden["maps"] or (old_sha is not None and old_sha != new_golden["generator_params_sha256"]):
            print("金样变了：%s 的输出或生成器参数与冻结的 %s 不同。发布过的版本冻结保留（R19、T-G3g）：改 VERSION（如 tradegen_v2）、"
                  "另起 trade_gen_v2.gd 和它自己的参考牌堆目录，再用 --new-version 写 golden_v2.json；%s 不许改。"
                  % (VERSION, GOLDEN_NAME, GOLDEN_NAME))
            sys.exit(1)
    elif other_goldens and not args.new_version:
        print("%s 还没有金样，而目录里已有 %s：这是新版本的第一份金样，确认 VERSION 已经改过时加 --new-version。" % (VERSION, other_goldens))
        sys.exit(1)
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    for old in FIXTURE_DIR.glob("*.json"):
        if old.name not in files and old.name not in other_goldens:
            old.unlink()
    for name, text in files.items():
        (FIXTURE_DIR / name).write_text(text, encoding="utf-8")
    total = sum(len(t.encode("utf-8")) for t in files.values())
    print("写出 %d 个文件到 %s（共 %.1f KB）" % (len(files), FIXTURE_DIR, total / 1024))


def cmd_generate(args):
    topo = parse_topology_key(args.topology)
    gm = {}
    if args.goods:
        for kv in args.goods.split(","):
            k, v = kv.split("=")
            gm[k] = "x_%s_%s" % (k, v)
    res = tradegen_generate(topo, gm or None)
    econ = res["_econ"]
    names = dict(econ.good_names)
    for dk in res["decks"]:
        print("## %s" % dk["id"])
        for c in dk["cards"]:
            print("   %02d  %s" % (c["card_number"], " = ".join(
                "%s×%d" % (names.get(e["resource_id"], e["resource_id"]) if e["resource_kind"] == "GOOD" else "白银", e["quantity"]) for e in c["entries"])))
    print("ok=%s 近源封顶 %d 张 %s；护栏 %d 次 %s；errors=%s" % (res["ok"], len(res["cap_log"]), [x["card"] for x in res["cap_log"]],
          len(res["guard_log"]), res["guard_log"], res["errors"]))
    if args.json:
        Path(args.json).write_text(canon(fixture_doc(topo, res)) + "\n", encoding="utf-8")


def cmd_sweep(args):
    one, two, _h = enumerate_topologies()
    for label, topos in (("一对", one), ("两对", two)):
        st = sweep(topos)
        print("%s %d 种：失败 %d，违规 %d；近源封顶 %d 张；护栏修改 %d 次；经过新城单程最大 %.4f、往返最大 %.4f；"
              "白银均值 %.2f–%.2f；搭档收购价 %s；3 步短途每回合 中位 %.2f、p90 %.2f"
              % (label, st["n"], st["fail"], st["inv_violations"], st["cap_cards"], st["guard_changes"], st["one_way_max"],
                 st["two_way_max"], st["silver_mean_min"], st["silver_mean_max"], st["partner_prices"], st["short_median"], st["short_p90"]))


def cmd_extra_loops(args):
    """T-G3d 的三项补查覆盖全部 767 种接法：门槛取原版同口径的最大值（DESIGN 4.3：3.95 / 0.88 / 8），超过就退出码 1。"""
    out = extra_loops_report()
    b = out["base"]
    print("原版：以物易物三角 %.4f 银/回合；期望单程 %.4f；原地买卖一轮 %d 银" % (b["barter"], b["expected"], b["camp"]))
    w = out["new_worst"]
    print("新城（全部接法最大）：以物易物三角 %.4f（%s）；期望单程 %.4f（%s）；原地买卖一轮 %d（%s）"
          % (w["barter"][0], w["barter"][1], w["expected"][0], w["expected"][1], w["camp"][0], w["camp"][1]))
    bad = []
    if w["barter"][0] > b["barter"] + 1e-9:
        bad.append("以物易物三角 %.4f > 原版 %.4f" % (w["barter"][0], b["barter"]))
    if w["expected"][0] > b["expected"] + 1e-9:
        bad.append("期望单程 %.4f > 原版 %.4f" % (w["expected"][0], b["expected"]))
    if w["camp"][0] > b["camp"]:
        bad.append("原地买卖一轮 %d > 原版 %d" % (w["camp"][0], b["camp"]))
    print("EXTRA_LOOPS %s topologies=%d%s" % ("ok" if not bad else "FAILED", out["n"], ("：" + "；".join(bad)) if bad else ""))
    sys.exit(1 if bad else 0)


def cmd_crosscheck(args):
    """k9 取整、朴素均值两处统一做法，在全部接法上与原写法（精确均值、不取整）输出逐字节相同。"""
    global USE_K9, USE_NAIVE_MEAN
    one, two, _h = enumerate_topologies()
    diff = 0
    for topo in one + two:
        USE_K9, USE_NAIVE_MEAN = True, True
        a = canon(public_result(tradegen_generate(topo)))
        USE_K9, USE_NAIVE_MEAN = False, False
        b = canon(public_result(tradegen_generate(topo)))
        if a != b:
            diff += 1
            print("不同：%s" % topology_key(topo))
    USE_K9, USE_NAIVE_MEAN = True, True
    print("CROSSCHECK topologies=%d differ=%d" % (len(one) + len(two), diff))
    sys.exit(1 if diff else 0)


def cmd_selftest(args):
    """① 原版 80 张卡满足不变量；② 全部接法生成成功、不变量 0 违规、护栏后循环不超上限；③ 同一输入两次逐字节相同。"""
    fails = 0
    econ = Economy.from_ruleset()
    for dk in econ.decks:
        errs = validate_deck(dk, econ.goods, local_goods=set(deck_locals(econ, dk["city_ids"])))
        if errs:
            print("原版违例：", errs)
            fails += 1
    P = frozen_params()
    one, two, _h = enumerate_topologies()
    for topo in one + two:
        r1 = tradegen_generate(topo)
        r2 = tradegen_generate(topo)
        if canon(public_result(r1)) != canon(public_result(r2)):
            print("不确定：", topology_key(topo))
            fails += 1
        if not r1["ok"]:
            print("失败：", topology_key(topo), r1["errors"])
            fails += 1
        new = ["x_" + t["slot"] for t in topo]
        L = all_loops(r1["_econ"], r1["_D"], P.turns_table, city_filter=lambda A, B: A in new or B in new)
        W = two_way_loops(L, P.turns_table)
        if (L and L[0]["rate"] > P.loop_cap_one_way + P.loop_cap_eps) or (W and W[0]["rate"] > P.loop_cap_two_way + P.loop_cap_eps):
            print("护栏失效：", topology_key(topo))
            fails += 1
    print("SELFTEST 原版 8 堆 + %d 种接法；失败 %d" % (len(one) + len(two), fails))
    sys.exit(1 if fails else 0)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("params")
    p.add_argument("--check", action="store_true")
    t = sub.add_parser("topologies")
    t.add_argument("--list", action="store_true")
    f = sub.add_parser("fixtures")
    f.add_argument("--check", action="store_true")
    f.add_argument("--new-version", action="store_true")
    g = sub.add_parser("generate")
    g.add_argument("--topology", required=True)
    g.add_argument("--goods", help="e1=kaolin,w1=coral")
    g.add_argument("--json")
    sub.add_parser("sweep")
    sub.add_parser("extra-loops")
    sub.add_parser("crosscheck")
    sub.add_parser("backtest")
    sub.add_parser("loops")
    sub.add_parser("selftest")
    args = ap.parse_args(argv)
    {"params": cmd_params, "topologies": cmd_topologies, "fixtures": cmd_fixtures, "generate": cmd_generate,
     "sweep": cmd_sweep, "extra-loops": cmd_extra_loops, "crosscheck": cmd_crosscheck,
     "backtest": lambda a: print_backtest(), "loops": lambda a: loop_report(), "selftest": cmd_selftest}[args.cmd](args)


if __name__ == "__main__":
    main()
