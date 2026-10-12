#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""analyze.py — 自制地图 AI 对局模拟的报告与胜场白名单（DESIGN 4.4，WP2）。

读 sim_run.gd 写的逐局 jsonl（run_batch.sh 的输出目录），按「同一批种子、同一座位配置、同一代理」把自制地图和原版配对，
算 S1–S12，按 B 档 / A 档门槛判断，写 Markdown 报告（中文）和数字摘要；--whitelist 时，只有样本量达到 4.4 的要求、
B1–B6 全部过 B 档、这种接法过 A 档，才写进胜场白名单。样本不够时报告写「样本不足，不判」，白名单不写。

数据完整性：run_batch.sh 给每一块写了 .plan（应当跑哪些种子），少写的局一律算进 S1 失败。
代理自检：原版上三种代理必须逐局相同（没有新城时三种代理都退回电脑策略）；地图上 avoid_new 的「真人回合原地结束」
比例不许超过 proxy_same + 5 个百分点（否则它量的是被自己卡住的玩家）。自检或 S1 不过时退出码 1，白名单不写。
白名单只拿 bank_k == 参数文件里的 k 的记录（S7 标定时另传 bank= 跑出来的数据不算），并把生成器版本和 k 写进白名单。
摘要写成 jsonl（第一行 S1 和自检，之后每张图一行）：发布包的导出预设按 *.json 收文件，报告目录里不放 .json。

用法
  python3 analyze.py <runs 目录> --report <report.md> [--summary <summary.jsonl>] [--title 标题]
                     [--whitelist <data/custom_map/validated_topologies_v1.json>] [--smoke]
"""
from __future__ import annotations

import argparse
import datetime
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path

B_KEYS = {
    "B1": "topo_v1|e1:changan:LAND:w1|w1:aden:SEA:e1",
    "B2": "topo_v1|e1:heijokyo:SEA:w1|w1:rome:SEA:e1",
    "B3": "topo_v1|e1:simhala:LAND:w1|w1:baghdad:LAND:e1",
    "B4": "topo_v1|e1:dagon:SEA:w1|w1:panti:LAND:e1",
    "B5": "topo_v1|e1:geumseong:SEA:w1|w1:cairo:SEA:e1",
    "B6": "topo_v1|e1:yumenguan:LAND:w1|w1:jeddah:LAND:e1",
    "B7": "topo_v1|e1:changan:LAND:w1|e2:heijokyo:SEA:w2|w1:aden:SEA:e1|w2:rome:SEA:e2",
    "B8": "topo_v1|e1:simhala:LAND:w1|e2:geumseong:SEA:w2|w1:baghdad:LAND:e1|w2:cairo:SEA:e2",
}
NAME_OF_KEY = {v: k for k, v in B_KEYS.items()}
PROXIES = ["same", "avoid_new", "best_loop"]
REPO = Path(__file__).resolve().parents[3]
PARAMS_PATH = REPO / "data" / "custom_map" / "tradegen_v1_params.json"
STILL_SLACK = 0.05          # 代理自检：avoid_new 的真人原地回合比例 ≤ proxy_same + 5 个百分点
# 记录里这些字段与代理、运行无关；原版上三种代理的其余字段必须逐局相同
VOLATILE = ("tag", "proxy", "ms")
TIERS = ["qingzhuang", "shanhai", "wanli"]
# 4.4 的样本量（每组）
NEED = {"B": {"S2": 2000, "S3": 2000, "S6": 2000, "S7": 400, "S8": 600, "S11": 2000},
        "A": {"S2": 600, "S3": 400, "S7": 200}}
# 4.4 的门槛
TH = {
    "B": {"S2": 3.0, "S3": 4.0, "S4": (-6.0, 4.0), "S5": 5.0, "S6": 3.0, "S7": (0.90, 1.10), "S9": (0.5, 2.0),
          "S10": 1.5, "S10b": 1.5},
    "A": {"S2": 5.0, "S3": 6.0, "S4": (-9.0, 6.0), "S5": 7.0, "S7": (0.90, 1.10), "S9": (0.4, 2.5),
          "S10": 2.0, "S10b": 2.0},
}


def load_runs(run_dir: Path) -> list[dict]:
    recs = []
    for f in sorted(run_dir.glob("*.jsonl")):
        if f.name.startswith("summary"):
            continue
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                recs.append(json.loads(line))
    return recs


def missing_games(run_dir: Path) -> list[str]:
    """按 run_batch.sh 写的 .plan 核对：每一块应当有的种子是否都写出来了。返回缺局说明。"""
    out = []
    for plan in sorted(run_dir.glob("*.plan")):
        kv = dict(x.split("=", 1) for x in plan.read_text(encoding="utf-8").split())
        want = set(range(int(kv["first"]), int(kv["first"]) + int(kv["seeds"])))
        got = set()
        jl = run_dir / kv["jsonl"]
        if jl.exists():
            for line in jl.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    got.add(int(json.loads(line)["seed"]))
        lost = sorted(want - got)
        if lost:
            out.append("%s：缺 %d 局（种子 %d…）" % (kv["jsonl"], len(lost), lost[0]))
    return out


def params_bank() -> tuple[str, dict]:
    doc = json.loads(PARAMS_PATH.read_text(encoding="utf-8"))
    return doc.get("generator", ""), {str(k): int(v) for k, v in doc.get("bank_delta_per_city", {}).items()}


def gkey(r: dict) -> tuple:
    return (r.get("seats", ""), r.get("diffs", ""), r.get("proxy", ""), r.get("policy", "formal"), int(r.get("rounds_cap", 0)))


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else float("nan")


def paired_delta(base: dict, mp: dict, f) -> tuple[float, float, int]:
    """同种子配对：(均值差, 95% 区间半宽, 对数)；f(rec) → 数。"""
    seeds = sorted(set(base) & set(mp))
    d = [f(mp[s]) - f(base[s]) for s in seeds]
    if not d:
        return float("nan"), float("nan"), 0
    m = mean(d)
    hw = 1.96 * statistics.stdev(d) / math.sqrt(len(d)) if len(d) > 1 else float("nan")
    return m, hw, len(d)


def seat_win(i):
    return lambda r: float(r["players"][i]["win_share"]) if r.get("ok") else 0.0


def fmt(x, nd=2):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "—"
    return ("%." + str(nd) + "f") % x


class Analysis:
    def __init__(self, recs: list[dict]):
        self.recs = recs
        self.by = defaultdict(dict)       # (key, gkey) → {seed: rec}
        for r in recs:
            self.by[(r.get("key", ""), gkey(r))][int(r["seed"])] = r
        self.keys = sorted({r.get("key", "") for r in recs if r.get("key", "")}, key=lambda k: (NAME_OF_KEY.get(k, "Z"), k))

    def group(self, key, seats, diffs, proxy, policy, rounds):
        return self.by.get((key, (seats, diffs, proxy, policy, rounds)), {})

    # ---------- S1 ----------
    def s1(self, missing=()):
        bad = [r for r in self.recs if not r.get("ok")]
        n_missing = sum(int(m.split("缺 ")[1].split(" 局")[0]) for m in missing)
        return {"games": len(self.recs), "failed": len(bad) + n_missing, "max_commands": sum(1 for r in bad if r.get("why") == "MAX_COMMANDS"),
                "missing": n_missing, "missing_detail": list(missing)[:10],
                "examples": [("%s seed=%s %s" % (r.get("tag"), r.get("seed"), r.get("why"))) for r in bad[:5]]}

    # ---------- 代理自检 ----------
    def proxy_checks(self) -> dict:
        """原版上三种代理逐局相同；地图上 avoid_new 的真人原地回合比例 ≤ proxy_same + 5 个百分点。"""
        problems = []
        rows = []
        groups = defaultdict(dict)          # (key, seats, diffs, policy, rounds) → {proxy: {seed: rec}}
        for (key, g), recs in self.by.items():
            seats, diffs, proxy, policy, rounds = g
            if proxy in PROXIES:
                groups[(key, seats, diffs, policy, rounds)][proxy] = recs
        for (key, seats, diffs, policy, rounds), by_px in sorted(groups.items()):
            if key == "":
                if len(by_px) < 2:
                    continue
                ref_px = "same" if "same" in by_px else sorted(by_px)[0]
                ref = by_px[ref_px]
                diff_n = 0
                pairs = 0
                for px, recs in by_px.items():
                    if px == ref_px:
                        continue
                    for seed in sorted(set(ref) & set(recs)):
                        pairs += 1
                        a = {k: v for k, v in ref[seed].items() if k not in VOLATILE}
                        b = {k: v for k, v in recs[seed].items() if k not in VOLATILE}
                        if a != b:
                            diff_n += 1
                rows.append({"check": "base_identical", "group": "%s/%s/%s/%d" % (seats, diffs, policy, rounds),
                             "proxies": sorted(by_px), "pairs": pairs, "differ": diff_n})
                if diff_n:
                    problems.append("原版 %s %s：三种代理有 %d/%d 局不同（没有新城时应逐局相同）" % (seats, diffs, diff_n, pairs))
            elif "same" in by_px and "avoid_new" in by_px:
                def still(recs):
                    t = sum(int(r.get("human_turns", 0)) for r in recs.values())
                    s_ = sum(int(r.get("human_still", 0)) for r in recs.values())
                    return (s_ / t) if t else float("nan"), t
                r_same, t_same = still(by_px["same"])
                r_av, t_av = still(by_px["avoid_new"])
                ok = not (math.isnan(r_same) or math.isnan(r_av)) and r_av <= r_same + STILL_SLACK
                rows.append({"check": "avoid_new_still", "map": NAME_OF_KEY.get(key, key), "group": "%s/%s/%s/%d" % (seats, diffs, policy, rounds),
                             "same": r_same, "avoid_new": r_av, "turns": [t_same, t_av], "ok": ok})
                if not ok:
                    problems.append("%s %s %s：avoid_new 真人回合原地结束 %.1f%% > proxy_same %.1f%% + 5 个百分点"
                                    % (NAME_OF_KEY.get(key, key), seats, diffs, 100 * r_av, 100 * r_same))
        return {"ok": not problems, "problems": problems, "rows": rows}

    # ---------- 每张图 ----------
    def per_map(self, key: str) -> dict:
        out = {"key": key, "name": NAME_OF_KEY.get(key, key)}
        hosts = None
        # S2 / S4 / S9 / S12：2 人 36 轮，对手山海
        s2 = {}
        s4 = {}
        s9_trades = defaultdict(int)
        s12 = {"games": 0, "opened": 0, "partner_sale_games": 0, "away_sale_games": 0}
        orig_far = defaultdict(int)
        orig_games = 0
        for px in PROXIES:
            b = self.group("", "HA", "shanhai", px, "formal", 36)
            m = self.group(key, "HA", "shanhai", px, "formal", 36)
            if not m:
                continue
            d, hw, n = paired_delta(b, m, seat_win(0))
            s2[px] = {"delta_pp": 100 * d, "ci_pp": 100 * hw, "n": n}
            any_rec = next(iter(m.values()))
            hosts = set(any_rec.get("hosts", []))
            host_share = lambda r, hs=hosts: sum(float(p["win_share"]) for p in r["players"] if p.get("start_city") in hs) if r.get("ok") else 0.0
            d4, hw4, n4 = paired_delta(b, m, host_share)
            s4[px] = {"delta_pp": 100 * d4, "ci_pp": 100 * hw4, "n": n4}
            for r in m.values():
                for c, k in r.get("trades_by_city", {}).items():
                    s9_trades[c] += int(k)
                s12["games"] += 1
                s12["opened"] += 1 if int(r.get("opened_new", 0)) > 0 else 0
                s12["partner_sale_games"] += 1 if int(r.get("new_good_partner_units", 0)) > 0 else 0
                s12["away_sale_games"] += 1 if int(r.get("new_good_away_units", 0)) > 0 else 0
            for r in b.values():
                orig_games += 1
                for g in r.get("orig_far_sold", []):
                    orig_far[g] += 1
        out["S2"] = s2
        out["S4"] = s4
        # S9：新城人气 = 在这座新城成交的份额 ÷ 原城的平均份额
        total = sum(s9_trades.values())
        newc = [c for c in s9_trades if c.startswith("x_")]
        any_rec = None
        for px in PROXIES:
            m = self.group(key, "HA", "shanhai", px, "formal", 36)
            if m:
                any_rec = next(iter(m.values()))
                break
        if any_rec:
            newc = sorted(set(newc) | set(any_rec.get("new_cities", [])))
        s9 = {}
        if total > 0:
            orig_share = [s9_trades.get(c, 0) / total for c in s9_trades if not c.startswith("x_")]
            orig_mean = sum(orig_share) / 16.0 if orig_share else 0.0
            for c in newc:
                s9[c] = (s9_trades.get(c, 0) / total) / orig_mean if orig_mean > 0 else float("nan")
        out["S9"] = s9
        # S12（只报告）
        orig_rates = sorted(v / orig_games for v in orig_far.values()) if orig_games else []
        # 14 种原版特产里没卖出过的按 0 计
        while orig_games and len(orig_rates) < 14:
            orig_rates.insert(0, 0.0)
        s12["opened_rate"] = s12["opened"] / s12["games"] if s12["games"] else float("nan")
        s12["partner_sale_rate"] = s12["partner_sale_games"] / s12["games"] if s12["games"] else float("nan")
        s12["away_sale_rate"] = s12["away_sale_games"] / s12["games"] if s12["games"] else float("nan")
        s12["orig_far_median"] = statistics.median(orig_rates) if orig_rates else float("nan")
        s12["orig_far_mean"] = mean(orig_rates) if orig_rates else float("nan")
        out["S12"] = s12
        # S3：3 人 24 轮、4 人 18 轮，各座位
        s3 = {}
        for seats, rounds in (("HAA", 24), ("HAAA", 18)):
            for px in PROXIES:
                b = self.group("", seats, "shanhai", px, "formal", rounds)
                m = self.group(key, seats, "shanhai", px, "formal", rounds)
                if not m:
                    continue
                for i in range(len(seats)):
                    d, hw, n = paired_delta(b, m, seat_win(i))
                    s3["%s_%s_seat%d" % (seats, px, i + 1)] = {"delta_pp": 100 * d, "ci_pp": 100 * hw, "n": n}
        out["S3"] = s3
        # S5：截断白银总量（2/3/4 人），按代理分开报；判定只看 proxy_same（量的是经济流速，不是代理本身强弱；
        # 4.4 没写 S5 要不要三种代理取最大，这里取这个口径并在报告里写明）
        s5 = {}
        for seats, rounds in (("HA", 36), ("HAA", 24), ("HAAA", 18)):
            for px in PROXIES:
                b = self.group("", seats, "shanhai", px, "formal", rounds)
                m = self.group(key, seats, "shanhai", px, "formal", rounds)
                seeds = sorted(set(b) & set(m))
                if seeds:
                    bs = [b[x]["total_silver"] for x in seeds]
                    ms = [m[x]["total_silver"] for x in seeds]
                    s5["%s_%s" % (seats, px)] = {"seats": seats, "proxy": px, "change_pct": 100 * (mean(ms) / mean(bs) - 1), "n": len(seeds)}
        out["S5"] = s5
        # S6：真人代理对三档 AI（2 人 36 轮）
        s6 = {}
        for tier in TIERS:
            for px in PROXIES:
                b = self.group("", "HA", tier, px, "formal", 36)
                m = self.group(key, "HA", tier, px, "formal", 36)
                if not m or tier == "shanhai" and not b:
                    continue
                d, hw, n = paired_delta(b, m, seat_win(0))
                s6["%s_%s" % (tier, px)] = {"delta_pp": 100 * d, "ci_pp": 100 * hw, "n": n}
        out["S6"] = s6
        # S7：不限时局长（不死等），同种子轮数比的几何均值
        s7 = {}
        for seats in ("HA", "HAA", "HAAA"):
            b = self.group("", seats, "shanhai", "nostall", "nostall", 0)
            m = self.group(key, seats, "shanhai", "nostall", "nostall", 0)
            seeds = [s for s in sorted(set(b) & set(m)) if b[s].get("ok") and m[s].get("ok")]
            if seeds:
                lr = [math.log(m[s]["rounds"] / b[s]["rounds"]) for s in seeds]
                gm = math.exp(mean(lr))
                hw = 1.96 * statistics.stdev(lr) / math.sqrt(len(lr)) if len(lr) > 1 else float("nan")
                s7[seats] = {"gmean": gm, "lo": math.exp(math.log(gm) - hw) if not math.isnan(hw) else float("nan"),
                             "hi": math.exp(math.log(gm) + hw) if not math.isnan(hw) else float("nan"), "n": len(seeds)}
        out["S7"] = s7
        # S8：不限时长尾（正式 AI + X3）
        b = self.group("", "HA", "shanhai", "same", "formal", 0)
        m = self.group(key, "HA", "shanhai", "same", "formal", 0)
        if m and b:
            br = [r["rounds"] for r in b.values() if r.get("ok")]
            mr = [r["rounds"] for r in m.values() if r.get("ok")]
            out["S8"] = {"base_over200": mean(1.0 if x > 200 else 0.0 for x in br), "map_over200": mean(1.0 if x > 200 else 0.0 for x in mr),
                         "base_max": max(br) if br else 0, "map_max": max(mr) if mr else 0, "n": len(mr)}
        # S10 / S10b：所有截断局（正式 AI + X3）
        st = {"new_stall": 0, "new_turns": 0, "orig_stall": 0, "orig_turns": 0, "new_streaks": [], "orig_streaks": [],
              "games": 0, "noprog8_new": 0, "noprog8_orig": 0, "by_diff": defaultdict(lambda: {"new": [], "orig": []})}
        for (k, g), recs in self.by.items():
            if k != key or g[3] != "formal" or g[4] <= 0:
                continue
            for r in recs.values():
                if not r.get("ok"):
                    continue
                st["games"] += 1
                st["new_stall"] += r["stall"]["new"]
                st["orig_stall"] += r["stall"]["orig"]
                st["new_turns"] += r["ai_turns"]["new"]
                st["orig_turns"] += r["ai_turns"]["orig"]
                st["new_streaks"].append(r["stall_streak_max"]["new"])
                st["orig_streaks"].append(r["stall_streak_max"]["orig"])
                st["noprog8_new"] += int(r["noprog8"]["new"])
                st["noprog8_orig"] += int(r["noprog8"]["orig"])
                for dk, v in r.get("noprog_streak_max", {}).items():
                    st["by_diff"][dk]["new"].append(v["new"])
                    st["by_diff"][dk]["orig"].append(v["orig"])

        def p95(xs):
            xs = sorted(xs)
            return xs[min(len(xs) - 1, int(0.95 * len(xs)))] if xs else 0

        out["S10"] = {"new_rate": st["new_stall"] / st["new_turns"] if st["new_turns"] else 0.0,
                      "orig_rate": st["orig_stall"] / st["orig_turns"] if st["orig_turns"] else 0.0,
                      "new_p95": p95(st["new_streaks"]), "orig_p95": p95(st["orig_streaks"]),
                      "new_turns": st["new_turns"], "games": st["games"]}
        out["S10b"] = {"new_rate": st["noprog8_new"] / st["games"] if st["games"] else 0.0,
                       "orig_rate": st["noprog8_orig"] / st["games"] if st["games"] else 0.0, "games": st["games"],
                       "by_diff": {dk: {"new_p95": p95(v["new"]), "orig_p95": p95(v["orig"]), "new_ge8": mean(1.0 if x >= 8 else 0.0 for x in v["new"])}
                                   for dk, v in st["by_diff"].items()}}
        # S11：三档电脑同桌（3 人 24 轮）
        m = self.group(key, "AAA", "qingzhuang,shanhai,wanli", "same", "formal", 24)
        if m:
            rates = {}
            for i, t in enumerate(TIERS):
                rates[t] = mean(float(r["players"][i]["win_share"]) for r in m.values() if r.get("ok"))
            out["S11"] = {"rates": rates, "order_ok": rates["wanli"] > rates["shanhai"] > rates["qingzhuang"], "n": len(m)}
        return out

    def verdict(self, pm: dict, tier: str) -> dict:
        """每项 PASS / FAIL / 样本不足；white = 全部判得出且全部通过。"""
        th = TH[tier]
        need = NEED[tier]
        v = {}

        def enough(metric, n):
            return n >= need.get(metric, 0)

        s2 = pm.get("S2", {})
        if len(s2) < 3:
            v["S2"] = ("缺代理", False)
        else:
            worst = max(abs(x["delta_pp"]) for x in s2.values())
            n = min(x["n"] for x in s2.values())
            v["S2"] = (("PASS" if worst <= th["S2"] else "FAIL") if enough("S2", n) else "样本不足", enough("S2", n) and worst <= th["S2"])
        s3 = pm.get("S3", {})
        # 3 种代理 × {HAA 3 个座位, HAAA 4 个座位} = 21 组，缺一组都不判
        want3 = {"%s_%s_seat%d" % (seats, px, i + 1) for px in PROXIES for seats in ("HAA", "HAAA") for i in range(len(seats))}
        if not s3:
            v["S3"] = ("没跑", False)
        elif not want3 <= set(s3):
            v["S3"] = ("缺代理或缺座位配置（%d/%d 组）" % (len(want3 & set(s3)), len(want3)), False)
        else:
            worst = max(abs(x["delta_pp"]) for x in s3.values())
            n = min(x["n"] for x in s3.values())
            v["S3"] = (("PASS" if worst <= th["S3"] else "FAIL") if enough("S3", n) else "样本不足", enough("S3", n) and worst <= th["S3"])
        s4 = pm.get("S4", {})
        if s4:
            lo, hi = th["S4"]
            ok = all(lo <= x["delta_pp"] <= hi for x in s4.values())
            n = min(x["n"] for x in s4.values())
            v["S4"] = (("PASS" if ok else "FAIL") if enough("S2", n) else "样本不足", enough("S2", n) and ok)
        s5 = [x for x in pm.get("S5", {}).values() if x["proxy"] == "same"]
        if s5:
            ok = all(abs(x["change_pct"]) <= th["S5"] for x in s5)
            n = min(x["n"] for x in s5)
            v["S5"] = (("PASS" if ok else "FAIL") if enough("S2", n) else "样本不足", enough("S2", n) and ok and len(s5) == 3)
        if tier == "B":
            s6 = pm.get("S6", {})
            if len(s6) < 9:
                v["S6"] = ("缺档或缺代理", False)
            else:
                worst = max(abs(x["delta_pp"]) for x in s6.values())
                n = min(x["n"] for x in s6.values())
                v["S6"] = (("PASS" if worst <= th["S6"] else "FAIL") if enough("S6", n) else "样本不足", enough("S6", n) and worst <= th["S6"])
            s8 = pm.get("S8")
            if s8:
                ok = s8["map_over200"] <= s8["base_over200"] + 0.02 and s8["map_max"] <= s8["base_max"] * 1.2
                v["S8"] = (("PASS" if ok else "FAIL") if enough("S8", s8["n"]) else "样本不足", enough("S8", s8["n"]) and ok)
            else:
                v["S8"] = ("没跑", False)
            s11 = pm.get("S11")
            if s11:
                v["S11"] = (("PASS" if s11["order_ok"] else "FAIL") if enough("S11", s11["n"]) else "样本不足", enough("S11", s11["n"]) and s11["order_ok"])
            else:
                v["S11"] = ("没跑", False)
        s7 = pm.get("S7", {})
        if len(s7) < 3:
            v["S7"] = ("没跑全", False)
        else:
            lo, hi = th["S7"]
            ok = all(lo <= x["gmean"] <= hi for x in s7.values())
            n = min(x["n"] for x in s7.values())
            v["S7"] = (("PASS" if ok else "FAIL") if enough("S7", n) else "样本不足", enough("S7", n) and ok)
        s9 = pm.get("S9", {})
        if s9:
            lo, hi = th["S9"]
            ok = all(lo <= x <= hi for x in s9.values())
            v["S9"] = ("PASS" if ok else "FAIL", ok and v.get("S2", ("", False))[1])
        s10 = pm["S10"]
        ok10 = s10["new_rate"] <= s10["orig_rate"] * th["S10"] + 1e-12 and (tier == "A" or s10["new_p95"] <= s10["orig_p95"])
        v["S10"] = ("PASS" if ok10 else "FAIL", ok10)
        s10b = pm["S10b"]
        ok10b = s10b["new_rate"] <= s10b["orig_rate"] * th["S10b"] + 1e-12
        v["S10b"] = ("PASS" if ok10b else "FAIL", ok10b)
        white = all(x[1] for x in v.values())
        return {"items": {k: x[0] for k, x in v.items()}, "white": white}


def write_report(an: Analysis, results: dict, path: Path, title: str, smoke: bool, s1: dict, pc: dict) -> None:
    L = []
    L.append("# %s" % title)
    L.append("")
    L.append("- 生成：%s，`tools/custom_map/sim/analyze.py`。数据：%d 局（失败 %d，撞 MAX_COMMANDS %d）。" % (
        datetime.date.today().isoformat(), s1["games"], s1["failed"], s1["max_commands"]))
    if smoke:
        L.append("- **这是冒烟，不是验收。** 用的是内存覆盖层（`sim_overlay.gd`，WP1 合入前的替身），样本远小于 DESIGN 4.4 的要求；"
                 "数字只说明驱动、三种真人代理和每个指标都算得出来。正式模拟要等 WP1 集成后走真实加载路径（`mode=real`），"
                 "按 4.4 的样本量重跑，再出白名单。")
    L.append("- 差值一律是「自制地图 − 原版」，同一批种子配对；± 是 95% 区间半宽。胜率差单位是百分点。")
    L.append("")
    L.append("## S1 失败与卡死命令")
    L.append("")
    L.append("- 全部 %d 局：失败 %d（其中按 .plan 核对缺写 %d 局），撞 MAX_COMMANDS（40,000）%d。%s" % (
             s1["games"], s1["failed"], s1["missing"], s1["max_commands"],
             ("例：" + "；".join(s1["examples"] + s1["missing_detail"])) if (s1["examples"] or s1["missing_detail"]) else "门槛 0：通过。"))
    L.append("")
    L.append("## 代理自检")
    L.append("")
    L.append("- 结论：%s" % ("通过" if pc["ok"] else "**不通过**：" + "；".join(pc["problems"])))
    for row in pc["rows"]:
        if row["check"] == "base_identical":
            L.append("- 原版 %s：代理 %s 逐局比对 %d 对，不同 %d 对。" % (row["group"], "、".join(row["proxies"]), row["pairs"], row["differ"]))
        else:
            L.append("- %s %s：真人回合原地结束 proxy_same %s%%、avoid_new %s%%（门槛：avoid_new ≤ same + 5 个百分点）%s" % (
                row["map"], row["group"], fmt(100 * row["same"], 1), fmt(100 * row["avoid_new"], 1), "" if row["ok"] else "，**超了**"))
    L.append("")
    for key, res in results.items():
        pm = res["metrics"]
        L.append("## %s　`%s`" % (pm["name"], key))
        L.append("")
        vb = res.get("verdict_B")
        va = res.get("verdict_A")
        if vb:
            L.append("- B 档判定：" + "，".join("%s %s" % (k, x) for k, x in vb["items"].items()))
        if va:
            L.append("- A 档判定：" + "，".join("%s %s" % (k, x) for k, x in va["items"].items()))
        L.append("")
        L.append("| 指标 | 结果 |")
        L.append("|---|---|")
        s2 = pm.get("S2", {})
        L.append("| S2 先手胜率变化（2 人 36 轮） | %s |" % ("；".join("%s %s±%s（n=%d）" % (px, fmt(x["delta_pp"], 1), fmt(x["ci_pp"], 1), x["n"]) for px, x in s2.items()) or "—"))
        s3 = pm.get("S3", {})
        if s3:
            worst = max(s3.items(), key=lambda kv: abs(kv[1]["delta_pp"]))
            L.append("| S3 各座位胜率变化（3 人 24 轮、4 人 18 轮） | 最大 |Δ| 在 %s：%s±%s（n=%d）；共 %d 组 |" % (
                worst[0], fmt(worst[1]["delta_pp"], 1), fmt(worst[1]["ci_pp"], 1), worst[1]["n"], len(s3)))
        s4 = pm.get("S4", {})
        L.append("| S4 宿主起点玩家胜率合计变化 | %s |" % ("；".join("%s %s±%s" % (px, fmt(x["delta_pp"], 1), fmt(x["ci_pp"], 1)) for px, x in s4.items()) or "—"))
        s5 = pm.get("S5", {})
        L.append("| S5 截断白银总量变化（判定只看 same） | %s |" % ("；".join("%s 人 %s %s%%（n=%d）" % (len(x["seats"]), x["proxy"], fmt(x["change_pct"], 1), x["n"]) for x in s5.values()) or "—"))
        s6 = pm.get("S6", {})
        if s6:
            L.append("| S6 真人代理对三档 AI | %s |" % "；".join("%s %s±%s（n=%d）" % (k, fmt(x["delta_pp"], 1), fmt(x["ci_pp"], 1), x["n"]) for k, x in s6.items()))
        s7 = pm.get("S7", {})
        if s7:
            L.append("| S7 不限时局长（所有座位都用不死等策略）几何均值比 | %s |" % "；".join("%s 人 %s（%s–%s，n=%d）" % (len(k), fmt(x["gmean"], 3), fmt(x["lo"], 3), fmt(x["hi"], 3), x["n"]) for k, x in s7.items()))
        s8 = pm.get("S8")
        if s8:
            L.append("| S8 不限时长尾（正式 AI + X3） | 超过 200 轮：原版 %s%% → 地图 %s%%；最长 %d → %d（n=%d） |" % (
                fmt(100 * s8["base_over200"], 1), fmt(100 * s8["map_over200"], 1), s8["base_max"], s8["map_max"], s8["n"]))
        s9 = pm.get("S9", {})
        L.append("| S9 新城人气 | %s |" % ("；".join("%s %s" % (c, fmt(x, 2)) for c, x in s9.items()) or "—"))
        s10 = pm["S10"]
        L.append("| S10 卡死率（新城 / 原城） | %s%% / %s%%；最长连续卡死 p95 %d / %d（%d 局，新城 AI 回合 %d） |" % (
            fmt(100 * s10["new_rate"], 1), fmt(100 * s10["orig_rate"], 1), s10["new_p95"], s10["orig_p95"], s10["games"], s10["new_turns"]))
        s10b = pm["S10b"]
        L.append("| S10b 有 AI 连续无进展 ≥ 8 回合的对局（新城 / 原城） | %s%% / %s%%；按难度：%s |" % (
            fmt(100 * s10b["new_rate"], 1), fmt(100 * s10b["orig_rate"], 1),
            "；".join("%s 新城 p95 %d、原城 p95 %d" % (dk, v["new_p95"], v["orig_p95"]) for dk, v in sorted(s10b["by_diff"].items()))))
        s11 = pm.get("S11")
        if s11:
            L.append("| S11 难度梯度（三档同桌） | %s；顺序%s（n=%d） |" % ("、".join("%s %s%%" % (t, fmt(100 * s11["rates"][t], 1)) for t in TIERS),
                     "保持" if s11["order_ok"] else "没保持", s11["n"]))
        s12 = pm["S12"]
        L.append("| S12 新特产流通（只报告） | 开通至少 1 座新城的对局 %s%%；新特产从别处运到搭档牌堆卖出的对局 %s%%（运到产地以外任何城卖出 %s%%；"
                 "只数不是在卖出城买进的件，原地倒腾不算）；"
                 "原版对照：一种原版特产在离产地 ≥ 15 步处按牌面卖出的对局比例，中位 %s%%、平均 %s%% |" % (
                     fmt(100 * s12["opened_rate"], 1), fmt(100 * s12["partner_sale_rate"], 1), fmt(100 * s12["away_sale_rate"], 1),
                     fmt(100 * s12["orig_far_median"], 1), fmt(100 * s12["orig_far_mean"], 1)))
        L.append("")
    path.write_text("\n".join(L) + "\n", encoding="utf-8")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs")
    ap.add_argument("--report", required=True)
    ap.add_argument("--summary")
    ap.add_argument("--title", default="自制地图 AI 对局模拟报告")
    ap.add_argument("--whitelist")
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args(argv)
    recs = load_runs(Path(args.runs))
    an = Analysis(recs)
    s1 = an.s1(missing_games(Path(args.runs)))
    pc = an.proxy_checks()
    results = {}
    for key in an.keys:
        pm = an.per_map(key)
        res = {"metrics": pm}
        if key in B_KEYS.values():
            res["verdict_B"] = an.verdict(pm, "B")
        res["verdict_A"] = an.verdict(pm, "A")
        results[key] = res
    write_report(an, results, Path(args.report), args.title, args.smoke, s1, pc)
    if args.summary:
        lines = [json.dumps({"S1": s1, "proxy_checks": pc}, ensure_ascii=False, default=str)]
        for key, res in results.items():
            lines.append(json.dumps({"key": key, **res}, ensure_ascii=False, default=str))
        Path(args.summary).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("REPORT %s maps=%d games=%d failed=%d missing=%d proxy_check=%s" % (args.report, len(results), s1["games"], s1["failed"],
          s1["missing"], "ok" if pc["ok"] else "FAILED"))
    for prob in pc["problems"]:
        print("PROXY_CHECK %s" % prob)
    rc = 0 if (pc["ok"] and s1["failed"] == 0) else 1
    if args.whitelist:
        if args.smoke:
            print("WHITELIST 冒烟模式不写白名单")
            sys.exit(rc)
        # 白名单绑定生成器版本和银库 k（3.16）：只拿 k 与参数文件相同的记录；有一条不同就整份拒写
        gen, bank = params_bank()
        bad_bank = [r for r in recs if r.get("key") and (r.get("bank_k") is None or int(r.get("bank_k")) != int(r.get("bank_k_file", -99))
                    or int(r.get("bank_k_file", -99)) != bank.get(str(len(r.get("players", []))), -99))]
        bad_gen = [r for r in recs if r.get("generator") != gen]
        if bad_bank or bad_gen or rc != 0:
            print("WHITELIST 不写：银库 k 与参数文件不一致的记录 %d 条、生成器版本不一致 %d 条、S1/代理自检%s"
                  % (len(bad_bank), len(bad_gen), "通过" if rc == 0 else "不通过"))
            sys.exit(1)
        # 一对接法：B1–B6 全部过 B 档；两对接法（D1 选两对时）：另外 B7、B8 也要过 B 档（DESIGN 4.4）
        b_ok = all(results.get(B_KEYS[b], {}).get("verdict_B", {}).get("white", False) for b in ("B1", "B2", "B3", "B4", "B5", "B6"))
        b2_ok = b_ok and all(results.get(B_KEYS[b], {}).get("verdict_B", {}).get("white", False) for b in ("B7", "B8"))
        topos = {}
        if b_ok and s1["failed"] == 0:
            for key, res in results.items():
                pairs = key.count("|") // 2
                if res["verdict_A"]["white"] and (pairs == 1 or (pairs == 2 and b2_ok)):
                    topos[key] = {"passed_at": datetime.date.today().isoformat(), "tier": "A"}
        wl_path = Path(args.whitelist)
        doc = json.loads(wl_path.read_text(encoding="utf-8"))
        doc["generator"] = gen
        doc["bank_delta_per_city"] = bank
        doc["topologies"] = topos
        doc["sim_report"] = str(args.report)
        wl_path.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print("WHITELIST b_tier_one_pair=%s b_tier_two_pairs=%s topologies=%d -> %s" % (b_ok, b2_ok, len(topos), wl_path))
    sys.exit(rc)


if __name__ == "__main__":
    main()
