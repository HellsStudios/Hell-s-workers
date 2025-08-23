extends VBoxContainer

func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return typeof(data) == TYPE_DICTIONARY and String(data.get("source","")) == "timeline"

func _drop_data(_pos: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY or not data.has("node"):
		return
	var card: Control = data["node"]
	var inst_id := 0
	if card and card.has_method("get"):
		var v = card.get("inst_id")
		if typeof(v) == TYPE_INT:
			inst_id = int(v)
	var from_hero := String(data.get("hero",""))

	# отвязать от расписания, если надо
	if inst_id > 0 and from_hero != "":
		GameManager.unschedule_task(from_hero, inst_id)

	# перенести в пул
	if card.get_parent():
		card.get_parent().remove_child(card)
	add_child(card)

	card.set("schedule_start_slot", -1)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.visible = true
