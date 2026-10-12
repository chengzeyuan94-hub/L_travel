"""Blender CLI: --background [source.blend] --python this.py -- --mode source|rebuild --output path.glb.
The saved .blend is the production source; rebuild additionally checks the authoring scripts.
"""
import argparse, json, os, sys
from pathlib import Path
import bpy

parser=argparse.ArgumentParser()
parser.add_argument('--mode',choices=['source','rebuild'],required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args(sys.argv[sys.argv.index('--')+1:])
root=Path(__file__).resolve().parents[2]
args.output=args.output.resolve();args.output.parent.mkdir(parents=True,exist_ok=True)
if args.mode=='rebuild':
    os.environ['SILKROAD_MOUNTAIN_OUTPUT']=str(args.output.parent/'rebuild-intermediates')
    namespace={'__name__':'__main__'}
    for script in ['blender_mountain.py','blender_mountain_quality.py']:
        path=root/'tools/traveler'/script
        exec(compile(path.read_text(),str(path),'exec'),namespace)
obj=next(o for o in bpy.context.scene.objects if o.type=='MESH' and o.name.startswith('T7 Snowcap Massif'))
for o in bpy.context.scene.objects:o.select_set(False)
obj.select_set(True);bpy.context.view_layer.objects.active=obj
bpy.ops.export_scene.gltf(filepath=str(args.output),export_format='GLB',use_selection=True,
    use_active_scene=True,export_materials='EXPORT',export_animations=False,
    export_cameras=False,export_lights=False,export_yup=True)
report={'mode':args.mode,'blender_version':bpy.app.version_string,'output':str(args.output),
    'vertices':len(obj.data.vertices),'triangles':len(obj.data.polygons),
    'snow_faces':sum(p.material_index==1 for p in obj.data.polygons)}
args.output.with_suffix('.json').write_text(json.dumps(report,indent=2))
print('MOUNTAIN_REPRODUCTION '+json.dumps(report))
