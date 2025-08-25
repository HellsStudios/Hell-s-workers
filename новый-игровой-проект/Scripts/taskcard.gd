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
	# кто наш герой (если карточка уже лежит на строке)
	var hero := ""
	var p := get_parent()
	if p and p.get_parent() and p.get_parent().has_method("get"):
		var v = p.get_parent().get("hero_name")
		if typeof(v) == TYPE_STRING:
			hero = String(v)

	# достаём inst_id, который контроллер прописал через set("inst_id", ...)
	var iid := 0
	if has_method("get"):
		var val = get("inst_id")
		if typeof(val) == TYPE_INT:
			iid = int(val)

	# источник: пул/таймлайн
	var src := "timeline"
	if get_parent() is Container:
		src = "pool"

	var data := {
		"duration": int(duration_slots),
		"task_name": task_name,
		"inst_id": iid,
		"source": src,
		"hero": hero,
		"node": self
	}

	# превью
	var preview := duplicate() as Control
	preview.modulate.a = 0.7
	set_drag_preview(preview)

	# прячем оригинал до окончания d&d
	visible = false
	preview.connect("tree_exiting", Callable(self, "_on_preview_exit"))
	return data

func _on_preview_exit() -> void:
	# если таймлайн нас принял — time_line_row.gd поставит метку
	var accepted := false
	if has_meta("accepted"):
		accepted = bool(get_meta("accepted"))
	if not visible and not accepted:
		visible = true
