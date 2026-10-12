"""Read-only source inspection in an isolated Blender CLI process."""
import bpy, json, pathlib
from mathutils import Vector

root = pathlib.Path(__file__).resolve().parents[3]
report = {}
for asset in ('fortress', 'pine'):
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    bpy.ops.import_scene.fbx(filepath=str(root / 'assets/traveler/panti' / (asset + '-raw.fbx')), use_anim=False)
    rows = []
    for ob in bpy.context.scene.objects:
        if ob.type != 'MESH': continue
        ob.data.calc_loop_triangles()
        points = [ob.matrix_world @ v.co for v in ob.data.vertices]
        lo = [min(p[i] for p in points) for i in range(3)]
        hi = [max(p[i] for p in points) for i in range(3)]
        mats = []
        for mat in ob.data.materials:
            mats.append({'name':mat.name, 'images':[
                {'name':n.image.name, 'path':n.image.filepath, 'size':list(n.image.size)}
                for n in mat.node_tree.nodes if n.type == 'TEX_IMAGE' and n.image]})
        rows.append({'name':ob.name,'triangles':len(ob.data.loop_triangles),'vertices':len(ob.data.vertices),'min':lo,'max':hi,'dimensions':[hi[i]-lo[i] for i in range(3)],'matrix':[list(r) for r in ob.matrix_world],'materials':mats})
    report[asset]=rows
out = root / 'docs/reports/traveler-panti-001/assets/source-inspection.json'
out.write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
