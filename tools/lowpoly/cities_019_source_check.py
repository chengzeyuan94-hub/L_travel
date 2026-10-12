"""Open saved editable city sources and reconcile their geometry with exports."""
import bpy,json,hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[2]
lib=root/"docs/design/city-library-019"
rows=[]
for group in ["east","caravan","landmarks"]:
    catalog=json.loads((lib/f"{group}-catalog.json").read_text())
    source=lib/f"source/{group}.blend"
    before=hashlib.sha256(source.read_bytes()).hexdigest()
    bpy.ops.wm.open_mainfile(filepath=str(source))
    expected={a["id"]:a for a in catalog["assets"]}
    meshes=[o for o in bpy.context.scene.objects if o.type=="MESH"]
    assert set(o.get("city_id") for o in meshes)==set(expected)
    for cid,a in expected.items():
        city=[o for o in meshes if o.get("city_id")==cid]
        triangles=0
        for o in city:
            o.data.calc_loop_triangles();triangles+=len(o.data.loop_triangles)
            assert not o.modifiers and all(abs(s-1)<1e-6 for s in o.scale)
            assert len(o.data.materials)==1 and len(o.data.vertices)>0
            assert abs(o["frame_factor"]-a["frame"]["factor"])<1e-8
        assert triangles==a["triangles"] and len(city)==a["meshes"]
        rows.append({"id":cid,"editable_meshes":len(city),"triangles":triangles,"source":str(source),"sha256":before})
    assert before==hashlib.sha256(source.read_bytes()).hexdigest()==catalog["blend_sha256"]
report={"task":"TASK-CITY-LIBRARY-019","blender":bpy.app.version_string,"checker_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"source_files_opened":3,"cities":rows,"errors":[],"city_count":len(rows),"editable_mesh_count":sum(a["editable_meshes"] for a in rows)}
(lib/"validation/blender-source-report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
print("CITY_019_SOURCE_CHECK",len(rows),report["editable_mesh_count"])
