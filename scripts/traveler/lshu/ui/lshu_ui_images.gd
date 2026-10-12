extends RefCounted
## Act 4 UI: postcard image cache. Postcard fronts are JPGs on disk (record.file, usually an
## absolute path under the save folder). Big fronts load on request; book and away-card thumbnails
## decode and shrink on WorkerThreadPool so opening the travel book never stalls the frame.
## LshuUi calls poll() every frame and shutdown() when it leaves the tree.

const THUMB_PX: int = 320
const MAX_ENTRIES: int = 96

var _cache: Dictionary = {}          # key -> Texture2D
var _order: Array[String] = []       # LRU, oldest first
var _jobs: Dictionary = {}           # key -> {task:int, callbacks:Array[Callable]}
var _results: Dictionary = {}        # key -> Image (written by workers)
var _mutex: Mutex = Mutex.new()
var loads: int = 0                   # evidence counters for QA
var failures: int = 0


static func file_ok(path: String) -> bool:
	return path != "" and FileAccess.file_exists(path)


## Full-size texture, loaded now (a front is one image; ~10–20 ms for a 1080p JPG). null when the
## file is missing or unreadable.
func texture(path: String) -> Texture2D:
	var key: String = path + "@0"
	if _cache.has(key):
		_touch(key)
		return _cache[key]
	if not file_ok(path):
		return null
	var img: Image = Image.load_from_file(path)
	if img == null or img.is_empty():
		failures += 1
		return null
	loads += 1
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_put(key, tex)
	return tex


func cached(path: String, max_px: int) -> Texture2D:
	var key: String = path + "@" + str(max_px)
	if _cache.has(key):
		_touch(key)
		return _cache[key]
	if max_px > 0 and _cache.has(path + "@0"):
		return _cache[path + "@0"]
	return null


## Thumbnail, decoded off the main thread. `done` gets the Texture2D (or null) on a later frame
## (immediately when cached).
func request(path: String, max_px: int, done: Callable) -> void:
	var hit: Texture2D = cached(path, max_px)
	if hit != null:
		if done.is_valid():
			done.call(hit)
		return
	if not file_ok(path):
		if done.is_valid():
			done.call(null)
		return
	var key: String = path + "@" + str(max_px)
	if _jobs.has(key):
		if done.is_valid():
			((_jobs[key] as Dictionary).callbacks as Array).append(done)
		return
	var task: int = WorkerThreadPool.add_task(_decode.bind(path, max_px, key), false, "lshu_ui_thumb")
	_jobs[key] = {"task": task, "callbacks": [done] if done.is_valid() else []}


## Warm the full-size cache for fronts that will likely be opened (unread postcards).
func prefetch(path: String) -> void:
	request(path, 0, Callable())


func poll() -> void:
	if _jobs.is_empty():
		return
	for key: Variant in _jobs.keys():
		var job: Dictionary = _jobs[key]
		if not WorkerThreadPool.is_task_completed(int(job.task)):
			continue
		WorkerThreadPool.wait_for_task_completion(int(job.task))
		_jobs.erase(key)
		_mutex.lock()
		var img: Image = _results.get(key, null) as Image
		_results.erase(key)
		_mutex.unlock()
		var tex: Texture2D = null
		if img != null and not img.is_empty():
			tex = ImageTexture.create_from_image(img)
			_put(String(key), tex)
			loads += 1
		else:
			failures += 1
		for cb: Variant in job.callbacks as Array:
			var c: Callable = cb
			if c.is_valid():
				c.call(tex)


func pending() -> int:
	return _jobs.size()


func shutdown() -> void:
	for key: Variant in _jobs.keys():
		WorkerThreadPool.wait_for_task_completion(int((_jobs[key] as Dictionary).task))
	_jobs.clear()
	_mutex.lock()
	_results.clear()
	_mutex.unlock()


func _decode(path: String, max_px: int, key: String) -> void:
	var img: Image = Image.load_from_file(path)
	if img != null and not img.is_empty() and max_px > 0:
		var longest: int = maxi(img.get_width(), img.get_height())
		if longest > max_px:
			var k: float = float(max_px) / float(longest)
			img.resize(maxi(1, roundi(img.get_width() * k)), maxi(1, roundi(img.get_height() * k)), Image.INTERPOLATE_CUBIC)
	_mutex.lock()
	_results[key] = img
	_mutex.unlock()


func _put(key: String, tex: Texture2D) -> void:
	_cache[key] = tex
	_order.erase(key)
	_order.append(key)
	while _order.size() > MAX_ENTRIES:
		var old: String = _order.pop_front()
		_cache.erase(old)


func _touch(key: String) -> void:
	_order.erase(key)
	_order.append(key)
