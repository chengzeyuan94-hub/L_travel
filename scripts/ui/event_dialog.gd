extends Control

## 阻断式事件弹窗：默认隐藏；显示时遮罩拦截全部鼠标输入；
## 点击“继续”只关闭弹窗，不修改任何对局状态。


func _ready() -> void:
	visible = false
	%ContinueButton.pressed.connect(_on_continue_pressed)


func show_event(title: String, description: String, effect_message: String) -> void:
	%EventTitleLabel.text = title
	%EventDescriptionLabel.text = description
	%EventEffectLabel.text = effect_message
	visible = true
	modulate.a = 0.0
	var panel: Control = $CenterContainer/Panel
	panel.pivot_offset = panel.size * 0.5
	panel.scale = Vector2(0.88, 0.88)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(panel, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_continue_pressed() -> void:
	%ContinueButton.disabled = true
	var panel: Control = $CenterContainer/Panel
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "modulate:a", 0.0, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_property(panel, "scale", Vector2(0.94, 0.94), 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await tween.finished
	visible = false
	modulate.a = 1.0
	panel.scale = Vector2.ONE
	%ContinueButton.disabled = false
