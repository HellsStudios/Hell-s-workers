extends VBoxContainer

var _cards_by_inst: Dictionary = {}   # inst_id -> Control

func _ensure_card_for_inst(inst: Dictionary) -> Control:
	var id := int(inst.get("inst_id", 0))
	if id <= 0:
		return null
	if _cards_by_inst.has(id):
		return _cards_by_inst[id]

	var card := preload("res://Scenes/task_card.tscn").instantiate()
	card.set("inst_id", id)
	card.set("def_id", String(inst.get("def_id","")))
	# цвет и заголовок из инстанса, если заданы
	if inst.has("color"):
		card.modulate = Color(String(inst["color"]))
	if inst.has("title") and card.has_method("set"):
		card.set("title", String(inst["title"]))

	_cards_by_inst[id] = card
	return card


func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return typeof(data) == TYPE_DICTIONARY and int(data.get("inst_id", 0)) > 0

func _drop_data(_pos: Vector2, data: Variant) -> void:
	var inst_id := int(data.get("inst_id", 0))
	var card: Control = data.get("node", null)

	# 1) СНАЧАЛА — снять из расписания в GM
	if inst_id > 0:
		GameManager.unschedule_any(inst_id)  # <- ключевая строка

	# 2) Переложить ноду в пул и сбросить внешний вид
	if is_instance_valid(card):
		if card.get_parent():
			card.get_parent().remove_child(card)
		add_child(card)

		card.set_anchors_preset(Control.PRESET_TOP_LEFT)
		card.anchor_right = 0
		card.anchor_bottom = 0
		card.size_flags_horizontal = 0
		card.size_flags_vertical = 0
		card.position = Vector2.ZERO
		card.visible = true

		if card.has_method("set"):
			card.set("schedule_start_slot", -1)
			card.set("duration_slots", 0)
