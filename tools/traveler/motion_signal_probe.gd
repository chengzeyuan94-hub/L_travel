extends SceneTree
func _initialize() -> void:
	var director: Node = load("res://scripts/traveler/motion_director.gd").new()
	var dt := 1.0/30.0
	var values: Array = []
	var max_rate := 0.0
	var previous: float = director.gust(0.0)
	for i in 1800:
		var value: float = director.gust(float(i)*dt)
		if i>0:max_rate=maxf(max_rate,absf(value-previous)/dt)
		values.append(value)
		previous=value
	var report := {"sample_count":values.size(),"sampling_fps":30,"wind_gust_min":values.min(),"wind_gust_max":values.max(),"wind_gust_max_abs_derivative_per_second":max_rate,"non_wind_terms":[],"non_wind_terms_verdict":"not applicable: S4-S10 excluded in round one","engine_max_fps":Engine.max_fps}
	var file := FileAccess.open("res://docs/reports/traveler-motion-001/S3-signals.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("MOTION_SIGNALS ",JSON.stringify(report))
	director.free()
	quit()
