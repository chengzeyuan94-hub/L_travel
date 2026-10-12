"""Install new AI card illustrations (2026-09-26 「旅行L叔」 card redraw) and repoint illustration_manifest.json.

Only the presentation manifest changes: rule data, the fact ledger and tools/build_yf064_p1_data.py are untouched.
New art goes to NEW paths (the old PNGs are shared with the Demo edition and stay as they are):
  cities: res://assets/game/content/lshu_configurable_v1/cards_v2/cities/city_<id>_1024x768.png   (4:3)
  events: res://assets/game/content/lshu_configurable_v1/cards_v2/events/event_<land|sea>_NN_768.png (1:1)

usage: python3 tools/cards/install_card_art.py <dir> [--status approved_ai_card_v2]
<dir> holds, per card, the fitted runtime PNG named as above plus its raw generated master named
<same stem>_master.png (city 1536x1152, event 1024x1024). Masters are archived under art-src/cards-v2/masters/
and recorded as source_master / source_size / source_sha256. Missing ids keep their old art.
"""
import argparse, hashlib, json, os, shutil, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(ROOT, "data/rulesets/lshu_configurable_v1/illustration_manifest.json")
MASTER_DIR = "art-src/cards-v2/masters"
CITY_DIR = "assets/game/content/lshu_configurable_v1/cards_v2/cities"
EVENT_DIR = "assets/game/content/lshu_configurable_v1/cards_v2/events"


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"not a PNG: {path}")
    return list(struct.unpack(">II", head[16:24]))


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--status", default="approved_ai_card_v2")
    a = ap.parse_args()
    doc = json.load(open(MANIFEST))
    changed = 0
    for section in ("items", "existing_coverage"):
        for e in doc[section]:
            if e["entity_type"] == "CITY":
                name = f"city_{e['entity_id']}_1024x768.png"
                rel_dir, want = CITY_DIR, [1024, 768]
            else:
                deck = "land" if e["deck_type"] == "LAND" else "sea"
                name = f"event_{deck}_{int(e['card_number']):02d}_768.png"
                rel_dir, want = EVENT_DIR, [768, 768]
            src = os.path.join(a.src, name)
            if not os.path.exists(src):
                continue
            size = png_size(src)
            if size != want:
                raise SystemExit(f"{name}: size {size} != {want}")
            master = src.replace(".png", "_master.png")
            if not os.path.exists(master):
                raise SystemExit(f"{name}: raw master missing ({os.path.basename(master)})")
            os.makedirs(os.path.join(ROOT, MASTER_DIR), exist_ok=True)
            master_rel = MASTER_DIR + "/" + os.path.basename(master)
            shutil.copyfile(master, os.path.join(ROOT, master_rel))
            os.makedirs(os.path.join(ROOT, rel_dir), exist_ok=True)
            dst = os.path.join(ROOT, rel_dir, name)
            shutil.copyfile(src, dst)
            res = "res://" + rel_dir + "/" + name
            digest = sha(dst)
            e["runtime_path"] = res
            e["runtime_size"] = size
            e["runtime_sha256"] = digest
            e["art_review_status"] = a.status
            e["source_kind"] = "ai_generated_card_v2"
            e["source_master"] = master_rel
            e["source_size"] = png_size(os.path.join(ROOT, master_rel))
            e["source_sha256"] = sha(os.path.join(ROOT, master_rel))
            if section == "existing_coverage":
                e["source_path"] = res
            changed += 1
    open(MANIFEST, "w").write(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
    print(f"installed {changed} illustrations")


if __name__ == "__main__":
    main()
