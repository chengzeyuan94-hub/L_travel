extends RefCounted
## Full native-resolution HSV in display RGB, with no resizing or color edits.
static func hsv_stats(source: Image) -> Dictionary:
	var image := source.duplicate() as Image
	image.convert(Image.FORMAT_RGB8)
	var bytes := image.get_data()
	var sum_v := 0.0
	var sum_s := 0.0
	for i in range(0,bytes.size(),3):
		var hi := maxi(bytes[i],maxi(bytes[i+1],bytes[i+2]))
		var lo := mini(bytes[i],mini(bytes[i+1],bytes[i+2]))
		sum_v += hi
		if hi>0:sum_s+=float(hi-lo)/float(hi)
	var count := image.get_width()*image.get_height()
	return {"meanV":sum_v/(255.0*count),"meanS":sum_s/count,"pixels":count,
		"image_size":[image.get_width(),image.get_height()],"color_space":"display RGB HSV"}
