"""Prompt builders for the archetype MODEL chain (concept image -> four-view sheet -> Blender -> Godot check).

Reads the map-editor catalogue (docs/design/map-editor-20260930/work/catalogue/catalogue.json) and the chain's
per-archetype hints (tools/map_catalogue/archetype_models.json) and assembles two prompts for
art-src/cards-v2/tools/gen_card.py (CherryIN, openai/gpt-image-2.5-flare, /images/edits with reference images):

  concept   standalone concept image of the building cluster ALONE, style-anchored by 1-2 DERIVED board-city
            renders (building-only, light-grey background, three-quarter view from the front-left, 35 deg)
  fourview  orthographic turnaround (FRONT / BACK / LEFT / RIGHT, 2x2) derived from the chosen 01-concept.png

Both prompts carry the catalogue's model rules: subject alone, NO ground slab / plinth / terrain square, NO water
(except the catalogue's stone-trough exceptions), NO text, NO people. Boats, carts, animals and quays are banned
too EXCEPT the ones an archetype's look is built around, which archetype_models.json lists per archetype under
"allow" ({"life": ..., "quay": ...}): canal_town's moored wupeng boats, yurt_market's ox-cart, caravanserai_town's
kneeling camels, shipyard_port's junks and slipway, lighthouse_port's ship and mole, lagoon_town's gondola and
mooring poles, noria_town's quay, stilt_village's canoe. People are never allowed.

  python3 tools/map_catalogue/archetype_prompts.py kiln_town concept          # print the prompt + refs
  python3 tools/map_catalogue/archetype_prompts.py kiln_town fourview --write  # also write <dir>/02-fourview.prompt.txt
  python3 tools/map_catalogue/archetype_prompts.py --list                      # archetype ids

Pure standard library; importable (build_prompt, refs_for, archetype, paths) by archetype_gen.py.
"""
import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOGUE = os.path.join(ROOT, "docs/design/map-editor-20260930/work/catalogue/catalogue.json")
HINTS = os.path.join(ROOT, "tools/map_catalogue/archetype_models.json")
ART_DIR = os.path.join(ROOT, "art-src/custom-map-catalogue/archetypes")
REFS_DIR = os.path.join(ROOT, "art-src/custom-map-catalogue/refs/derived")

STAGES = {
    "concept": {"file": "01-concept", "size_key": "concept_size"},
    "fourview": {"file": "02-fourview", "size_key": "fourview_size"},
}


def load_catalogue():
    with open(CATALOGUE, encoding="utf-8") as f:
        return json.load(f)


def load_hints():
    with open(HINTS, encoding="utf-8") as f:
        return json.load(f)


def archetype(aid, cat=None):
    cat = cat or load_catalogue()
    for a in cat["archetypes"]:
        if a["id"] == aid:
            return a
    raise SystemExit(f"unknown archetype id {aid!r}; known: {', '.join(x['id'] for x in cat['archetypes'])}")


def board_side_of(city, hints=None):
    hints = hints or load_hints()
    for side, cities in hints["defaults"]["board_cities_by_side"].items():
        if city in cities:
            return side
    raise SystemExit(f"{city!r} is not a shipped board city (defaults.board_cities_by_side)")


def hints_for(aid, hints=None):
    """Merged hints for one archetype: archetype entry over defaults (style_refs / compare_cities by side_hint).
    compare_cities (the archetype's 2-3 'closest' shipped cities, shown first) and style_refs must be shipped cities
    of the archetype's OWN side (west archetypes against west cities, east against east); compare_all is every
    shipped city of that side, closest ones first (what the Godot side-by-side shows)."""
    hints = hints or load_hints()
    a = archetype(aid)
    d = hints["defaults"]
    h = dict(hints["archetypes"].get(aid, {}))
    side = a.get("side_hint", "east")
    h["side"] = side
    entry = hints["archetypes"].get(aid, {})
    h["has_entry"] = bool(entry.get("layout")) and len(entry.get("views", {})) == 4
    h.setdefault("style_refs", d["style_refs"][side])
    h.setdefault("compare_cities", d["compare_cities"][side])
    for key in ("style_refs", "compare_cities"):
        wrong = [c for c in h[key] if board_side_of(c, hints) != side]
        if wrong:
            raise SystemExit(f"{aid}: {key} {wrong} are not {side} board cities (a {side} archetype is compared "
                             f"with {side} cities only; defaults.board_cities_by_side)")
    side_all = d["board_cities_by_side"][side]
    h["compare_all"] = list(h["compare_cities"]) + [c for c in side_all if c not in h["compare_cities"]]
    for k in ("concept_size", "fourview_size", "board_foot", "concept_camera", "aspect_max"):
        h.setdefault(k, d[k])
    h.setdefault("allow", {})
    views = dict(d["views"])
    views.update(h.get("views", {}))
    h["views"] = views
    return h


def paths(aid):
    d = os.path.join(ART_DIR, aid)
    return {
        "dir": d,
        "concept": os.path.join(d, "01-concept.png"),
        "fourview": os.path.join(d, "02-fourview.png"),
        "build": os.path.join(d, "build.py"),
        "blend": os.path.join(d, f"{aid}.blend"),
        "glb": os.path.join(ROOT, "assets/custom_map_catalogue/cities", f"{aid}.glb"),
        "thumb": os.path.join(ROOT, "assets/custom_map_catalogue/thumbs", f"{aid}.png"),
    }


def derived_ref(city):
    """DERIVED (building-only) board-city render made by the chain itself: render_board_refs.py renders it from
    assets/merchant_board_claude/cities/<city>.glb with the exact camera and light of the original DERIVED renders
    into art-src/custom-map-catalogue/refs/derived/ (tracked, so every checkout has the same style anchors). The
    design-doc PNGs are only in the main checkout and are NOT used as a fallback."""
    p = os.path.join(REFS_DIR, f"{city}.png")
    if os.path.exists(p):
        return p
    raise SystemExit(f"no DERIVED render for {city}: run\n  Blender -b --factory-startup --python "
                     f"tools/map_catalogue/render_board_refs.py -- {city}")


def refs_for(aid, stage):
    if stage == "concept":
        return [derived_ref(c) for c in hints_for(aid)["style_refs"]]
    concept = paths(aid)["concept"]
    if not os.path.exists(concept):
        raise SystemExit(f"four-view needs the chosen concept first: {concept}")
    return [concept]


# ---------------------------------------------------------------------------------------------------------------
# shared rule blocks (catalogue rules.model / water_trough_exceptions)
# ---------------------------------------------------------------------------------------------------------------
NO_BASE = ("NO ground slab, plinth, base plate, diorama tile, terrain square, hill, lawn, paving or soil patch under "
           "the model: the buildings, their own footings, the props and the trees stand directly on the plain "
           "background, with only a faint soft contact shadow under them.")
NO_TEXT = "NO text, letters, numbers, labels, signs with writing, watermarks, frames or UI anywhere in the image."
NO_PEOPLE = "NO people or figures of any kind."


def life_rule(h):
    """No people ever; animals, carts and boats only when the archetype's look is built around them (allow.life)."""
    life = h.get("allow", {}).get("life")
    if life:
        return (f"{NO_PEOPLE} The ONLY animals, carts or boats allowed are the ones this asset is built around: {life}. "
                "Nothing else of that kind: no other animals, carts, boats or vehicles.")
    return f"{NO_PEOPLE} NO animals, carts, boats or vehicles."


def water_rule(a, h=None):
    """No water surface (the board supplies its own sea); the catalogue's stone troughs and, per archetype
    (allow.quay), a built quay / mole / slipway / walkway on posts are allowed as architecture."""
    quay = (h or {}).get("allow", {}).get("quay")
    quay_line = (f" A built edge that is part of the architecture IS allowed: {quay}; it ends in a clean cut edge on "
                 "the plain background, with NO water surface, sea or shoreline around it." if quay else "")
    if a.get("water_trough"):
        return ("The ONLY water allowed is this small built trough, which is part of the architecture: "
                f"{a['water_trough']} (stone rim all round, no more than a quarter of the footprint, never reaching "
                "the edge of the model). No other water: no river, sea, pond or shoreline." + quay_line)
    if quay:
        return "NO water anywhere: no river, sea, pond, canal or shoreline." + quay_line
    return "NO water anywhere: no river, sea, pond, canal, wharf, jetty or shoreline."


def footprint_rule(h):
    return (f"FOOTPRINT: compact, the whole cluster (trees and lamp posts included) no more than {h['aspect_max']} : 1 "
            "in plan - the board scales every city to the same width, so a long strip comes out small and flat.")


def composition_block(a):
    c = a.get("composition", {})
    sec = "; ".join(c.get("secondary", []))
    return (f"main mass (at least half the footprint width): {c.get('main', '')}; "
            f"secondary masses (no more than three): {sec}; signature trees: {c.get('trees', '')}")


def build_prompt(aid, stage, note=None):
    a = archetype(aid)
    h = hints_for(aid)
    palette = ", ".join(a.get("palette", []))
    layout = h.get("layout", "")
    if stage == "concept":
        n = len(h["style_refs"])
        refs_line = ("REFERENCE IMAGES 1-%d are two existing cities from the same game board, rendered exactly the way "
                     "this asset must look" % n) if n > 1 else "REFERENCE IMAGE 1 is an existing city from the same game board"
        parts = [
            "CONCEPT ART for ONE isolated game asset: a single low-poly miniature building cluster that will stand as "
            f"a city on the 3D map of the cozy family travel board game 「旅行L叔」. Archetype: {a['name_zh']} - "
            f"{a['card_scene']['CITY_EN'] if a.get('card_scene') else a['id']}.",
            f"{refs_line}: chunky faceted low-poly toy-diorama models built from simple blocks, flat matte colours with "
            "no textures and no outlines, crisp simple shading, warm sunlight, almost no perspective, the model "
            "isolated on a plain flat light-grey background, small stone lamp posts with glowing lanterns beside the "
            "buildings. Match that rendering style and that level of detail exactly. Use the references ONLY for "
            "style: do not copy their buildings, their roof colours, their layout or their camera angle.",
            f"CAMERA: {h['concept_camera']}",
            f"THE ASSET: {a['look']}",
            layout,
            f"PALETTE: {palette}.",
            "The silhouette named above must read at a 120-pixel thumbnail: keep that outline bold and simple, "
            "everything else is small detail.",
            f"IT MUST NOT LOOK LIKE the existing board cities (note in Chinese): {a.get('distinct_from_existing', '')}",
            "FRAMING: the whole cluster in frame, centred, with generous empty margin all round; one single cluster, "
            "nothing else in the picture.",
            footprint_rule(h),
            NO_BASE, water_rule(a, h), life_rule(h), NO_TEXT,
        ]
    elif stage == "fourview":
        v = h["views"]
        parts = [
            "ORTHOGRAPHIC MODEL REFERENCE SHEET (turnaround) of the EXACT building cluster in reference image 1, for a "
            "3D modeller who will rebuild it in Blender as a low-poly model. Keep every element exactly as in "
            "reference image 1: the same parts, the same counts, proportions, colours and positions, the same chunky "
            "low-poly look with flat matte colours.",
            f"What the model is (for reading reference image 1 correctly): {a['look']} Plus the small lamp posts if "
            "reference image 1 has them.",
            layout,
            "LAYOUT OF THE SHEET: four separate views of the same model at exactly the same scale, in a 2 x 2 grid with "
            "generous even spacing on a plain flat light-grey background: top-left FRONT, top-right BACK, bottom-left "
            "LEFT, bottom-right RIGHT. Every view is a true orthographic elevation seen exactly horizontally from "
            "ground level (camera at half the model's height, no roofs seen from above, no perspective, no "
            "three-quarter angle). In each view the model stands on one flat horizontal ground line, and both views of "
            "a row share the same ground line and the same scale.",
            f"FRONT view: {v['FRONT']}.",
            f"BACK view: {v['BACK']}.",
            f"LEFT view: {v['LEFT']}.",
            f"RIGHT view: {v['RIGHT']}.",
            "Soft even studio light from the front-left, only a very faint contact shadow under each view.",
            "Every feature that is geometrically visible from a side (an opening, a broken face, a stair, a wheel) "
            "appears in EVERY view that looks at that side, at the same place and size; the four views must agree "
            "with each other and with reference image 1.",
            NO_BASE, water_rule(a, h), life_rule(h),
            "NO text, labels, view names, numbers, arrows, dimension lines, grid lines or frames.",
        ]
    else:
        raise SystemExit(f"unknown stage {stage!r} (concept|fourview)")
    if note:
        parts.append(f"CORRECTION FOR THIS ATTEMPT: {note}")
    return "\n\n".join(p for p in parts if p)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("id", nargs="?")
    ap.add_argument("stage", nargs="?", choices=sorted(STAGES))
    ap.add_argument("--note")
    ap.add_argument("--write", action="store_true", help="write <dir>/<NN-stage>.prompt.txt")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list or not a.id:
        for x in load_catalogue()["archetypes"]:
            print(x["id"], x["name_zh"], x["side_hint"], x["route_type"])
        return
    if not a.stage:
        raise SystemExit("stage required: concept | fourview")
    prompt = build_prompt(a.id, a.stage, a.note)
    h = hints_for(a.id)
    try:
        refs = refs_for(a.id, a.stage)
    except SystemExit as e:
        refs = [f"(missing) {e}"]
    print(f"size: {h[STAGES[a.stage]['size_key']]}\nrefs: {refs}\n")
    print(prompt)
    if a.write:
        d = paths(a.id)["dir"]
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, STAGES[a.stage]["file"] + ".prompt.txt")
        with open(p, "w", encoding="utf-8") as f:
            f.write(prompt + "\n")
        print("\nwrote", os.path.relpath(p, ROOT), file=sys.stderr)


if __name__ == "__main__":
    main()
