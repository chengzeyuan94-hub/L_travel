class_name DiceSystem

## 原版骰子：数值面 1–5 与事件面。测试可注入指定结果。

const FACE_EVENT := "EVENT"
const FACE_COUNT := 6


static func roll() -> Variant:
	var i := GameState.rng_int(FACE_COUNT)
	return FACE_EVENT if i == FACE_COUNT - 1 else i + 1


static func is_event_face(face: Variant) -> bool:
	return face is String and String(face) == FACE_EVENT


static func is_valid_face(face: Variant) -> bool:
	if is_event_face(face):
		return true
	return face is int and int(face) >= 1 and int(face) <= 5


static func face_text(face: Variant) -> String:
	return "事件" if is_event_face(face) else str(face)
