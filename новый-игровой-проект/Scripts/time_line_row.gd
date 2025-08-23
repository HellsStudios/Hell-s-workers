extends Panel

const TOTAL_SLOTS := 48
const SLOT_WIDTH  := 25.0

static func _has_prop(o: Object, prop: String) -> bool:
	if o == null: return false
	for p in o.get_property_list():
		if String(p.get("name","")) == prop:
			return true
	return false

func _slot_from_x(x: float) -> int:
	var s := int(floor(x / SLOT_WIDTH))
	if s < 0: s = 0
	return s

func _can_drop_data(pos: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not data.has("duration"):
		return false

	var dur := int(data["duration"])
	var slot := _slot_from_x(pos.x)
	if slot + dur > TOTAL_SLOTS:
		return false

	# проверка пересечений с уже лежащими карточками
	for c in get_children():
		if c == data.get("node", null):
			continue
		if not (c is ColorRect):
			continue

		var st := -1
		var d2 := 0
		if _has_prop(c, "schedule_start_slot"):
			st = int(c.get("schedule_start_slot"))
		if _has_prop(c, "duration_slots"):
			d2 = int(c.get("duration_slots"))

		if st >= 0 and d2 > 0:
			var en := st + d2
			var new_en := slot + dur
			if slot < en and new_en > st:
				return false
	return true

func _drop_data(pos: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	if not data.has("node"):
		return

	var card: Control = data["node"]
	var dur  := int(data.get("duration", 1))
	var inst_id := int(data.get("inst_id", 0))
	var from_hero := String(data.get("hero",""))

	# герой-владелец строки — мы записали его контроллером в свойство "hero_name"
	var hero := ""
	if has_method("get"):
		var v = get("hero_name")
		if typeof(v) == TYPE_STRING:
			hero = String(v)

	var slot := _slot_from_x(pos.x)
	if not _can_drop_data(pos, data):
		return

	# если перетащили с другой строки — отписать старое расписание
	if inst_id > 0 and from_hero != "":
		GameManager.unschedule_task(from_hero, inst_id)

	# переместить ноду в текущую строку
	if card.get_parent():
		card.get_parent().remove_child(card)
	add_child(card)

	# позиция/размер
	var y := (size.y - card.size.y) * 0.5
	card.position = Vector2(float(slot) * SLOT_WIDTH, y)
	card.set("schedule_start_slot", slot)
	card.set("duration_slots", dur)
	card.size_flags_horizontal = Control.SIZE_FILL
	card.visible = true

	# зарегистрировать расписание в GM
	if inst_id > 0 and hero != "":
		GameManager.schedule_task(hero, inst_id, slot)
