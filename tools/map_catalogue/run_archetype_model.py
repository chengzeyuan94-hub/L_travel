# Step 3 of the archetype model chain: build -> .blend -> GLB -> Blender check renders -> thumbnail.
#
#   Blender -b --factory-startup --python tools/map_catalogue/run_archetype_model.py -- <id> [--no-render]
#
# (Blender = /Users/chengzeyuan/Applications/Blender-5.2.1.app/Contents/MacOS/Blender; always a fresh headless
#  process, never Carlos's open window / the blender-mcp socket on localhost:9876.)
#
# 1. execs art-src/custom-map-catalogue/archetypes/<id>/build.py, which defines build(L, city) and models the
#    archetype against its 02-fourview.png with lib_city_lowpoly (L); optional module constant PREFIX names the
#    materials (<PREFIX>_<Name>), default = the id's initials in capitals
# 2. applies transforms, puts the footprint centre on the origin and the lowest point on the ground (z = 0)
# 3. saves art-src/custom-map-catalogue/archetypes/<id>/<id>.blend   (editable, un-joined, one collection per
#    kind: <id>_buildings / <id>_props / <id>_trees)  -- the source of truth
# 4. joins meshes per material and exports assets/custom_map_catalogue/cities/<id>.glb (glTF Y-up, front = +Z),
#    writes its .import sidecar (importer="keep", like assets/merchant_board_claude/cities/*.glb.import) and
#    merges its entry into assets/custom_map_catalogue/cities/building_bounds.json (same schema as the board's)
#    atomically (merge_bounds: directory flock, re-read, set this id only, temp file + os.replace, mode 644), so
#    several runners (one per archetype) can run in parallel
# 5. re-imports the exported GLB into an empty scene and renders
#      03-blender-ortho.png       FRONT / BACK / LEFT / RIGHT, one common scale, same ground line (2 x 2, like 02)
#      03-blender-iso.png         800x600, the exact camera + light of the DERIVED board-city renders (front-left)
#      03-blender-board.png       800x600, the board camera's side (front-right, 43.5 deg; lib VIEW_DIRS["board"])
#      03-blender-iso-vs-derived.png   the iso render next to the DERIVED renders of the compare cities
#      assets/custom_map_catalogue/thumbs/<id>.png   512x512, transparent, board view (what the player will see)
# 6. writes model-report.json (dims, aspect, triangles, GLB bytes, materials, night-glow materials) and its
#    acceptance block (DESIGN.md 3.13.5): footprint aspect <= aspect_max (1.3, trees and lamps included), lowest
#    point >= -0.05 (no plinth below the ground), >= 3 door / window materials matching the board's night-glow regex
#    (lanterns do not count), every mesh one material, no textures. A failed item prints "[archetype] ACCEPT_FAIL"
#    (the renders are still made, so the failure can be looked at); archetype_chain.sh then exits 1.
# The comparison cities are the archetype's OWN side (archetype_prompts.hints_for: west archetypes against west
# board cities, east against east).
import bpy, importlib.util, json, math, os, shutil, sys, tempfile, time
from mathutils import Vector

sys.dont_write_bytecode = True  # no __pycache__ next to build.py

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import lib_city_lowpoly as L  # noqa: E402
import archetype_prompts as P  # noqa: E402  (pure stdlib: hints, sides, compare cities)

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
if not args:
    raise SystemExit("usage: Blender -b --factory-startup --python run_archetype_model.py -- <id> [--no-render]")
AID = args[0]
NO_RENDER = "--no-render" in args
ART = os.path.join(ROOT, "art-src/custom-map-catalogue/archetypes", AID)
BUILD = os.path.join(ART, "build.py")
BLEND = os.path.join(ART, f"{AID}.blend")
GLB = os.path.join(ROOT, "assets/custom_map_catalogue/cities", f"{AID}.glb")
BOUNDS = os.path.join(ROOT, "assets/custom_map_catalogue/cities/building_bounds.json")
THUMB = os.path.join(ROOT, "assets/custom_map_catalogue/thumbs", f"{AID}.png")
t0 = time.time()


def log(*a):
    print("[archetype]", *a, flush=True)


SHIPPED_BOARD_HEIGHT = (1.65, 3.61)  # board heights of the 16 shipped cities (rome .. baghdad), batch1/a-board-report.json
BOUNDS_SOURCE = "tools/map_catalogue/run_archetype_model.py (building-only archetype models; centre already at the origin)"
BOUNDS_MODE = 0o644  # the tracked file's mode; mkstemp would otherwise leave 0600


def merge_bounds(path, aid, entry, timeout=120.0):
    """Merge ONE archetype's entry into the shared building_bounds.json so that several runner processes (one per
    archetype, run in parallel) never lose each other's entries or leave a half-written file:
      1. take an exclusive flock on the file's DIRECTORY (every runner locks the same directory; no lock file is left
         behind, and the lock is not on the file itself, whose inode os.replace swaps);
      2. re-read the file under the lock (the latest version, not one read earlier in this run);
      3. set cities[aid] only, keep every other entry and key as it is;
      4. write a temp file in the same directory, fsync, chmod 644, os.replace onto the file (atomic on one volume),
         so a reader sees either the old or the new file, never a partial one.
    A file that exists but cannot be parsed is an error (never silently replaced by a one-entry file)."""
    import fcntl
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    dfd = os.open(d, os.O_RDONLY)
    try:
        t_end = time.time() + timeout
        while True:
            try:
                fcntl.flock(dfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.time() > t_end:
                    raise SystemExit(f"[archetype] could not lock {d} for {timeout:.0f} s (another runner stuck?)")
                time.sleep(0.05)
        bounds = {"source": BOUNDS_SOURCE, "cities": {}}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                bounds = json.load(f)  # a corrupt file raises here instead of being overwritten
        bounds.setdefault("cities", {})[aid] = entry
        fd, tmp = tempfile.mkstemp(prefix=".building_bounds.", suffix=".tmp", dir=d)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(bounds, f, indent=1)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, BOUNDS_MODE)
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
    finally:
        os.close(dfd)  # releases the flock


# ---------------------------------------------------------------- 1-2 build
spec = importlib.util.spec_from_file_location(f"build_{AID}", BUILD)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
prefix = getattr(mod, "PREFIX", "".join(w[0] for w in AID.split("_")).upper())
L.reset_scene()
city = L.new_city(AID, prefix)
mod.build(L, city)
dims = L.finish()
log("built", json.dumps(dims))

# ---------------------------------------------------------------- 3 editable source
os.makedirs(ART, exist_ok=True)
bpy.context.preferences.filepaths.save_version = 0  # no <id>.blend1 backups
bpy.ops.wm.save_as_mainfile(filepath=BLEND, compress=True)
log("saved", os.path.relpath(BLEND, ROOT))

# ---------------------------------------------------------------- 4 GLB + sidecars
joined = L.join_by_material(AID)
L.export_glb(GLB)
imp = GLB + ".import"
if not os.path.exists(imp):
    with open(imp, "w") as f:
        f.write('[remap]\n\nimporter="keep"\n')
merge_bounds(BOUNDS, AID, {"building_width": round(dims["width_x"], 3), "building_depth": round(dims["depth_y"], 3),
                            "building_centre_xz": [0, 0]})
glb_bytes = os.path.getsize(GLB)
log("exported", os.path.relpath(GLB, ROOT), glb_bytes, "bytes,", len(joined), "meshes")

HINT = P.hints_for(AID)
glow_windows = sorted(o.data.materials[0].name for o in joined if L.GLOW_RE.search(o.data.materials[0].name)
                      and "Lamp" not in o.data.materials[0].name)
acc = {"aspect": dims["aspect"], "aspect_max": HINT["aspect_max"], "aspect_ok": dims["aspect"] <= HINT["aspect_max"],
       "min_z": dims["bbox_min"][2], "no_plinth_ok": dims["bbox_min"][2] >= -0.05,
       "glow_window_materials": glow_windows, "glow_windows_ok": len(glow_windows) >= 3,
       "one_material_per_mesh_ok": all(len(o.data.materials) == 1 for o in joined),
       "no_textures_ok": not any(n.type == 'TEX_IMAGE' for m in bpy.data.materials if m.node_tree for n in m.node_tree.nodes)}
acc["ok"] = all(v for k, v in acc.items() if k.endswith("_ok"))
report = {"id": AID, "prefix": prefix, "side": HINT["side"], "acceptance": acc, "blend": os.path.relpath(BLEND, ROOT), "glb": os.path.relpath(GLB, ROOT),
          "glb_bytes": glb_bytes, "dims_blender_zup": dims,
          "gltf_note": "glTF = (x, z, -y): width_x is glTF X, depth_y is glTF Z, front = glTF +Z",
          "materials": sorted(o.data.materials[0].name for o in joined),
          "night_glow_materials": sorted(o.data.materials[0].name for o in joined
                                         if "Lamp" in o.data.materials[0].name or L.GLOW_RE.search(o.data.materials[0].name)),
          "board_scale_at_foot_3_75": round(3.75 / dims["width_x"], 4),
          # information only (not an acceptance item): height on the board at foot 3.75, against the 16 shipped cities'
          # board heights (rome 1.65 ... baghdad 3.61, batch1/a-board-report.json); archetype_models.json
          # defaults.board_notes_common asks for about 2.4-3.5
          "board_height_at_foot_3_75": round(dims["height"] * 3.75 / dims["width_x"], 3),
          "shipped_board_height_range": list(SHIPPED_BOARD_HEIGHT)}

# ---------------------------------------------------------------- 5 renders (of the exported GLB)
if not NO_RENDER:
    TMP = tempfile.mkdtemp(prefix=f"archetype_{AID}_")  # per-view renders, deleted after compositing
    L.import_glb(GLB)
    views = [("front", "FRONT"), ("back", "BACK"), ("left", "LEFT"), ("right", "RIGHT")]
    PW, PH = 800, 560
    common = max(L.fit_scale(v, PW, PH, 1.1) for v, _ in views)
    tmp = []
    for v, label in views:
        d = L.VIEW_DIRS[v]()
        # key light from the camera's upper left so every elevation is lit the same way
        key = (d + Vector((0, 0, 0.9)) + d.cross(Vector((0, 0, 1))) * 0.6).normalized()
        p = os.path.join(TMP, f"ortho-{v}.png")
        L.render_view(p, v, PW, PH, ortho_scale=common, label=label, key_dir=key)
        tmp.append(p)
    L.compose(tmp, os.path.join(ART, "03-blender-ortho.png"), 2, PW, PH)
    shutil.rmtree(TMP, ignore_errors=True)
    iso = L.render_view(os.path.join(ART, "03-blender-iso.png"), "q34", 800, 600)
    L.render_view(os.path.join(ART, "03-blender-board.png"), "board", 800, 600)
    L.render_view(THUMB, "board", 512, 512, margin=1.04, transparent=True)
    # the new iso render beside the DERIVED renders of the compare cities (same camera, light, 800x600)
    comp = HINT["compare_cities"]  # same side as the archetype (hints_for refuses anything else)
    refs = []
    for c in comp:
        rp = os.path.join(ROOT, "art-src/custom-map-catalogue/refs/derived", f"{c}.png")
        if not os.path.exists(rp):
            L.import_glb(os.path.join(ROOT, "assets/merchant_board_claude/cities", f"{c}.glb"))
            L.render_view(rp, "q34", 800, 600)
        refs.append(rp)
    L.compose([os.path.join(ART, "03-blender-iso.png")] + refs, os.path.join(ART, "03-blender-iso-vs-derived.png"),
              len(refs) + 1, 800, 600)
    report["renders"] = {"ortho": "03-blender-ortho.png", "iso": "03-blender-iso.png", "board_view": "03-blender-board.png",
                         "iso_vs_derived": "03-blender-iso-vs-derived.png", "compare_cities": comp,
                         "thumb": os.path.relpath(THUMB, ROOT), "ortho_scale_common": round(common, 4),
                         "iso_ortho_scale": iso["ortho_scale"]}

report["compare_all"] = HINT["compare_all"]
report["seconds"] = round(time.time() - t0, 1)
with open(os.path.join(ART, "model-report.json"), "w") as f:
    json.dump(report, f, indent=1, ensure_ascii=False)
log("RESULT", json.dumps({k: report[k] for k in ("glb_bytes", "board_scale_at_foot_3_75", "board_height_at_foot_3_75")}), "tris", dims["triangles"],
    "aspect", dims["aspect"], "size", dims["width_x"], dims["depth_y"], dims["height"])
bh = report["board_height_at_foot_3_75"]
if not SHIPPED_BOARD_HEIGHT[0] <= bh <= SHIPPED_BOARD_HEIGHT[1]:
    log(f"NOTE board height {bh} is outside the shipped cities' {SHIPPED_BOARD_HEIGHT[0]}-{SHIPPED_BOARD_HEIGHT[1]} "
        "(not an acceptance failure; say why in build.py if it is deliberate)")
log("ACCEPT_OK" if acc["ok"] else "ACCEPT_FAIL", json.dumps(acc))
