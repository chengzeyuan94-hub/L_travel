# Headless twin of tools/ui_icons/run_asset.sh.
#
# run_asset.sh sends three scripts to Carlos's live Blender over bl.py (localhost:9876):
#   setup_studio.py (once) -> lib_lowpoly.py + KEY + assets/<key>.py -> KEY/OUT_* + render_asset.py
# This file runs the SAME three unmodified scripts, in the same order and each in a fresh
# namespace (blender-mcp's execute_code does exec(code, {"bpy": bpy})), inside one background
# Blender process started with --factory-startup. It never opens a socket.
#
# Usage (normally through run_icon_headless.sh):
#   Blender -b --factory-startup --python icon_headless.py -- \
#       --key kaolin --asset art-src/custom-map-catalogue/specialties/kaolin/asset.py \
#       --out-icon assets/game/ui/lshu_3d/icons/kaolin.png \
#       --out-doc art-src/custom-map-catalogue/specialties/kaolin \
#       --out-glb art-src/custom-map-catalogue/specialties/kaolin/kaolin.glb \
#       --out-blend art-src/custom-map-catalogue/specialties/kaolin/kaolin.blend
import bpy, sys, os, json, argparse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
UI_ICONS = os.path.join(REPO, "tools", "ui_icons")

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("--key", required=True)
ap.add_argument("--asset", required=True, help="modelling script (same contract as tools/ui_icons/assets/<key>.py)")
ap.add_argument("--out-icon", required=True)
ap.add_argument("--out-doc", required=True, help="folder for the four-way ortho strip")
ap.add_argument("--out-glb", required=True)
ap.add_argument("--out-blend", required=True)
ap.add_argument("--ortho-name", default="03-blender-ortho.png",
                help="render_asset.py writes 04-ortho-check.png; it is renamed to this (the 01/02/03 design-folder convention)")
ap.add_argument("--match-live", action="store_true",
                help="reproduce the live-Blender state the shipped icons were built in (see below); only for parity checks")
a = ap.parse_args(argv)


def run(label, code):
    ns = {"bpy": bpy, "__name__": "__main__"}
    exec(compile(code, label, "exec"), ns)
    return ns


def src(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


# 1. the studio, exactly as tools/ui_icons/setup_studio.py builds it
run("setup_studio.py", src(os.path.join(UI_ICONS, "setup_studio.py")))
studio = bpy.data.scenes["LshuIconStudio"]
assert bpy.context.window.scene == studio and bpy.context.scene == studio, "studio is not the window scene"

# Factory startup brings a scene called "Scene" with the default Cube/Light/Camera. Carlos's
# file has it too; it is never rendered (render_asset renders the window scene) and GLB export
# is selection-only, but it would leak into the saved .blend source, so drop it.
for sc in list(bpy.data.scenes):
    if sc != studio:
        bpy.data.scenes.remove(sc)
for o in list(bpy.data.objects):
    if studio not in o.users_scene:
        bpy.data.objects.remove(o, do_unlink=True)
for coll in (bpy.data.collections, bpy.data.meshes, bpy.data.lights, bpy.data.cameras, bpy.data.materials):
    for d in list(coll):
        if d.users == 0:
            coll.remove(d)

# 2. model: lib_lowpoly.py + KEY + asset script, one namespace (what run_asset.sh concatenates)
if a.match_live:
    # In Carlos's Blender every icon_<key> collection already existed and had been viewport-disabled
    # by render_asset.py rendering some other key. Objects created in a viewport-disabled collection
    # are not evaluated, so lib_lowpoly.finish() measured identity matrices and set each asset down at
    # a slightly different world offset (tea: +0.073 z). Framing is unaffected (render_asset.py frames
    # the bounds after unhiding); only the sun shadow-map texel alignment moves, which is the whole
    # difference between a plain headless run and the shipped PNGs. With this flag the re-render is
    # pixel-identical to the shipped tea/porcelain/jade PNGs. New assets should NOT use it: without it
    # finish() really puts the model on the ground at the origin, which is what the GLB wants.
    _c = bpy.data.collections.new("icon_" + a.key)
    bpy.data.collections["LshuIcons"].children.link(_c)
    _c.hide_viewport = True
model_code = src(os.path.join(UI_ICONS, "lib_lowpoly.py")) + "\n" + f"KEY = {a.key!r}\n" + src(a.asset)
run(os.path.basename(a.asset), model_code)

# 3. render + ortho strip + GLB with render_asset.py
render_code = (f"KEY = {a.key!r}\nOUT_ICON = {os.path.abspath(a.out_icon)!r}\n"
               f"OUT_DOC = {os.path.abspath(a.out_doc)!r}\nOUT_GLB = {os.path.abspath(a.out_glb)!r}\n"
               + src(os.path.join(UI_ICONS, "render_asset.py")))
run("render_asset.py", render_code)
strip_src = os.path.join(os.path.abspath(a.out_doc), "04-ortho-check.png")
strip_dst = os.path.join(os.path.abspath(a.out_doc), a.ortho_name)
if strip_src != strip_dst and os.path.exists(strip_src):
    os.replace(strip_src, strip_dst)

# 4. keep the editable source next to the export (studio + this one asset only)
studio.render.filepath = "//"
os.makedirs(os.path.dirname(os.path.abspath(a.out_blend)), exist_ok=True)
bpy.context.preferences.filepaths.save_version = 0  # no <key>.blend1 backup next to the source
bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(a.out_blend), copy=True, compress=True)

col = bpy.data.collections["icon_" + a.key]
objs = [o for o in col.all_objects if o.type == 'MESH']
print("ICON_HEADLESS_RESULT " + json.dumps({
    "key": a.key, "blender": bpy.app.version_string, "objects": len(objs),
    "tris": sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs),
    "icon": os.path.abspath(a.out_icon), "ortho": strip_dst,
    "glb": os.path.abspath(a.out_glb), "blend": os.path.abspath(a.out_blend)}))
