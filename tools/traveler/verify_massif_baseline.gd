extends SceneTree
func _initialize() -> void:
	var old_script := GDScript.new()
	old_script.source_code=FileAccess.get_file_as_string("res://docs/design/shanhe-luren/mountain-rework/legacy-generator-source.gd.txt")
	if old_script.reload()!=OK:push_error("Old script cannot load");quit(1);return
	var old=old_script.new()
	var current=load("res://scripts/traveler/traveler_lookdev.gd").new()
	current.audit_enabled=true
	var rng:=RandomNumberGenerator.new();rng.seed=20260918
	var target:=Vector3(28.3460006713867,1.49336516857147,6.19920015335083)
	var bands:=[
		{"z":-62.0,"count":7,"h":22.0,"r":21.0,"span":150.0,"rock":Color(0.40,0.38,0.52),"snow":Color(0.90,0.90,0.97),"ang":22,"ring":8},
		{"z":-102.0,"count":7,"h":34.0,"r":31.0,"span":210.0,"rock":Color(0.52,0.50,0.64),"snow":Color(0.93,0.93,0.98),"ang":20,"ring":7},
		{"z":-152.0,"count":6,"h":46.0,"r":41.0,"span":280.0,"rock":Color(0.63,0.62,0.76),"snow":Color(0.96,0.96,0.99),"ang":18,"ring":6}]
	var rows:Array=[]
	for bi in bands.size():
		var b:Dictionary=bands[bi];var specs:Array=[]
		for i in int(b.count):
			var t:=float(i)/float(int(b.count)-1)
			var x:float=-float(b.span)*.5+float(b.span)*t+rng.randf_range(-10,10)
			var z:float=float(b.z)+rng.randf_range(-7,7)
			specs.append({"pos":Vector3(target.x+x,-1.2-float(bi)*.5,target.z+z),"h":float(b.h)*rng.randf_range(.82,1.22),"r":float(b.r)*rng.randf_range(.86,1.18)})
		var before:ArrayMesh=old.build_massif_band(specs,b.rock,b.snow,20260918+bi*77,b.ang,b.ring)
		var after:ArrayMesh=current.build_massif_band(specs,b.rock,b.snow,20260918+bi*77,b.ang,b.ring)
		var aa:=var_to_bytes(before.surface_get_arrays(0));var bb:=var_to_bytes(after.surface_get_arrays(0))
		rows.append({"band":bi,"identical":aa==bb,"before_hash":aa.hex_encode().sha256_text(),"after_hash":bb.hex_encode().sha256_text()})
		if aa!=bb:push_error("Audit changed geometry")
	var file:=FileAccess.open("res://docs/design/shanhe-luren/mountain-rework/legacy-preservation.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"bands":rows,"source_snapshot":"res://docs/design/shanhe-luren/mountain-rework/legacy-generator-source.gd.txt"},"\t"));file.close()
	print("LEGACY_PRESERVATION ",JSON.stringify(rows))
	quit()
