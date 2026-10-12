"""Read the supplied sitting FBX in an isolated Blender process."""
import bpy, json, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / 'docs/reports/traveler-panti-001/assets/camp-character'
OUT.mkdir(parents=True, exist_ok=True)
SOURCE = pathlib.Path('/Users/chengzeyuan/Desktop/露营点位模型及概念图/L叔坐下-Sitting.fbx')

def bounds(ob):
    p = [ob.matrix_world @ v.co for v in ob.data.vertices]
    lo = [min(v[i] for v in p) for i in range(3)]
    hi = [max(v[i] for v in p) for i in range(3)]
    return {'min':lo, 'max':hi, 'size':[hi[i]-lo[i] for i in range(3)]}

def scan(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=str(path), use_anim=True)
    result={'source':str(path),'fps':bpy.context.scene.render.fps, 'objects':[], 'actions':[], 'images':[]}
    for ob in bpy.context.scene.objects:
        item={'name':ob.name,'type':ob.type,'location':list(ob.location),'rotation':list(ob.rotation_euler),'scale':list(ob.scale),'parent':ob.parent.name if ob.parent else None}
        if ob.type=='MESH':
            ob.data.calc_loop_triangles()
            item.update(bounds= bounds(ob),vertices=len(ob.data.vertices),triangles=len(ob.data.loop_triangles),materials=[m.name for m in ob.data.materials],groups=[g.name for g in ob.vertex_groups])
        if ob.type=='ARMATURE': item.update(bones=[b.name for b in ob.data.bones],active_action=ob.animation_data.action.name if ob.animation_data and ob.animation_data.action else None)
        result['objects'].append(item)
    for ac in bpy.data.actions: result['actions'].append({'name':ac.name,'range':list(ac.frame_range),'slots':[s.identifier for s in ac.slots]})
    for im in bpy.data.images: result['images'].append({'name':im.name,'path':im.filepath,'packed':bool(im.packed_file),'size':list(im.size)})
    return result

report={'sitting':scan(SOURCE),'approved_idle':scan(ROOT/'assets/traveler/characters/action2/animations/idle.fbx')}
(OUT/'source-inspection.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
