extends Node

const SLOT_WIDTH: float = 25.0

@onready var task_list: VBoxContainer = $UI/MainLayout/TaskPoolPanel/TaskList
@onready var card_template: ColorRect = $UI/MainLayout/TaskPoolPanel/TaskList/TaskCardTemplate
@onready var rows_root: VBoxContainer      = $UI/MainLayout/Control/HBoxContainer/TimeLineArea
@onready var time_area: Control = $UI/MainLayout/Control/HBoxContainer/TimeLineArea
@onready var pointer: ColorRect = $UI/MainLayout/Control/TimePointer
@onready var play_btn: Button = $UI/HBoxContainer/PlayButton
@onready var pause_btn: Button = $UI/HBoxContainer/PauseButton
@onready var speed_spin: SpinBox = $UI/HBoxContainer/SpeedSpin
@onready var popup: AcceptDialog = $UI/EventPopup
@onready var popup_text: RichTextLabel = $UI/EventPopup/EventText
@onready var labels_root: VBoxContainer      = $UI/MainLayout/Control/HBoxContainer/VBoxContainer
var rows: Array[Node] = []

var running: bool = false
var current_slot: int = 0           # 0..47
var slot_time_accum: float = 0.0
var sec_per_slot: float = 0.7       # сколько секунд занимает 1 слот

const TOTAL_SLOTS := 48

# ===== POINTER: helpers =====
func _pointer_base_x() -> float:
	if not pointer or not time_area:
		return 0.0
	# pointer и time_area в одном контейнере, переведём координаты
	var parent_global = pointer.get_parent().global_position
	return time_area.global_position.x - parent_global.x

func _set_pointer_x() -> void:
	if not pointer or not time_area:
		return
	var base_x := _pointer_base_x()
	var progress := 0.0
	if sec_per_slot > 0.0:
		progress = clamp(slot_time_accum / sec_per_slot, 0.0, 1.0)
	var slot_f := float(min(current_slot, TOTAL_SLOTS))
	pointer.position.x = base_x + (slot_f + progress) * SLOT_WIDTH

func _sync_pointer_rect() -> void:
	if not pointer or not time_area:
		return
	pointer.position.y = time_area.position.y
	pointer.size.y     = time_area.size.y
	_set_pointer_x()

func _start() -> void:
	running = true

func _pause() -> void:
	running = false

func _reset_day() -> void:
	running = false
	current_slot = 0
	slot_time_accum = 0.0
	_set_pointer_x()

func _on_speed_changed(v: float) -> void:
	# ожидаем "секунд за слот"
	sec_per_slot = max(0.03, float(v))

func _ready() -> void:
	_build_rows_from_scene()
	_attach_rows_to_heroes()
	_refresh_task_pool()
	_redraw_schedule()

	# реакция на изменения пула/расписания от GM
	if GameManager.has_signal("task_pool_changed"):
		if not GameManager.task_pool_changed.is_connected(_on_pool_changed):
			GameManager.task_pool_changed.connect(_on_pool_changed)
	if GameManager.has_signal("schedule_changed"):
		if not GameManager.schedule_changed.is_connected(_redraw_schedule):
			GameManager.schedule_changed.connect(_redraw_schedule)
	
		# --- POINTER init ---
	_sync_pointer_rect()
	_reset_day()

	if play_btn and not play_btn.pressed.is_connected(_start):
		play_btn.pressed.connect(_start)
	if pause_btn and not pause_btn.pressed.is_connected(_pause):
		pause_btn.pressed.connect(_pause)
	if speed_spin and not speed_spin.value_changed.is_connected(_on_speed_changed):
		speed_spin.value_changed.connect(_on_speed_changed)

	if time_area and not time_area.resized.is_connected(_sync_pointer_rect):
		time_area.resized.connect(_sync_pointer_rect)

	set_process(true)
	
	if GameManager.has_signal("task_started") and not GameManager.task_started.is_connected(_on_task_started):
		GameManager.task_started.connect(_on_task_started)
	if GameManager.has_signal("task_event") and not GameManager.task_event.is_connected(_on_task_event):
		GameManager.task_event.connect(_on_task_event)
	if GameManager.has_signal("task_completed") and not GameManager.task_completed.is_connected(_on_task_completed):
		GameManager.task_completed.connect(_on_task_completed)

	# Закрытие попапа продолжает время
	if popup and not popup.confirmed.is_connected(func(): running = true):
		popup.confirmed.connect(func(): running = true)
		

func _on_task_started(hero: String, inst_id: int) -> void:
	print("[TL] START  hero=", hero, " inst=", inst_id)

func _on_task_event(hero: String, inst_id: int, ev: Dictionary) -> void:
	# Пока просто стопаем время и показываем текст события
	running = false
	if popup_text:
		popup_text.bbcode_enabled = true
		var t := String(ev.get("text", "Событие"))
		popup_text.text = "[b]%s[/b]\n\n(пока заглушка выбора)" % t
	if popup:
		popup.popup_centered()

func _on_task_completed(hero: String, inst_id: int, outcome: Dictionary) -> void:
	var ok := bool(outcome.get("success", true))
	var msg := "Задание завершено: "
	if ok:
		msg += "успех"
	else:
		msg += "провал"
	print("[TL] ", msg, " hero=", hero, " inst=", inst_id)



func _process(delta: float) -> void:
	if not running:
		_set_pointer_x()
		return

	if sec_per_slot <= 0.0:
		sec_per_slot = 0.7

	slot_time_accum += delta

	if slot_time_accum >= sec_per_slot:
		var steps := int(floor(slot_time_accum / sec_per_slot))
		slot_time_accum -= float(steps) * sec_per_slot

		for _i in range(steps):
			if current_slot < TOTAL_SLOTS:
				current_slot += 1
				GameManager.tick_timeline(current_slot)

		# стоп у правого края
		if current_slot >= TOTAL_SLOTS:
			current_slot = TOTAL_SLOTS
			running = false
			slot_time_accum = 0.0

	_set_pointer_x()


func _on_pool_changed() -> void:
	_refresh_task_pool()

# найти TimeLineRow1..7
func _build_rows_from_scene() -> void:
	rows.clear()
	for i in range(1, 8):
		var n := rows_root.get_node_or_null("TimeLineRow%d" % i)
		if n:
			rows.append(n)

# подписать лейблы, лишние строки скрыть
func _attach_rows_to_heroes() -> void:
	var names: Array = GameManager.party_names.duplicate()

	for i in range(rows.size()):
		var row = rows[i]

		# имя лейбла: "Label" для первой строки, дальше "Label1", "Label2", ...
		var lbl_name := "Label"
		if i > 0:
			lbl_name = "Label%d" % i
		var lbl := labels_root.get_node_or_null(lbl_name)

		if i < names.size():
			row.visible = true
			if row.has_method("set"):
				row.set("hero_name", String(names[i]))
			if lbl and lbl is Label:
				(lbl as Label).text = String(names[i])
		else:
			row.visible = false
			if lbl and lbl is Label:
				(lbl as Label).text = ""


func _refresh_task_pool() -> void:
	# очистить всё, кроме шаблона
	for c in task_list.get_children():
		if c != card_template:
			c.queue_free()
	if card_template:
		card_template.visible = false

	# если задач нет — попробуем нагенерить из квеста/дня
	if GameManager.active_task_pool.is_empty():
		GameManager.spawn_quest_tasks("q_intro")
		GameManager.spawn_daily_tasks("default")

	for inst in GameManager.active_task_pool:
		if typeof(inst) != TYPE_DICTIONARY:
			continue
		var def_id := String(inst.get("def_id",""))
		var def: Dictionary = GameManager.task_defs.get(def_id, {})
		if def.is_empty():
			continue

		var node := card_template.duplicate() as ColorRect
		node.visible = true

		# свойства скрипта карточки
		node.set("duration_slots", int(def.get("duration_slots", 4)))
		node.set("task_name", String(def.get("title", def_id)))
		node.set("inst_id", int(inst.get("inst_id", 0)))
		node.set("schedule_start_slot", -1)

		# подпись на вложенном Label (если есть)
		var lbl: Label = node.get_node_or_null("Label")
		if lbl:
			lbl.text = "%s (%d×15м)" % [
				String(def.get("title", def_id)),
				int(def.get("duration_slots", 4))
			]

		task_list.add_child(node)


func _redraw_schedule() -> void:
	# полностью перерисовать карточки на строках по GM.scheduled
	for i in range(rows.size()):
		var row = rows[i]
		# чистим все карточки на строке
		var to_free: Array = []
		for c in row.get_children():
			if c is ColorRect:
				to_free.append(c)
		for c in to_free:
			c.queue_free()

		# имя героя строки
		var hero := ""
		if row.has_method("get"):
			var v = row.get("hero_name")
			if typeof(v) == TYPE_STRING:
				hero = String(v)

		if hero == "":
			continue

		# что у этого героя в расписании
		for s in GameManager.scheduled.get(hero, []):
			if typeof(s) != TYPE_DICTIONARY:
				continue
			var def_id := String(s.get("def_id",""))
			var def = GameManager.task_defs.get(def_id, {})
			var start := int(s.get("start", 0))
			var dur := int(s.get("duration", 1))

			var card := card_template.duplicate() as ColorRect
			card.visible = true
			card.set("task_name", String(def.get("title", def_id)))
			card.set("duration_slots", dur)
			if s.has("inst_id"):
				card.set("inst_id", int(s["inst_id"]))
			card.set("schedule_start_slot", start)
			var y = (row.size.y - card.size.y) / 2.0
			card.position = Vector2(start * SLOT_WIDTH, y)
			card.set_size(Vector2(dur * SLOT_WIDTH, card.size.y))
			row.add_child(card)
