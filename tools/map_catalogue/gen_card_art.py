"""City card illustrations for the map-editor catalogue archetypes (「旅行L叔」 custom cities).

Fills art-src/cards-v2/prompts/city_template.txt from an archetype's `card_scene` in the catalogue, sends it
through art-src/cards-v2/tools/gen_card.py (CherryIN, openai/gpt-image-2.5-flare, image edits with references)
and fits the chosen master to the runtime size with art-src/cards-v2/tools/fit_card.py — the same chain and
reference order as the shipped 16 city cards (art-src/cards-v2/README.md, tools/run_batch.py):

  ref 1  L叔 official front  (official_前.png, printed "FRONT" label cropped off: rows 0-789, byte-identical to cards-v2)
  ref 2  L叔 official left   (official_左.png)
  ref 3  title key art       (docs/design/shanhe-luren/title-home-20260926/01_master.jpg)
  ref 4  city series anchor  (art-src/cards-v2/masters/city_changan_1024x768_master.png)

Catalogue rules applied on top of the template (catalogue.json rules.card_art):
  * "one card of a 16-city series" reads as a series card (the template file itself stays untouched);
  * TRANSPORT_PROP is picked by starting transport (camel -> CAMEL, ship -> BOAT); BOTH-route archetypes get both;
  * L叔 holds / wears / carries no trade good, wears nothing on his head, and his camel or boat carries only two
    small plain cream cloth bundles, so one picture fits whatever specialty the player chooses.

Outputs (per archetype and transport, <v> = <archetype_id>_<camel|ship>):
  art-src/custom-map-catalogue/cards/<v>/attempt_N.png (+ .prompt.txt / .json from gen_card.py)   every generation
  art-src/custom-map-catalogue/cards/<v>/master.png, prompt.txt, master.json                       the chosen attempt
  assets/custom_map_catalogue/cards/<v>_1024x768.png (+ a .import stub with the cards_v2 texture params)
  art-src/custom-map-catalogue/cards/generation_log.jsonl                                           one line per API call
  art-src/custom-map-catalogue/cards/_review/<archetype_id>_*.png                                  --review sheets

The API key is read by gen_card.py ONLY from $CHERRYIN_KEY_FILE; this script only checks that the variable is set.
Every API call is limited to one try by default (--retries), and a quota error stops the run with the relay's own
message (exit code 3).

usage (from the repo root; pillow is needed for the refs, the fit and the review sheets):
  uv run --with pillow python3 tools/map_catalogue/gen_card_art.py kiln_town --dry-run
  CHERRYIN_KEY_FILE=$HOME/.config/silkroad/cherryin-api-key \\
      uv run --with pillow python3 tools/map_catalogue/gen_card_art.py kiln_town [--transport camel|ship]
  ... kiln_town --transport ship --note "one-line correction for this re-render"      # regenerate (new attempt)
  ... kiln_town --transport ship --select 1                                             # promote an earlier attempt
  ... kiln_town --review                                                                # comparison + card-frame sheets
  ... kiln_town --set-review self_review_pass                                          # after looking at the sheets
  ... all --max-calls 30                                                                # every archetype, resumable
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _main_checkout():
    try:
        common = subprocess.check_output(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return ROOT
    return os.path.dirname(common if os.path.isabs(common) else os.path.join(ROOT, common))


MAIN = _main_checkout()


def repo_path(rel):
    """A repo file from this checkout, or from the main checkout when it is untracked here (refs, masters)."""
    for base in (ROOT, MAIN):
        p = os.path.join(base, rel)
        if os.path.exists(p):
            return p
    raise SystemExit(f"missing {rel} (looked in {ROOT} and {MAIN})")


CATALOGUE = "docs/design/map-editor-20260930/work/catalogue/catalogue.json"
TEMPLATE = "art-src/cards-v2/prompts/city_template.txt"
STYLE = "art-src/cards-v2/prompts/_card_style.txt"
GEN_CARD = "art-src/cards-v2/tools/gen_card.py"
FIT_CARD = "art-src/cards-v2/tools/fit_card.py"
LSHU_REFS = "docs/design/shanhe-luren/ui-3d-assets-20260925/lshu_refs"
TITLE_ART = "docs/design/shanhe-luren/title-home-20260926/01_master.jpg"
ANCHOR = "art-src/cards-v2/masters/city_changan_1024x768_master.png"
SHIPPED_CITY_DIR = "assets/game/content/lshu_configurable_v1/cards_v2/cities"
KIT_DIR = "assets/game/ui/city_cards/v2"
SHIPPED_IMPORT = "assets/game/content/lshu_configurable_v1/cards_v2/cities/city_changan_1024x768.png.import"

OUT_ART = "art-src/custom-map-catalogue/cards"
OUT_RUNTIME = "assets/custom_map_catalogue/cards"
MASTER_SIZE = "1536x1152"
RUNTIME_SIZE = "1024x768"

TRANSPORTS = {  # CLI name -> (catalogue TRANSPORT_PROP key, game starting_transport, noun used in the rule text)
    "camel": ("CAMEL", "CAMEL", "camel"),
    "ship": ("BOAT", "SHIP", "boat"),
}
ROUTE_TRANSPORTS = {"LAND": ["camel"], "SEA": ["ship"], "BOTH": ["camel", "ship"]}
PLACEHOLDERS = ("CITY_EN", "ERA_HINT", "LANDMARKS", "LOCAL_LIFE", "LIGHT", "LSHU_SIDE", "LSHU_ACTION")
SERIES_PHRASE = ("one card of a 16-city series", "one card of a city card series")
CATALOGUE_RULES = (
    "ITEMS AND CLOTHES: L叔 holds, wears and carries no trade goods of any kind: nothing in his hands or under his arms "
    "apart from the gestures described above, and his own brown satchel is his only bag. He wears nothing on his head, "
    "so his glasses and the small hair tuft stay clearly visible. His {noun} carries only two small plain cream cloth "
    "bundles: no pottery, jars, crates, bales or other goods on it. The town's own craft installations and workshop "
    "props are architecture and may appear around him."
)
SERIES_ANCHOR = (
    "SERIES ANCHOR: Reference image 4 is an approved card of this same city card series. Match its L叔 size and "
    "rendering, its palette, its warm light and its finish, but draw the new place described above (do not copy its "
    "buildings, pagoda, city wall or composition)."
)
QUOTA_MARKERS = ("insufficient_user_quota", "insufficient_quota", "quota")
# the card-frame overlays that sit on the illustration (scripts/ui/formal_city_card.gd, 1086x1448 design px)
CARD = {
    "size": (1086, 1448), "photo": (115, 226, 856, 651), "art": (133, 244, 820, 615),
    "deco": [("ribbon", (133, 14, 820, 220)), ("badge.png", (84, 214, 150, 124)),
             ("highlight.png", (213, 806, 660, 150)), ("tag_olive.png", (96, 976, 150, 58)),
             ("tag_camel.png", (96, 1092, 150, 58)), ("divider.png", (143, 1170, 800, 52)),
             ("stamp.png", (118, 1228, 126, 134)), ("postmark.png", (714, 1216, 212, 146))],
    "title": (250, 36, 586, 124), "epithet": (303, 844, 480, 72),
    "intro": (262, 956, 728, 98), "scenery": (262, 1072, 728, 98),
    "intro_badge": (138, 976, 104, 58), "scenery_badge": (138, 1092, 104, 58),
}


def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def rel(path):
    if path.startswith(ROOT + os.sep):
        return os.path.relpath(path, ROOT)
    if path.startswith(MAIN + os.sep):
        return "main-checkout:" + os.path.relpath(path, MAIN)
    return path


def load_catalogue(path):
    doc = json.load(open(path))
    return {a["id"]: a for a in doc["archetypes"]}, doc


def transports_for(arch, only):
    allowed = ROUTE_TRANSPORTS[arch["route_type"]]
    if only:
        if only not in allowed:
            raise SystemExit(f"{arch['id']} is route_type {arch['route_type']}: transport {only} not allowed ({allowed})")
        return [only]
    return allowed


def build_prompt(arch, transport, notes):
    scene = arch["card_scene"]
    key, _, noun = TRANSPORTS[transport]
    t = open(repo_path(TEMPLATE)).read()
    if SERIES_PHRASE[0] not in t:
        raise SystemExit(f"template changed: '{SERIES_PHRASE[0]}' not found in {TEMPLATE}")
    t = t.replace(*SERIES_PHRASE)
    for k in PLACEHOLDERS:
        v = scene.get(k, "").strip()
        if not v:
            raise SystemExit(f"{arch['id']}: card_scene.{k} is empty")
        t = t.replace("{" + k + "}", v)
    prop = scene.get("TRANSPORT_PROP", {}).get(key, "").strip()
    if not prop:
        raise SystemExit(f"{arch['id']}: card_scene.TRANSPORT_PROP.{key} is empty")
    t = t.replace("{TRANSPORT_PROP}", prop)
    t = t.replace("{STYLE_BLOCK}", open(repo_path(STYLE)).read().strip())
    left = sorted(set(re.findall(r"\{[A-Z_]+\}", t)))
    if left:
        raise SystemExit(f"unfilled placeholders: {left}")
    t = re.sub(r"(?<!\.)\.\.(?!\.)", ".", t).rstrip() + "\n\n" + CATALOGUE_RULES.format(noun=noun) + "\n\n" + SERIES_ANCHOR
    if notes:
        t += "\n\nCORRECTIONS FOR THIS RENDER: " + " ".join(n.strip() for n in notes)
    return t + "\n"


def prepare_refs(cache_dir):
    """Refs 1-2 are made on the fly (same crop as art-src/fun-events-cards/tools/prepare_refs.py)."""
    from PIL import Image
    os.makedirs(cache_dir, exist_ok=True)
    front = os.path.join(cache_dir, "1_official_front_nolabel.png")
    left = os.path.join(cache_dir, "2_official_left.png")
    src = repo_path(LSHU_REFS)
    Image.open(os.path.join(src, "official_前.png")).convert("RGB").crop((0, 0, 798, 790)).save(front)
    Image.open(os.path.join(src, "official_左.png")).convert("RGB").save(left)
    return [("lshu_official_front_nolabel", front, rel(os.path.join(src, "official_前.png")) + " crop 0,0,798,790"),
            ("lshu_official_left", left, rel(os.path.join(src, "official_左.png"))),
            ("title_key_art_style", repo_path(TITLE_ART), rel(repo_path(TITLE_ART))),
            ("city_series_anchor_changan", repo_path(ANCHOR), rel(repo_path(ANCHOR)))]


def variant_dir(arch_id, transport):
    return os.path.join(ROOT, OUT_ART, f"{arch_id}_{transport}")


def runtime_path(arch_id, transport):
    return os.path.join(ROOT, OUT_RUNTIME, f"{arch_id}_{transport}_{RUNTIME_SIZE}.png")


def attempts(vdir):
    got = []
    for f in os.listdir(vdir) if os.path.isdir(vdir) else []:
        m = re.fullmatch(r"attempt_(\d+)\.png", f)
        if m:
            got.append(int(m.group(1)))
    return sorted(got)


def log_call(entry):
    p = os.path.join(ROOT, OUT_ART, "generation_log.jsonl")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def ensure_gdignore():
    p = os.path.join(ROOT, OUT_ART, ".gdignore")  # masters stay out of the Godot import
    if not os.path.exists(p):
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").close()


def write_import_stub(png):
    """Give the runtime PNG the cards_v2 texture import params (mipmaps on) before Godot first imports it."""
    imp = png + ".import"
    if os.path.exists(imp):
        return
    src = open(repo_path(SHIPPED_IMPORT)).read()
    params = src[src.index("[params]"):]
    open(imp, "w").write('[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n' + params)


def generate(arch, transport, refs, notes, retries, dry_run):
    vdir = variant_dir(arch["id"], transport)
    prompt = build_prompt(arch, transport, notes)
    n = (attempts(vdir) or [0])[-1] + 1
    out = os.path.join(vdir, f"attempt_{n}.png")
    if dry_run:
        print(f"--- {arch['id']} {transport} -> {rel(out)}  size {MASTER_SIZE}")
        print("refs:", [r[2] for r in refs])
        print(prompt)
        return "dry"
    if not os.environ.get("CHERRYIN_KEY_FILE") or not os.path.exists(os.environ["CHERRYIN_KEY_FILE"]):
        raise SystemExit("set CHERRYIN_KEY_FILE to the key file (the key itself is never passed or printed)")
    os.makedirs(vdir, exist_ok=True)
    pfile = os.path.join(vdir, f"attempt_{n}.prompt_in.txt")
    open(pfile, "w").write(prompt)
    cmd = [sys.executable, repo_path(GEN_CARD), "--out", out, "--prompt-file", pfile, "--size", MASTER_SIZE,
           "--retries", str(retries)]
    for _, path, _ in refs:
        cmd += ["--ref", path]
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True)
    os.remove(pfile)  # gen_card.py keeps the exact prompt in attempt_N.png.prompt.txt
    log = (p.stdout + p.stderr).strip()
    ok = p.returncode == 0 and os.path.exists(out)
    log_call({"time": datetime.datetime.now().isoformat(timespec="seconds"), "archetype": arch["id"],
              "transport": transport, "attempt": n, "ok": ok, "seconds": round(time.time() - t0),
              "notes": notes, "output": log[-600:]})
    if not ok:
        print(f"FAILED {arch['id']} {transport} attempt {n}:\n{log}", file=sys.stderr)
        if any(m in log.lower() for m in QUOTA_MARKERS):
            print("relay reports no quota: stopping", file=sys.stderr)
            sys.exit(3)
        return "fail"
    meta = {"attempt": n, "notes": notes, "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest(),
            "refs": [{"role": r, "source": s, "sha256": sha256(pth)} for r, pth, s in refs]}
    json.dump(meta, open(os.path.join(vdir, f"attempt_{n}.meta.json"), "w"), ensure_ascii=False, indent=1)
    print(f"{arch['id']} {transport} attempt {n} ok in {time.time() - t0:.0f}s")
    promote(arch, transport, n)
    return "ok"


def promote(arch, transport, n):
    """Make attempt n the master and (re)fit the runtime image with fit_card.py."""
    vdir = variant_dir(arch["id"], transport)
    src = os.path.join(vdir, f"attempt_{n}.png")
    if not os.path.exists(src):
        raise SystemExit(f"no {rel(src)}")
    master = os.path.join(vdir, "master.png")
    shutil.copyfile(src, master)
    shutil.copyfile(src + ".prompt.txt", os.path.join(vdir, "prompt.txt"))
    rt = runtime_path(arch["id"], transport)
    os.makedirs(os.path.dirname(rt), exist_ok=True)
    fit = subprocess.run([sys.executable, repo_path(FIT_CARD), master, rt, "--size", RUNTIME_SIZE],
                         capture_output=True, text=True)
    if fit.returncode != 0:
        raise SystemExit("fit_card.py failed:\n" + fit.stdout + fit.stderr)
    write_import_stub(rt)
    ensure_gdignore()
    from PIL import Image
    ameta_p = os.path.join(vdir, f"attempt_{n}.meta.json")
    ameta = json.load(open(ameta_p)) if os.path.exists(ameta_p) else {}
    api = json.load(open(src + ".json")) if os.path.exists(src + ".json") else {}
    key, starting, _ = TRANSPORTS[transport]
    meta = {
        "schema": "lshu_custom_city_card_art_v1",
        "archetype_id": arch["id"], "archetype_name_zh": arch["name_zh"], "transport": transport,
        "starting_transport": starting, "transport_prop_key": key, "route_type": arch["route_type"],
        "catalogue": CATALOGUE, "card_scene_sha256": hashlib.sha256(
            json.dumps(arch["card_scene"], ensure_ascii=False, sort_keys=True).encode()).hexdigest(),
        "template": TEMPLATE, "style": STYLE, "generator": GEN_CARD, "fit": FIT_CARD,
        "model": os.environ.get("CHERRYIN_IMAGE_MODEL", "openai/gpt-image-2.5-flare"), "quality": "high",
        "chosen_attempt": n, "attempts_on_disk": attempts(vdir), "notes": ameta.get("notes", []),
        "refs": ameta.get("refs", []), "prompt_sha256": ameta.get("prompt_sha256"),
        "master": rel(master), "master_size": list(Image.open(master).size), "master_sha256": sha256(master),
        "runtime_path": "res://" + rel(rt), "runtime_size": list(Image.open(rt).size), "runtime_sha256": sha256(rt),
        "api_usage": api.get("usage"), "api_created": api.get("created"),
        "source_kind": "ai_generated_custom_map_card", "art_review_status": "pending",
        "promoted_at": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    json.dump(meta, open(os.path.join(vdir, "master.json"), "w"), ensure_ascii=False, indent=1)
    print(f"master <- attempt {n}; runtime {rel(rt)} {meta['runtime_size']} {meta['runtime_sha256'][:12]}")


# ---------------------------------------------------------------- review sheets
def _font(size):
    from PIL import ImageFont
    for f in ("/System/Library/Fonts/Hiragino Sans GB.ttc", "/System/Library/Fonts/STHeiti Medium.ttc",
              "C:/Windows/Fonts/msyh.ttc"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def _fit_box(im, box_w, box_h):
    from PIL import Image
    s = min(box_w / im.width, box_h / im.height)
    return im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.Resampling.LANCZOS)


def card_mock(art_path, transport, name, epithet, intro, scenery):
    """The formal city card (formal_city_card.gd layout + the real kit PNGs) with this illustration in the frame."""
    from PIL import Image, ImageDraw
    kit = repo_path(KIT_DIR)
    card = Image.open(os.path.join(kit, "paper_1086x1448.png")).convert("RGBA").resize(CARD["size"])
    d = ImageDraw.Draw(card)
    x, y, w, h = CARD["photo"]
    d.rounded_rectangle((x, y, x + w, y + h), 10, fill="#FFFDF7", outline="#EADCC0")
    x, y, w, h = CARD["art"]
    art = Image.open(art_path).convert("RGB")
    s = max(w / art.width, h / art.height)  # STRETCH_KEEP_ASPECT_COVERED
    art = art.resize((round(art.width * s), round(art.height * s)), Image.Resampling.LANCZOS)
    art = art.crop(((art.width - w) // 2, (art.height - h) // 2, (art.width - w) // 2 + w, (art.height - h) // 2 + h))
    card.paste(art, (x, y))
    for fname, (x, y, w, h) in CARD["deco"]:
        if fname == "ribbon":
            fname = "ribbon_denim.png" if transport == "ship" else "ribbon.png"
        im = _fit_box(Image.open(os.path.join(kit, fname)).convert("RGBA"), w, h)  # KEEP_ASPECT_CENTERED
        card.alpha_composite(im, (x + (w - im.width) // 2, y + (h - im.height) // 2))
    d = ImageDraw.Draw(card)

    def text(rect, s, size, fill, outline=None, center=True):
        x, y, w, h = rect
        f = _font(size)
        lines, cur = [], ""
        for ch in s:  # naive wrap by width
            if d.textlength(cur + ch, font=f) > w:
                lines.append(cur)
                cur = ch
            else:
                cur += ch
        lines.append(cur)
        lh = size * 1.3
        ty = y + (h - lh * len(lines)) / 2
        for ln in lines:
            tw = d.textlength(ln, font=f)
            tx = x + (w - tw) / 2 if center else x
            d.text((tx, ty), ln, font=f, fill=fill, stroke_width=4 if outline else 0, stroke_fill=outline)
            ty += lh
    text(CARD["title"], name, 64, "#FBF3E4", outline="#6B4228")
    text(CARD["epithet"], epithet, 34, "#3A2A22")
    text(CARD["intro"], intro, 27, "#3A2A22", center=False)
    text(CARD["scenery"], scenery, 27, "#3A2A22", center=False)
    text(CARD["intro_badge"], "简介", 28, "#FBF3E4")
    text(CARD["scenery_badge"], "风貌", 28, "#FBF3E4")
    return card.convert("RGB")


def review(arch, shipped):
    from PIL import Image, ImageDraw
    rdir = os.path.join(ROOT, OUT_ART, "_review")
    os.makedirs(rdir, exist_ok=True)
    variants = [(t, runtime_path(arch["id"], t)) for t in ROUTE_TRANSPORTS[arch["route_type"]]]
    variants = [(t, p) for t, p in variants if os.path.exists(p)]
    if not variants:
        raise SystemExit(f"no runtime images for {arch['id']} yet")
    head = _font(22)
    bg = (36, 28, 20)
    # 1) style: new variants (+ L叔's official front / left in spare slots) on top, shipped city cards below, 512x384
    cw, ch, cap = 512, 384, 30
    cols = max(len(variants), len(shipped))
    lshu = [("L叔 official front (identity ref)", os.path.join(repo_path(LSHU_REFS), "official_前.png"), (0, 0, 798, 790)),
            ("L叔 official left (identity ref)", os.path.join(repo_path(LSHU_REFS), "official_左.png"), None)]
    top = [(f"NEW {arch['id']} · {t}", p, None) for t, p in variants]
    top += lshu[:max(0, cols - len(top))]
    rows = [top, [(f"shipped · {c}", os.path.join(repo_path(SHIPPED_CITY_DIR), f"city_{c}_1024x768.png"), None)
                  for c in shipped]]
    sheet = Image.new("RGB", (cols * cw, 2 * (ch + cap)), bg)
    d = ImageDraw.Draw(sheet)
    for r, items in enumerate(rows):
        for i, (label, p, crop) in enumerate(items):
            im = Image.open(p).convert("RGB")
            if crop:
                im = im.crop(crop)
            if label.startswith("L叔"):
                im = _fit_box(im, cw, ch)
            else:
                im = im.resize((cw, ch), Image.Resampling.LANCZOS)
            x, y = i * cw, r * (ch + cap)
            sheet.paste(im, (x + (cw - im.width) // 2, y + cap))
            d.text((x + 8, y + 4), label, font=head, fill=(240, 230, 210))
    out1 = os.path.join(rdir, f"{arch['id']}_style_compare.png")
    sheet.save(out1, optimize=True)
    # 2) the real card frame: full cards on top (new variants + a shipped card), then the same cards at the small
    #    popup scale and the bare illustrations as 120 px thumbnails
    name = (arch.get("example_cities") or [arch["name_zh"]])[0]
    intro = arch["intro_template"].replace(arch.get("template_placeholder", "{城名}"), name)
    scenery = arch["scenery_template"].replace(arch.get("template_placeholder", "{城名}"), name)
    cards = [card_mock(p, t, name, arch["name_zh"], intro, scenery) for t, p in variants]
    cards += [card_mock(os.path.join(repo_path(SHIPPED_CITY_DIR), f"city_{shipped[0]}_1024x768.png"), "camel",
                        "长安", "丝路东端，盛唐西都", "（对照：已发布的长安卡）", "")]
    cw2, ch2 = CARD["size"][0] // 2, CARD["size"][1] // 2
    sw, sh = 217, 290
    W = len(cards) * cw2
    H = ch2 + cap + sh + 20
    sheet2 = Image.new("RGB", (W, H), bg)
    d = ImageDraw.Draw(sheet2)
    for i, c in enumerate(cards):
        sheet2.paste(c.resize((cw2, ch2), Image.Resampling.LANCZOS), (i * cw2, 0))
    y0 = ch2 + cap
    d.text((8, ch2 + 4), "small popup scale (217x290) and 120 px thumbnails", font=head, fill=(240, 230, 210))
    for i, c in enumerate(cards):
        sheet2.paste(c.resize((sw, sh), Image.Resampling.LANCZOS), (i * (sw + 12), y0))
    x0 = len(cards) * (sw + 12) + 20
    for i, (_, p) in enumerate(variants):
        sheet2.paste(Image.open(p).convert("RGB").resize((120, 90), Image.Resampling.LANCZOS), (x0 + i * 132, y0))
    out2 = os.path.join(rdir, f"{arch['id']}_card_frame.png")
    sheet2.save(out2, optimize=True)
    print("review sheets:", rel(out1), rel(out2))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("archetype_id", help="catalogue archetype id, or 'all' (needs --max-calls)")
    ap.add_argument("--transport", choices=sorted(TRANSPORTS), help="default: every transport its route_type needs")
    ap.add_argument("--catalogue", default=CATALOGUE)
    ap.add_argument("--note", action="append", default=[], help="correction appended to this render's prompt")
    ap.add_argument("--select", type=int, help="promote attempt N to master + runtime (no API call)")
    ap.add_argument("--review", action="store_true", help="build the comparison sheets (no API call)")
    ap.add_argument("--set-review", metavar="STATUS",
                    help="record the art review verdict in master.json, e.g. self_review_pass (no API call)")
    ap.add_argument("--shipped", default="changan,quanzhou,geumseong", help="shipped city cards for --review")
    ap.add_argument("--redo", action="store_true", help="generate a new attempt even when a master exists")
    ap.add_argument("--dry-run", action="store_true", help="print the assembled prompts, call nothing")
    ap.add_argument("--retries", type=int, default=1, help="tries per image (each try may be billed)")
    ap.add_argument("--max-calls", type=int, default=0, help="stop after this many API calls (required for 'all')")
    a = ap.parse_args()

    archs, _ = load_catalogue(os.path.join(ROOT, a.catalogue) if not os.path.isabs(a.catalogue) else a.catalogue)
    if a.archetype_id == "all":
        if a.max_calls <= 0 and not (a.dry_run or a.review):
            raise SystemExit("'all' needs --max-calls N")
        todo = list(archs.values())
    elif a.archetype_id in archs:
        todo = [archs[a.archetype_id]]
    else:
        raise SystemExit(f"unknown archetype {a.archetype_id}; known: {', '.join(archs)}")

    if a.review:
        for arch in todo:
            review(arch, a.shipped.split(","))
        return
    if a.set_review:
        for arch in todo:
            for t in transports_for(arch, a.transport):
                mp = os.path.join(variant_dir(arch["id"], t), "master.json")
                if not os.path.exists(mp):
                    raise SystemExit(f"no {rel(mp)}")
                m = json.load(open(mp))
                m["art_review_status"] = a.set_review
                m["art_review_record"] = rel(os.path.join(ROOT, OUT_ART, "art_review.json"))
                json.dump(m, open(mp, "w"), ensure_ascii=False, indent=1)
                print(arch["id"], t, "->", a.set_review)
        return
    if a.select:
        if len(todo) != 1 or not a.transport:
            raise SystemExit("--select needs one archetype and --transport")
        promote(todo[0], a.transport, a.select)
        return

    refs = prepare_refs(os.path.join(tempfile.gettempdir(), "lshu_card_refs")) if not a.dry_run else [
        ("lshu_official_front_nolabel", "", "official_前.png crop"), ("lshu_official_left", "", "official_左.png"),
        ("title_key_art_style", "", TITLE_ART), ("city_series_anchor_changan", "", ANCHOR)]
    calls, results = 0, []
    for arch in todo:
        for t in transports_for(arch, a.transport):
            if os.path.exists(os.path.join(variant_dir(arch["id"], t), "master.png")) and not (a.redo or a.note or a.dry_run):
                results.append((arch["id"], t, "skip (master exists; --redo or --note for a new attempt)"))
                continue
            if a.max_calls and calls >= a.max_calls:
                results.append((arch["id"], t, "not run: --max-calls reached"))
                continue
            r = generate(arch, t, refs, a.note, a.retries, a.dry_run)
            calls += r != "dry"
            results.append((arch["id"], t, r))
    for r in results:
        print(*r)


if __name__ == "__main__":
    main()
