extends Camera2D

# ───── РУЧНЫЕ ПРЕДЕЛЫ (в пикселях) ──────────────────────────────────────────────
# Для ноутбука Full-HD (1920×1080) я заложил примерную «карту» 3000×2000.
# Меняйте цифры, как вам нужно.
const LIMIT_LEFT   := 0
const LIMIT_RIGHT  := 1000
const LIMIT_TOP    := 0
const LIMIT_BOTTOM := 500
# ────────────────────────────────────────────────────────────────────────────────

var dragging: bool = false
var last_mouse_pos: Vector2 = Vector2.ZERO


func _unhandled_input(event: InputEvent) -> void:
	# ЛКМ нажата / отпущена ─ переключаем режим drag
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
		if dragging:
			last_mouse_pos = event.position

	# Двигаем камеру, пока тянем
	elif event is InputEventMouseMotion and dragging:
		var delta: Vector2 = last_mouse_pos - event.position   # «лист бумаги» эффект
		position -= delta                                      # (или +=, если нужно наоборот)

		# ─── зажимаем в пределах ────────────────────────────
		position.x = clamp(position.x, LIMIT_LEFT,  LIMIT_RIGHT)
		position.y = clamp(position.y, LIMIT_TOP,   LIMIT_BOTTOM)
		# ────────────────────────────────────────────────────

		last_mouse_pos = event.position
		get_viewport().set_input_as_handled()  # клик не идёт в другие объекты
