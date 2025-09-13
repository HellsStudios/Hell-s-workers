extends CanvasLayer
#class_name Fader

@onready var rect := ColorRect.new()

func _ready() -> void:
	layer = 200
	process_mode = Node.PROCESS_MODE_ALWAYS
	rect.color = Color(0, 0, 0, 0.0)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(rect)

func _fade_to(alpha: float, dur := 0.25) -> void:
	var tw = create_tween()
	tw.tween_property(rect, "color:a", clamp(alpha, 0.0, 1.0), dur)
	await tw.finished

func fade_out(dur := 0.25) -> void: await _fade_to(1.0, dur)
func fade_in(dur := 0.25)  -> void: await _fade_to(0.0, dur)
