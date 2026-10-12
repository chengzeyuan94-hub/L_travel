extends Node
## 手柄输入层（2026-09-29 Carlos：「aynthor 需要提供 abxy 键位的对应控制，肩键等键位的控制……参考 xbox 手柄」）。
## 自动加载 PadInput。键位按 Xbox 手柄的习惯（位置语义：JOY_BUTTON_A = 下方键）：
##   A = 确认：按主按钮，或按焦点框框着的那个按钮（只确认，不挑选）
##   B = 返回：清掉挑选 → 关浮层 → 返回；从不做不可逆的事（Select / 机身 Back 键 / 安卓返回手势都算 B）
##   X = 多选里勾 / 不勾；电脑回合「电脑走快点」；把焦点框挪到次要按钮（换乘、不交易结束回合）
##   Y = 移动时「原地停留」；市集收起 / 展开；旅人幕开关提示；找 L叔 开合旅行本
##   LB / RB = 在同一组候选里轮换        LT / RT（读轴）= 地图缩小 / 放大
##   右摇杆 = 平移地图   R3 = 镜头归位   L3 = 镜头跟到当前玩家   Start = 对局小菜单
##   十字键 / 左摇杆 = 移动焦点框（对局的单选决策里：高亮就是挑选，和鼠标点一下一样只是选中）
## AYN Thor 的 ABXY 印的是任天堂布局；系统「Style」保持 Standard 时，印着 A 的键发的就是 A（调研 §1.1），
## 所以屏幕上的小圆标只写字母，不画 Xbox 的菱形位置图。
##
## 动作层：运行时往 InputMap 注册 pad_* 动作（ACTIONS；不写进 project.godot，不碰 ui_* 和键盘动作），只绑手柄键
## 和左摇杆方向；键盘、鼠标、触屏一律不经过这里。手柄事件在这里用掉（set_input_as_handled），Godot 自带的
## 焦点导航不会再拿同一下去按别的按钮（本项目的按钮几乎都是 FOCUS_NONE，焦点顺序由各页自己给）。
## 扳机只读轴（安卓上 L2/R2 的数字键会被映成 MISC1 或丢掉，调研 §2.1），静止值可能是 −1（Xbox 映射表），按 >0.5 判。
##
## 手柄模式：按了手柄键 / 推了摇杆就进，动了鼠标、点了屏幕、按了键盘就退。焦点框和字母小圆标只在手柄模式里画，
## 只用鼠标 / 触屏 / 键盘的人看不到任何新东西，桌面行为和以前一样。
##
## 页面把自己登记成「手柄上下文」（register），这里按优先级找现在在前面的那一页，把动作交给它：
##   pad_active() -> bool       现在是不是这一页在前面
##   pad_action(name) -> bool   处理一个动作：accept back x y lb rb start l3 r3 up down left right
##   pad_focus() -> Variant     焦点框框哪儿：Control / Rect2（画布坐标）/ null
##   pad_glyphs() -> Array      [[Control, "A"(, "side")], …]：贴在按钮左上角的字母小圆标（"side" = 放在小药丸旁边）
##   pad_axes(pan: Vector2, zoom: float, dt: float)（可选）右摇杆（-1..1）/ 扳机（放大为正）的连续量，dt 是真实秒数
##   pad_wake() -> bool（可选）为真时：从鼠标 / 触屏换到手柄的第一下只亮出焦点框，不按下去（开场、设置页）
## 分组 "pad_blocker" 里的节点可见时（加载页）手柄动作一律吞掉。
##
## 只在安卓上开（Carlos 2026-09-29：这几处改动「仅限于安卓版本」；桌面 macOS / Windows 要和以前一模一样，
## 连着手柄也一样：手柄事件不在这里用掉、不进手柄模式、不画焦点框）。桌面上要试：-- --lshu-pad；测试里 PadInput.enabled = true。
##
## 触屏防误触（touch_guards，2026-09-30 安卓压力测试 TS-2/3/4/5/7/8）：也只在安卓上开，桌面上要试：-- --lshu-touch-guards；
## 测试里 PadInput.touch_guards = true。开着时：
##   · 系统取消的触摸（手掌误触、拉通知栏、边缘返回手势：安卓 ACTION_CANCEL，Godot 里 canceled = true）松开时不算点
##     （release_canceled()：这一下是不是这种松开；各确认按钮在 pressed 里先问它）
##   · 「不交易，结束回合」先选再确认；旅人幕「‹ 返回」、对局里的齿轮、开场「退出游戏」要「点一下、停一下再点」；
##     开场设置里不放「全屏显示」；有没下完的存档时「出发！」也要点两次（见各处）
## 手机从后台回来 / 失去焦点：按着的方向、摇杆、扳机一律当松开（安卓不会补发松开，MC-1）。

signal pad_mode_changed(on: bool)
## 每分发一个动作发一次（测试和调试日志用）：name、处理它的上下文（空 = 没人要）、它是否用掉了
signal dispatched(name: String, context: String, used: bool)

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")

## 动作名 → 手柄键（device = -1：任何一个手柄）
const BUTTONS := {
	"pad_accept": [JOY_BUTTON_A],
	"pad_back": [JOY_BUTTON_B, JOY_BUTTON_BACK],
	"pad_x": [JOY_BUTTON_X],
	"pad_y": [JOY_BUTTON_Y],
	"pad_lb": [JOY_BUTTON_LEFT_SHOULDER],
	"pad_rb": [JOY_BUTTON_RIGHT_SHOULDER],
	"pad_start": [JOY_BUTTON_START],
	"pad_l3": [JOY_BUTTON_LEFT_STICK],
	"pad_r3": [JOY_BUTTON_RIGHT_STICK],
	"pad_up": [JOY_BUTTON_DPAD_UP],
	"pad_down": [JOY_BUTTON_DPAD_DOWN],
	"pad_left": [JOY_BUTTON_DPAD_LEFT],
	"pad_right": [JOY_BUTTON_DPAD_RIGHT],
}
## 左摇杆也绑在四个方向动作上（Input.is_action_pressed 用得上）；导航本身按下面的主方向 + 回差判
const STICK := {
	"pad_up": [JOY_AXIS_LEFT_Y, -1.0], "pad_down": [JOY_AXIS_LEFT_Y, 1.0],
	"pad_left": [JOY_AXIS_LEFT_X, -1.0], "pad_right": [JOY_AXIS_LEFT_X, 1.0],
}
const DIRS := {"pad_up": Vector2.UP, "pad_down": Vector2.DOWN, "pad_left": Vector2.LEFT, "pad_right": Vector2.RIGHT}
const ACTION_DEADZONE := 0.5
## 左摇杆当方向键：推过 0.6 算按下，回到 0.35 以内算松开（回差，免得在边上抖）
const STICK_ON := 0.6
const STICK_OFF := 0.35
## 右摇杆死区；扳机过 0.12 才开始缩放
const PAN_DEADZONE := 0.22
const TRIGGER_DEADZONE := 0.12
## 按住方向：0.38 秒后开始连发，之后每 0.13 秒一下
const REPEAT_DELAY_MS := 380
const REPEAT_EVERY_MS := 130
## 鼠标挪多远算「改用鼠标了」（桌面上碰一下桌子不退出手柄模式）
const MOUSE_EXIT_PX := 12.0
## 焦点框 / 小圆标画在最上面（旅人幕的界面 120、入场片 125 之上）
const LAYER := 127

## 手柄层开没开（安卓上开；桌面上只有带 -- --lshu-pad 或测试打开时才开）。关着时整层什么都不做
var enabled := false:
	set(v):
		enabled = v
		if not v:
			set_pad_mode(false)
var pad_mode := false
## 最近一次用的手柄（日志用）；-1 = 还没有
var last_device := -1
## 触屏防误触开没开（安卓上开；桌面上只有带 -- --lshu-touch-guards 或测试打开时才开），见文件头
var touch_guards := false
## 正在分发的这一下是不是「系统取消的触摸松开」（每帧清掉）
var _release_canceled := false
## 正在分发的这一下是不是触屏（ScreenTouch，或手指模拟出来的鼠标）；每帧清掉。桌面上没有触屏，永远是 false
var _touch_dispatch := false
## 正在分发的方向是按住不放的自动连发（滑条这类「一下一格」的地方不跟着连发）
var repeating := false

var _contexts: Array = []      # [{node: Node, priority: int, serial: int}]
var _serial := 0
var _held_dir := ""            # 十字键按住的方向动作名
var _stick_dir := ""           # 左摇杆当前的方向动作名
var _repeat_dir := ""
var _repeat_at := 0
var _axes := {}                # JoyAxis -> 最近一次的值
var _trigger_rest := {JOY_AXIS_TRIGGER_LEFT: 0.0, JOY_AXIS_TRIGGER_RIGHT: 0.0}
var _mouse_travel := 0.0
var _layer: CanvasLayer
var _ring: PadRing


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	enabled = OS.has_feature("android") or "--lshu-pad" in OS.get_cmdline_user_args()
	touch_guards = OS.has_feature("android") or "--lshu-touch-guards" in OS.get_cmdline_user_args()
	_register_actions()
	_layer = CanvasLayer.new()
	_layer.name = "PadFocusLayer"
	_layer.layer = LAYER
	add_child(_layer)
	_ring = PadRing.new()
	_ring.name = "PadRing"
	_ring.font = Kit.font("body", 800)
	_layer.add_child(_ring)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	if OS.has_feature("android"):
		# 安卓的返回手势（沉浸模式下从边上划两次）默认直接关掉游戏：孩子乱划一下整局就没了。
		# 改成和 B 一样（清掉挑选 / 关浮层 / 旅人幕里叫出「返回」，从不做不可逆的事）
		get_tree().quit_on_go_back = false
		get_tree().root.go_back_requested.connect(func() -> void: _dispatch("back"))
	if enabled:
		for id in Input.get_connected_joypads():
			print("PAD_CONNECTED ", JSON.stringify({"device": id, "name": Input.get_joy_name(id), "guid": Input.get_joy_guid(id)}))


func _register_actions() -> void:
	for action: String in BUTTONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, ACTION_DEADZONE)
		for b: int in BUTTONS[action]:
			var e := InputEventJoypadButton.new()
			e.device = -1
			e.button_index = b as JoyButton
			if not InputMap.action_has_event(action, e):
				InputMap.action_add_event(action, e)
		if STICK.has(action):
			var m := InputEventJoypadMotion.new()
			m.device = -1
			m.axis = STICK[action][0] as JoyAxis
			m.axis_value = float(STICK[action][1])
			if not InputMap.action_has_event(action, m):
				InputMap.action_add_event(action, m)


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if not enabled:
		return
	print("PAD_CONNECTION ", JSON.stringify({"device": device, "connected": connected, "name": Input.get_joy_name(device) if connected else ""}))
	if not connected and device == last_device:
		_release_dirs()
		set_pad_mode(false)


# ------------------------------------------------------------------ 上下文
## 登记一页。priority 大的在前（入场片 60 > 旅人幕 50 > 对局 20 > 设置页 / 开场 10）；同级时后登记的在前
func register(node: Node, priority: int = 0) -> void:
	unregister(node)
	_serial += 1
	_contexts.append({"node": node, "priority": priority, "serial": _serial})
	if not node.tree_exiting.is_connected(unregister):
		node.tree_exiting.connect(unregister.bind(node), CONNECT_ONE_SHOT)


func unregister(node: Node) -> void:
	for i in range(_contexts.size() - 1, -1, -1):
		if _contexts[i].node == node or not is_instance_valid(_contexts[i].node):
			_contexts.remove_at(i)


## 现在在前面的那一页（没有就 null）；加载页这类挡板可见时也是 null
func active_context() -> Node:
	if blocked():
		return null
	var best: Dictionary = {}
	for c: Dictionary in _contexts:
		var n: Node = c.node
		if not is_instance_valid(n) or not n.is_inside_tree():
			continue
		if not bool(n.call("pad_active")):
			continue
		if best.is_empty() or int(c.priority) > int(best.priority) or (int(c.priority) == int(best.priority) and int(c.serial) > int(best.serial)):
			best = c
	return best.node if not best.is_empty() else null


func blocked() -> bool:
	if not is_inside_tree():
		return true
	for n in get_tree().get_nodes_in_group("pad_blocker"):
		if n is CanvasItem and (n as CanvasItem).is_visible_in_tree():
			return true
	return false


func _dispatch(name: String) -> bool:
	if not enabled:
		return false
	var ctx := active_context()
	var used := false
	if ctx != null:
		used = bool(ctx.call("pad_action", name))
	dispatched.emit(name, String(ctx.name) if ctx != null else "", used)
	return used


# ------------------------------------------------------------------ 事件
func _input(event: InputEvent) -> void:
	# 这一下是不是手指（按钮会从原始的 ScreenTouch 自己按下去，game_screen 的防连点要知道：TS-1）
	_touch_dispatch = event is InputEventScreenTouch or event is InputEventScreenDrag or (
		(event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION
	)
	if touch_guards:
		# 这一下是不是系统取消的松开：_input 在界面分发之前跑，按钮在同一下里发 pressed，确认按钮的 pressed 里问 release_canceled()。
		# 不在这里吞掉取消事件：吞掉一半会让按钮的 press_attempt / 触摸序号卡住（TS-3）
		_release_canceled = (
			(event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed and (event as InputEventScreenTouch).canceled)
			or (event is InputEventMouseButton and not (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).canceled)
		)
	if not enabled:
		return          # 桌面：手柄事件原样往下走（和以前一样）
	if event is InputEventJoypadButton:
		_on_joy_button(event as InputEventJoypadButton)
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadMotion:
		_on_joy_motion(event as InputEventJoypadMotion)
		get_viewport().set_input_as_handled()
	elif pad_mode:
		if event is InputEventMouseMotion:
			_mouse_travel += (event as InputEventMouseMotion).relative.length()
			if _mouse_travel > MOUSE_EXIT_PX:
				set_pad_mode(false)
		elif (
			(event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
			or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
			or (event is InputEventKey and (event as InputEventKey).pressed and not _is_system_key(event as InputEventKey))
		):
			set_pad_mode(false)


## 机身侧面的音量键这类不是「改用键盘了」：按它不退出手柄模式（Thor 的音量键走键盘那条路）
static func _is_system_key(k: InputEventKey) -> bool:
	return k.keycode in [KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_VOLUMEMUTE, KEY_MEDIAPLAY, KEY_MEDIASTOP, KEY_MEDIAPREVIOUS, KEY_MEDIANEXT]


func _on_joy_button(e: InputEventJoypadButton) -> void:
	last_device = e.device
	var dir := ""
	for action: String in DIRS:
		if e.is_action(action, true):
			dir = action
	if not e.pressed:
		if dir != "" and dir == _held_dir:
			_held_dir = ""
		return
	if _wake():
		return
	if dir != "":
		_held_dir = dir
		_nav(dir)
		return
	for action: String in BUTTONS:
		if e.is_action_pressed(action, false, true):
			_dispatch(action.trim_prefix("pad_"))
			return


func _on_joy_motion(e: InputEventJoypadMotion) -> void:
	last_device = e.device
	_axes[e.axis] = e.axis_value
	match e.axis:
		JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y:
			var v := Vector2(float(_axes.get(JOY_AXIS_LEFT_X, 0.0)), float(_axes.get(JOY_AXIS_LEFT_Y, 0.0)))
			var d := _stick_dir
			if v.length() < STICK_OFF:
				d = ""
			elif v.length() > STICK_ON:
				d = _dominant(v)
			if d != _stick_dir:
				_stick_dir = d
				if d != "":
					if _wake():
						_repeat_dir = d                       # 叫醒的这一推：按住也不连发，松开再推才走
						_repeat_at = Time.get_ticks_msec() + 3600000
					else:
						_nav(d)
		JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT:
			if e.axis_value < -0.05:
				_trigger_rest[e.axis] = -1.0     # Xbox 映射表：扳机静止是 −1（调研 §2.2）
			if trigger(e.axis) > 0.3:
				set_pad_mode(true)
		_:
			if absf(e.axis_value) > 0.4:
				set_pad_mode(true)


## 进手柄模式。刚从鼠标 / 触屏换过来的这一下：页面菜单（开场、设置页：pad_wake() 为真）只把焦点框亮出来，
## 不按下去——孩子先看见框在哪儿，再按才算。返回 true = 这一下只用来叫醒
func _wake() -> bool:
	var was := pad_mode
	set_pad_mode(true)
	if was:
		return false
	var ctx := active_context()
	if ctx != null and ctx.has_method("pad_wake") and bool(ctx.call("pad_wake")):
		dispatched.emit("wake", String(ctx.name), false)
		return true
	return false


static func _dominant(v: Vector2) -> String:
	if absf(v.x) >= absf(v.y):
		return "pad_right" if v.x > 0.0 else "pad_left"
	return "pad_down" if v.y > 0.0 else "pad_up"


func _nav(action: String) -> void:
	_repeat_dir = action
	_repeat_at = Time.get_ticks_msec() + REPEAT_DELAY_MS
	_dispatch(action.trim_prefix("pad_"))


func _release_dirs() -> void:
	_held_dir = ""
	_stick_dir = ""
	_repeat_dir = ""
	_axes.clear()


## 切到后台 / 失去焦点（掌机的第二块屏、Home、通知栏）：安卓把手柄的取消事件丢掉，回来也不补发松开，
## 按着的摇杆 / 扳机 / 十字键会一直「按着」——地图自己漂、目的地自己换（MC-1）。这时一律当松开；
## 回来时还按着的话，下一下摇杆抖动就会重新报上来。桌面上这一层关着，什么都不做
func _notification(what: int) -> void:
	if not enabled:
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		if _held_dir != "" or _stick_dir != "" or not _axes.is_empty():
			print("PAD_RELEASE_ON_FOCUS_OUT ", JSON.stringify({"what": what, "held": _held_dir, "stick": _stick_dir, "axes": _axes.size()}))
		_release_dirs()


## 正在分发的这一下是系统取消的触摸松开（只在触屏防误触开着时会是 true）
func release_canceled() -> bool:
	return _release_canceled


## 正在分发的这一下是手指（触屏）
func touch_dispatch() -> bool:
	return _touch_dispatch


## 触屏防误触开没开（各页用：没有 PadInput 时当关着）
static func guards_on(from: Node) -> bool:
	var hub := _hub_of(from)
	return hub != null and bool(hub.get("touch_guards"))


## 这一下（按钮的 pressed 里问）是系统取消的触摸松开：确认类的按钮不当它是点
static func canceled_press(from: Node) -> bool:
	var hub := _hub_of(from)
	return hub != null and bool(hub.call("release_canceled"))


## 这一下（按钮的 pressed 里问）是手指按的
static func touch_press(from: Node) -> bool:
	var hub := _hub_of(from)
	return hub != null and bool(hub.call("touch_dispatch"))


static func _hub_of(from: Node) -> Node:
	if from == null or not from.is_inside_tree():
		return null
	return from.get_node_or_null("/root/PadInput")


func set_pad_mode(on: bool) -> void:
	_mouse_travel = 0.0
	if on == pad_mode:
		return
	pad_mode = on
	if not on:
		_release_dirs()
	print("PAD_MODE ", JSON.stringify({"on": on, "device": last_device}))
	pad_mode_changed.emit(on)


## 扳机按下的深度 0..1（静止值 0 或 −1 都换算成 0）
func trigger(axis: int) -> float:
	var v := float(_axes.get(axis, _trigger_rest.get(axis, 0.0)))
	var rest := float(_trigger_rest.get(axis, 0.0))
	return clampf((v - rest) / maxf(0.001, 1.0 - rest), 0.0, 1.0)


## 右摇杆（死区外重新拉到 0..1）
func right_stick() -> Vector2:
	var v := Vector2(float(_axes.get(JOY_AXIS_RIGHT_X, 0.0)), float(_axes.get(JOY_AXIS_RIGHT_Y, 0.0)))
	var l := v.length()
	if l < PAN_DEADZONE:
		return Vector2.ZERO
	return v / l * clampf((l - PAN_DEADZONE) / (1.0 - PAN_DEADZONE), 0.0, 1.0)


## 缩放量：右扳机放大为正，左扳机缩小为负
func zoom_axis() -> float:
	var z := 0.0
	var rt := trigger(JOY_AXIS_TRIGGER_RIGHT)
	var lt := trigger(JOY_AXIS_TRIGGER_LEFT)
	if rt > TRIGGER_DEADZONE:
		z += (rt - TRIGGER_DEADZONE) / (1.0 - TRIGGER_DEADZONE)
	if lt > TRIGGER_DEADZONE:
		z -= (lt - TRIGGER_DEADZONE) / (1.0 - TRIGGER_DEADZONE)
	return z


# ------------------------------------------------------------------ 每帧
func _process(delta: float) -> void:
	_release_canceled = false          # 只算分发那一下；之后代码里（计时器、手柄）按的按钮不受它影响
	_touch_dispatch = false
	if not enabled:
		if _ring.visible:
			_ring.step(Rect2(), 0, [], 1.0)
		return
	var real_dt := delta / maxf(Engine.time_scale, 0.0001)
	var dir := _held_dir if _held_dir != "" else _stick_dir
	if dir == "" or dir != _repeat_dir:
		_repeat_dir = dir
		_repeat_at = Time.get_ticks_msec() + REPEAT_DELAY_MS
	elif Time.get_ticks_msec() >= _repeat_at:
		_repeat_at = Time.get_ticks_msec() + REPEAT_EVERY_MS
		repeating = true
		_dispatch(dir.trim_prefix("pad_"))
		repeating = false
	var ctx := active_context()
	if ctx != null and ctx.has_method("pad_axes"):
		var pan := right_stick()
		var zoom := zoom_axis()
		if pan != Vector2.ZERO or absf(zoom) > 0.0:
			set_pad_mode(true)
			ctx.call("pad_axes", pan, zoom, minf(real_dt, 0.1))
	_update_ring(ctx, real_dt)


func _update_ring(ctx: Node, dt: float) -> void:
	var target := Rect2()
	var key := 0
	var glyphs: Array = []
	if pad_mode and ctx != null:
		var f: Variant = ctx.call("pad_focus") if ctx.has_method("pad_focus") else null
		if f is Control:
			target = rect_of(f as Control) if (f as Control).is_visible_in_tree() else Rect2()
			key = (f as Control).get_instance_id()
		elif f is Rect2:
			target = f
			key = -1
		if ctx.has_method("pad_glyphs"):
			for g: Variant in ctx.call("pad_glyphs"):
				var arr := g as Array
				if arr.size() >= 2 and arr[0] is Control and is_instance_valid(arr[0]) and (arr[0] as Control).is_visible_in_tree():
					glyphs.append([rect_of(arr[0] as Control), String(arr[1]), String(arr[2]) if arr.size() >= 3 else "corner"])
	_ring.step(target, key, glyphs, dt)


## 控件在画布上的外接矩形（含父节点的缩放 / 所在 CanvasLayer 的变换）
static func rect_of(c: Control) -> Rect2:
	var xf := c.get_global_transform_with_canvas()
	var r := Rect2(xf * Vector2.ZERO, Vector2.ZERO)
	for p: Vector2 in [Vector2(c.size.x, 0), Vector2(0, c.size.y), c.size]:
		r = r.expand(xf * p)
	return r


# ------------------------------------------------------------------ 工具（各页共用）
## 像点了一下那样按一个按钮（不可按 / 看不见时返回 false）。先发 button_down / button_up，糖果按钮会照常压一下
static func press(b: BaseButton) -> bool:
	if b == null or not is_instance_valid(b) or b.disabled or not b.is_visible_in_tree():
		return false
	b.button_down.emit()
	if b.toggle_mode:
		b.set_pressed_no_signal(not b.button_pressed)
		b.toggled.emit(b.button_pressed)
	b.button_up.emit()
	b.pressed.emit()
	return true


## 方向导航：从 from 往 dir 走，挑 rects 里最近的那个（主方向距离 + 2.5 倍横向偏离；横向有重叠的不算偏离）。没有返回 -1
static func pick_dir(from: Rect2, rects: Array, dir: Vector2) -> int:
	var c0 := from.get_center()
	var best := -1
	var best_score := INF
	var side := Vector2(-dir.y, dir.x)
	for i in rects.size():
		var r: Rect2 = rects[i]
		var d := r.get_center() - c0
		var along := d.dot(dir)
		if along <= 2.0:
			continue
		var perp := absf(d.dot(side))
		# 横向有重叠（同一行 / 同一列）：不算偏离
		var overlap: bool
		if dir.x != 0.0:
			overlap = r.position.y < from.end.y and r.end.y > from.position.y
		else:
			overlap = r.position.x < from.end.x and r.end.x > from.position.x
		var score := along + (0.0 if overlap else perp * 2.5)
		if score < best_score:
			best_score = score
			best = i
	return best


## 在一串控件里按方向走：cur 是当前下标（-1 = 还没有焦点：返回 first）
static func nav_controls(controls: Array, cur: int, dir: Vector2, first: int = 0) -> int:
	if controls.is_empty():
		return -1
	if cur < 0 or cur >= controls.size():
		return clampi(first, 0, controls.size() - 1)
	var rects: Array = []
	for c: Control in controls:
		rects.append(rect_of(c))
	var i := pick_dir(rects[cur], rects, dir)
	return cur if i < 0 else i


# ------------------------------------------------------------------ 焦点框
## 焦点框：挎包棕的细边 + 暖金色的框，轻轻呼吸；字母小圆标：墨色圆底、奶油色正文圆体字母
class PadRing extends Control:
	const GOLD := Color("#FFC94D")
	const EDGE := Color("#3A2A22")
	const CREAM := Color("#FBF3E4")
	var font: Font
	var _target := Rect2()
	var _shown := Rect2()
	var _alpha := 0.0
	var _t := 0.0
	var _glyphs: Array = []
	var _key := 0
	var _sliding := false
	var _outer := StyleBoxFlat.new()
	var _inner := StyleBoxFlat.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		for sb: StyleBoxFlat in [_outer, _inner]:
			sb.draw_center = false
			sb.anti_aliasing = true
			sb.corner_detail = 10
		_outer.set_border_width_all(8)
		_inner.set_border_width_all(4)

	## 焦点框的当前矩形（测试用）；没有时是空矩形
	func shown_rect() -> Rect2:
		return _shown if _alpha > 0.5 else Rect2()

	func glyph_count() -> int:
		return _glyphs.size()

	func step(target: Rect2, key: int, glyphs: Array, dt: float) -> void:
		_t += dt
		var had := _target.has_area()
		var same := key == _key and key != 0
		_target = target
		_key = key
		if target.has_area():
			# 刚出现、或还是同一个东西（跟着镜头 / 滚动走）直接到位；换到别的东西时 0.1 秒滑过去
			if not had or _alpha < 0.05 or (same and not _sliding):
				_shown = target
			else:
				_sliding = true
				var k := minf(1.0, dt * 18.0)
				_shown = Rect2(_shown.position.lerp(target.position, k), _shown.size.lerp(target.size, k))
			if _shown.position.distance_to(target.position) < 0.5 and _shown.size.distance_to(target.size) < 0.5:
				_shown = target
				_sliding = false
		_alpha = move_toward(_alpha, 1.0 if target.has_area() else 0.0, dt * (10.0 if target.has_area() else 6.0))
		if target.has_area() and _alpha < 0.5:
			_alpha = 0.5
		_glyphs = glyphs
		visible = _alpha > 0.01 or not glyphs.is_empty()
		queue_redraw()

	func _draw() -> void:
		if _alpha > 0.01 and _shown.has_area():
			var pulse := 0.5 + 0.5 * sin(_t * TAU / 1.4)
			var r := _shown.grow(6.0 + 2.5 * pulse)
			var rad := int(clampf(minf(r.size.x, r.size.y) * 0.22, 10.0, 30.0))
			_outer.set_corner_radius_all(rad + 2)
			_outer.border_color = Color(EDGE, 0.55 * _alpha)
			draw_style_box(_outer, r.grow(2.0))
			_inner.set_corner_radius_all(rad)
			_inner.border_color = Color(GOLD, (0.82 + 0.18 * pulse) * _alpha)
			draw_style_box(_inner, r)
		for g: Array in _glyphs:
			var gr: Rect2 = g[0]
			var letter: String = g[1]
			var rad2 := 17.0
			# "corner"（默认）：压在按钮左上角；"side"：小药丸（返回、跳过）放在左边外面（左边没地方就放右边），不盖住字
			var c := gr.position + Vector2(rad2 * 0.35, rad2 * 0.35)
			if g.size() >= 3 and String(g[2]) == "side":
				c = Vector2(gr.position.x - rad2 - 14.0, gr.get_center().y)
				if c.x - rad2 < 2.0:
					c = Vector2(gr.end.x + rad2 + 14.0, gr.get_center().y)
			draw_circle(c, rad2 + 2.5, Color(CREAM, 0.95))
			draw_circle(c, rad2, EDGE)
			if font != null:
				var px := 22
				var sz := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, px)
				draw_string(font, c + Vector2(-sz.x * 0.5, font.get_ascent(px) * 0.5 - 2.0), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, px, CREAM)
