extends Camera2D

const LIMIT_LEFT   := 0
const LIMIT_RIGHT  := 1000
const LIMIT_TOP    := 0
const LIMIT_BOTTOM := 500

var dragging: bool = false
var last_mouse_pos: Vector2 = Vector2.ZERO

# ВАЖНО: флаг, позволяющий временно отключать drag
var drag_enabled: bool = true

func set_drag_enabled(v: bool) -> void:
	drag_enabled = v
	if not v:
		dragging = false  # сразу гасим текущий drag

func cancel_drag() -> void:
	dragging = false

func _unhandled_input(event: InputEvent) -> void:
	if not drag_enabled:
		return

	# ЛКМ: нажали/отпустили — включаем/выключаем drag
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			dragging = true
			last_mouse_pos = event.position
		else:
			dragging = false

	# Двигаем камеру, пока тянем
	elif event is InputEventMouseMotion and dragging:
		var delta: Vector2 = last_mouse_pos - event.position
		position -= delta
		position.x = clamp(position.x, LIMIT_LEFT,  LIMIT_RIGHT)
		position.y = clamp(position.y, LIMIT_TOP,   LIMIT_BOTTOM)
		last_mouse_pos = event.position
		get_viewport().set_input_as_handled()
