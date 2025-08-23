extends ColorRect

@export var duration_slots: int = 4
@export var task_name: String = ""
var schedule_start_slot: int = -1
var inst_id: int = 0
@onready var lbl: Label = $Label

func _ready() -> void:
	if lbl:
		lbl.clip_text = true
		lbl.text_overrun_behavior = 3
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.text = (task_name if task_name != "" else "[Задача]")

func _get_drag_data(_pos: Vector2) -> Variant:
	# выясним, откуда тащим
	var src := "timeline"
	if get_parent() is Container:
		src = "pool"

	# кто герой-владелец (если карточка лежит в строке)
	var hero := ""
	var p := get_parent()
	if p and p.has_method("get"):
		var v = p.get("hero_name")
		if typeof(v) == TYPE_STRING:
			hero = String(v)

	var data := {
		"duration": int(duration_slots),
		"task_name": task_name,
		"inst_id": int(inst_id),
		"source": src,
		"hero": hero,
		"node": self,
	}

	var preview := duplicate() as Control
	preview.modulate.a = 0.7
	set_drag_preview(preview)
	visible = false
	preview.connect("tree_exiting", Callable(self, "_on_preview_exit"))
	return data

func _on_preview_exit() -> void:
	if not visible:
		visible = true
