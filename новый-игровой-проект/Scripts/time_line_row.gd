extends Panel

const TOTAL_SLOTS := 48
const SLOT_WIDTH  := 25.0
@export var hero_name: String = ""   # <- ВАЖНО: контроллер пишет сюда имя героя
@export var task_card_scene: PackedScene = preload("res://Scenes/taskcard.tscn")
@export var pool_container_path: NodePath
@onready var pool_container: Control = get_node_or_null(pool_container_path) as Control
const TASK_CARD_FALLBACK := preload("res://Scenes/taskcard.tscn") # ← поставь свой ПРАВИЛЬНЫЙ путь


func _get_or_make_card(inst_id: int, def_id: String, overrides: Dictionary = {}) -> Control:
	var node_name := "Card_%d" % inst_id
	var card: Control = get_node_or_null(node_name) as Control
	if card == null:
		if task_card_scene == null:
			push_error("[Row] task_card_scene is null")
			return null
		card = task_card_scene.instantiate() as Control
		card.name = node_name
		add_child(card)

	# применяем оверрайды, если нужны
	for k in overrides.keys():
		card.set(String(k), overrides[k])

	return card



func _move_card_to_pool(card: Control) -> void:
	if card == null:
		return
	if card.get_parent():
		card.get_parent().remove_child(card)
	if pool_container:
		pool_container.add_child(card)
	else:
		# страховка: если пула нет – не ломаемся
		add_child(card); remove_child(card) # «отвязать» от строки
	# сброс внешнего вида
	card.set_anchors_preset(Control.PRESET_TOP_LEFT)
	card.anchor_right = 0
	card.anchor_bottom = 0
	card.size_flags_horizontal = 0
	card.size_flags_vertical = 0
	card.position = Vector2.ZERO
	card.visible = true
	# подчистить «следы расписания», если карточка их хранит
	if card.has_method("set"):
		card.set("schedule_start_slot", -1)
		card.set("duration_slots", 0)


func _ready():
	if pool_container_path != NodePath("") and has_node(pool_container_path):
		pool_container = get_node(pool_container_path)
	GameManager.schedule_changed.connect(_rebuild_from_schedule)
	_rebuild_from_schedule()

func _rebuild_from_schedule() -> void:
	var list: Array = GameManager.scheduled.get(hero_name, [])
	var keep := {}

	for s in list:
		var inst_id := int(s.get("inst_id", 0))
		var def_id  := String(s.get("def_id", ""))
		var card: Control = _get_or_make_card(inst_id, def_id, s)
		if card == null:
			push_error("[Row] Can't create card for inst %d (def '%s')" % [inst_id, def_id])
			continue

		var st  := int(s.get("start", 0))
		var dur := int(s.get("duration", 1))

		# безопасно «задать» свойства
		if card.has_method("set"):
			card.set("inst_id", inst_id)
			card.set("def_id",  def_id)
			card.set("schedule_start_slot", st)
			card.set("duration_slots",      dur)

		var y := (size.y - card.size.y) * 0.5
		card.position = Vector2(st * SLOT_WIDTH, y)
		card.visible  = true

		keep[card.name] = true

	# подчистить лишние карточки
	for c in get_children():
		if c is Control and c.name.begins_with("Card_") and not keep.has(c.name):
			if pool_container:
				_move_card_to_pool(c)
				c.position = Vector2.ZERO
			else:
				c.queue_free()



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

	# НОВОЕ: нельзя начинать раньше указателя
	var now := int(GameManager.timeline_clock.get("slot", 0))
	if slot < now:
		return false

	if slot + dur > TOTAL_SLOTS:
		return false

	# ...твои проверки пересечений как были...
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

	
# Вспомогательное: снять инстанс задачи из расписания где бы он ни лежал
func _unschedule_anywhere(inst_id: int) -> bool:
	if inst_id <= 0:
		return false
	var removed := false
	for h in GameManager.party_names:
		var arr: Array = GameManager.scheduled.get(h, [])
		for s in arr:
			if typeof(s) == TYPE_DICTIONARY and int(s.get("inst_id", 0)) == inst_id:
				GameManager.unschedule_task(h, inst_id)
				removed = true
				break
	return removed

func _row_hero() -> String:
	var h := hero_name
	if h == "":
		var v = get("hero_name")
		if typeof(v) == TYPE_STRING:
			h = String(v)
	return h



func _drop_data(pos: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY or not data.has("node"):
		return

	var card: Control = data["node"]
	var dur  := int(data.get("duration", 1))
	var inst_id := int(data.get("inst_id", 0))
	var hero := ""
	if has_method("get"):
		var v = get("hero_name")
		if typeof(v) == TYPE_STRING:
			hero = String(v)

	var slot := _slot_from_x(pos.x)
	if slot < 0:
		slot = 0
	if slot + dur > TOTAL_SLOTS:
		slot = TOTAL_SLOTS - dur

	# НОВОЕ: задним числом нельзя
	var now := int(GameManager.timeline_clock.get("slot", 0))
	if slot < now:
		Toasts.warn("Нельзя планировать задним числом.")
		return

	if not _can_drop_data(pos, data):
		return

	# дальше — как у тебя было: сняли старое, поставили новое
	var scheduled := true
	if inst_id > 0:
		_unschedule_anywhere(inst_id)
		scheduled = GameManager.schedule_task(hero, inst_id, slot)

	if not scheduled:
		if is_instance_valid(card):
			var prev_slot := -1
			if card.has_method("get"):
				prev_slot = int(card.get("schedule_start_slot"))
			if prev_slot >= 0:
				var y := (size.y - card.size.y) * 0.5
				card.position = Vector2(float(prev_slot) * SLOT_WIDTH, y)
		return

	if is_instance_valid(card):
		card.queue_free()
