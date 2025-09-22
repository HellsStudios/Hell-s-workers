extends Node2D

signal picked
signal vanished

@onready var area: Area2D = $Area2D
@onready var anim: AnimationPlayer = $Area2D/AnimationPlayer

var _alive := true

func _ready() -> void:
	if anim:
		# слушаем завершение любой анимации
		if not anim.animation_finished.is_connected(_on_anim_finished):
			anim.animation_finished.connect(_on_anim_finished)

		if anim.has_animation("spawn"):
			anim.play("spawn")
		elif anim.has_animation("idle"):
			anim.play("idle")  # если spawn нет — сразу idle

	if area and not area.input_event.is_connected(_on_area_input):
		area.input_event.connect(_on_area_input)

func _on_anim_finished(name: StringName) -> void:
	# когда закончился спавн — переключаемся на idle
	if _alive and String(name) == "spawn" and anim and anim.has_animation("idle"):
		anim.play("idle")

func _on_area_input(_vp, event: InputEvent, _shape_idx: int) -> void:
	if _alive and event is InputEventMouseButton \
		and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_pick()

func _pick() -> void:
	if not _alive: return
	_alive = false
	picked.emit()

	if anim and anim.has_animation("pick"):
		anim.play("pick")
		await anim.animation_finished
	_vanish()

func _vanish() -> void:
	vanished.emit()
	queue_free()
