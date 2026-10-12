#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""emit_nostall.py — 从仓库当前的 scripts/ai/ai_policy.gd 生成「不死等」参考 AI（DESIGN 4.4，只用于 S7）。

改两处：去掉 class_name（副本不能和正式 AIPolicy 重名）；把 choose_trade 里的「远端更好就持货等待」改成
「这回合原地没走就不再等」（ECONOMY §5.4 的一行修正）。原版和自制地图两边都用它，量的是经济本身而不是死等。
写到仓库外（默认本次运行的 scratch 目录），仓库里不留副本。

用法：python3 emit_nostall.py <输出 .gd 路径>
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OLD = "\tif future_liquidation > immediate_liquidation:\n"
NEW = "\tif future_liquidation > immediate_liquidation and player.movement_spent > 0:\n"


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    src = (REPO / "scripts" / "ai" / "ai_policy.gd").read_text(encoding="utf-8")
    if not src.startswith("class_name AIPolicy\n") or src.count(OLD) != 1:
        print("ai_policy.gd 已变化，nostall 补丁需要重新核对（choose_trade 的持货等待比较）")
        sys.exit(1)
    out = src.replace("class_name AIPolicy\n", "## 模拟用副本（emit_nostall.py 生成）：只改 1 行——原地没走就不再等远方更好的价。\n", 1)
    out = out.replace(OLD, NEW, 1)
    Path(sys.argv[1]).write_text(out, encoding="utf-8")
    print("写出 %s" % sys.argv[1])


if __name__ == "__main__":
    main()
