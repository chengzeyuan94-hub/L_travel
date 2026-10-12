extends SceneTree
## 巴格达旅人 · 循环实机窗口：「下雨 → 开花、树叶发光 → 黄昏晚霞 → 下雨」。
##
## 两个世界并排跑、同一个时钟：
##   A 雨世界 = Codex 的雨景装配（storm look + 捧物 + 开花 + 雨 + 光束 / 叶面发光 / 城灯 / 火与树风），
##             加上晚霞世界已认可的中景沙脊与碎石（按雨世界的湿地约定改造，见 cycle_midground.gd）和地面草风。
##   B 晚霞世界 = 晚霞探针 m_grass（光、云、金边、沙地、风沙、树风、落叶、草），换上 Codex 的捧物动作与土豆开花。
## 两边的人物动作、土豆与花由同一个时钟驱动，所以过渡时人物不会重影。
## 合成层（cycle_mix.gdshader）按时间线把两张图过渡：晚霞从太阳处向外铺开，雨从左上方压回来。
## 过渡以外只渲染正在显示的那个世界（另一个 SubViewport 暂停），过渡前 1 秒预热。
##
## 时间线（cycle_config.json 可改）：0–8 s 为 Codex 原节奏（0–4 开花、3–6 光束下探、6.2–8 叶面发光、4–8 城灯），
## 8–12 s 过渡到晚霞（手中保持盛开的花），晚霞停留，4 s 过渡回雨（花收回），下雨停留，再开始下一轮。
##
## 交互（Carlos 2026-09-23：「交互为：点击「土豆」进行自动切换」）：默认是点击模式，三个状态轮流切换，
##   下雨（等待）→ 点土豆 → 开花、树叶发光（Codex 8 秒节奏）→ 点土豆 → 云层滚走露出晚霞（8 秒）→ 点土豆 → 雨压回来、花收回（4 秒）→ 下雨。
##   鼠标移到土豆上变成小手；切换过程中点击不响应。空格等同点土豆。--cycle-auto 回到自动循环。
## 按键：R 回到下雨  P 暂停/继续  1/2/3 直接跳到 下雨/开花发光/晚霞  H 标题栏提示显示/隐藏。
## 抽查静帧（给导演验证用）：--cycle-stills=<绝对目录> --cycle-times=0,4.8,8,10,12,20,24,26 会逐个时间点截合成图后退出。
##
## 2026-09-27：逻辑搬到节点 tools/traveler/baghdad/cycle/baghdad_cycle.gd + 场景 scenes/traveler/baghdad_cycle.tscn
## （正式包的导出模板不认 --script，旅人模式第三幕要能当场景打开）。这个 SceneTree 脚本只把那个场景挂到 root 上，
## 所以 `--script res://tools/traveler/baghdad/cycle/review_cycle.gd -- ...` 的所有用法（点击 / 自动循环 / 抽查静帧 /
## 录像 / 测帧 / 自测）和以前一样。

const SCENE := "res://scenes/traveler/baghdad_cycle.tscn"


func _initialize() -> void:
	root.add_child.call_deferred(load(SCENE).instantiate())
