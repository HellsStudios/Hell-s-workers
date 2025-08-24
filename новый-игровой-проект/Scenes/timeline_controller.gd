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
@onready var popup_buttons: VBoxContainer = $UI/EventPopup/Buttons
var rows: Array[Node] = []
var event_active: bool = false
var running: bool = false
var current_slot: int = 0           # 0..47
var slot_time_accum: float = 0.0
var base_sec_per_slot: float = 0.7   # 1× скорость
var speed_mult: float = 1.0          # множитель
var sec_per_slot: float = 0.7

const TOTAL_SLOTS := 48

func _go_mansion() -> void:
	GameManager.reset_day_summary()
	get_tree().change_scene_to_file("res://scenes/mansion.tscn")  # путь подставь свой

func _show_event(ev: Dictionary, hero: String, inst_id: int) -> void:
	# стопаем таймлайн и включаем «жёсткий» модальный режим
	event_active = true
	running = false

	popup.title = "Событие"
	popup_text.text = String(ev.get("text", ""))

	# СДЕЛАТЬ ОКНО СТРОГО МОДАЛЬНЫМ И НЕЗАКРЫВАЕМЫМ
	popup.exclusive = true  # блокирует клики/ввод вне окна
	# спрятать/заблокировать встроенную кнопку "ОК" у AcceptDialog
	var ok_btn := popup.get_ok_button()
	if ok_btn:
		ok_btn.visible = false
		ok_btn.disabled = true
		ok_btn.focus_mode = Control.FOCUS_NONE

	# перехватываем попытки закрыть крестиком, Esc, Alt+F4
	if not popup.close_requested.is_connected(_on_event_close_requested):
		popup.close_requested.connect(_on_event_close_requested)

	# подчистим прошлые кнопки
	for c in popup_buttons.get_children():
		c.queue_free()

	# cпавним опции
	var opts: Array = ev.get("options", [])
	if opts.is_empty():
		# Без вариантов — принудительная «кнопка» продолжения (но не "ОК")
		var b := Button.new()
		b.text = "Продолжить"
		b.pressed.connect(func():
			_on_event_option_chosen(hero, inst_id, ev, {}))
		popup_buttons.add_child(b)
		b.grab_focus()
	else:
		for i in opts.size():
			var opt = opts[i]
			var b := Button.new()
			b.text = String(opt.get("text", "Вариант %d" % (i + 1)))
			b.pressed.connect(func():
				_on_event_option_chosen(hero, inst_id, ev, opt))
			popup_buttons.add_child(b)
			if i == 0:
				b.grab_focus()  # чтобы Enter сразу срабатывал на 1-й опции

	popup.popup_centered()

func _on_event_close_requested() -> void:
	# намеренно НИЧЕГО не закрываем
	Toasts.warn("Нельзя закрыть событие — выберите вариант.")
	popup.popup_centered()
	popup.grab_focus()

func _on_event_option_chosen(hero: String, inst_id: int, ev: Dictionary, opt: Dictionary) -> void:
	# закрываем попап, резолвим ивент, снова запускаем таймлайн
	popup.hide()
	GameManager._resolve_event_option(hero, inst_id, ev, opt)
	event_active = false
	running = true

func _on_day_end() -> void:
	running = false
	var sum = GameManager.get_day_summary()
	var msg := "[b]Итоги дня[/b]\n" + "Крестли: +%d\nЭтерия: +%d\n" % [int(sum.krestli), int(sum.etheria)]
	if sum.items.size() > 0:
		msg += "Предметы: %s\n" % [JSON.stringify(sum.items)]
	if sum.supplies.size() > 0:
		msg += "Припасы: %s\n" % [JSON.stringify(sum.supplies)]

	popup.title = "День завершён"
	popup_text.text = msg
	popup.get_ok_button().text = "В особняк"
	popup.popup_centered()
	popup.confirmed.connect(_go_mansion, CONNECT_ONE_SHOT)

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
	speed_mult = max(0.01, v)
	sec_per_slot = base_sec_per_slot / speed_mult

func _ready() -> void:
	_build_rows_from_scene()
	_attach_rows_to_heroes()
	_refresh_task_pool()
	_redraw_schedule()
	speed_spin.min_value = 0.25
	speed_spin.max_value = 4.0
	speed_spin.step = 0.25
	speed_spin.value = 1.0
	speed_spin.value_changed.connect(_on_speed_changed)
	_on_speed_changed(speed_spin.value)

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
	if not GameManager.task_finished.is_connected(_on_task_finished):
		GameManager.task_finished.connect(_on_task_finished)


	# Закрытие попапа продолжает время
	if popup and not popup.confirmed.is_connected(func(): running = true):
		popup.confirmed.connect(func(): running = true)
		
func _advance_one_slot() -> void:
	if event_active:
		return
	current_slot += 1
	if current_slot >= 48:
		_on_day_end()
		return
	# события в слоте ...
	_check_task_finishes(current_slot)
func _on_task_finished(hero: String, inst_id: int, success: bool, rewards: Dictionary) -> void:
	# UI убирается сам через _redraw_schedule() от schedule_changed
	_redraw_schedule()
	var k := int(rewards.get("krestli",0))
	var title := ""
	# находим деф для текста
	for s in GameManager.scheduled.get(hero, []):
		if int(s.get("inst_id",0)) == inst_id:
			title = String(GameManager.task_defs.get(s.get("def_id",""), {}).get("title",""))
			break
	if title == "":
		# можно достать из пула по def_id инстанса, если хранишь
		pass
	var msg := "[b]Задача завершена[/b]: %s\n+%d крестли" % [title, k]
	popup_text.text = msg
	popup.title = "Готово"
	popup.get_ok_button().text = "Ок"
	popup.popup_centered()

func _check_task_finishes(slot: int) -> void:
	for row in rows:
		var hero := String(row.get("hero_name")) if row.has_method("get") else ""
		if hero == "": continue
		for s in GameManager.scheduled.get(hero, []):
			if typeof(s) != TYPE_DICTIONARY: continue
			var st := int(s.get("start",0))
			var dur := int(s.get("duration",1))
			if slot >= st + dur and not bool(s.get("_done", false)):
				var inst_id := int(s.get("inst_id",0))
				s["_done"] = true   # чтобы не триггерить повторно на этом же кадре
				GameManager.finish_task(hero, inst_id, true)  # успех/фэйлы — позже по логике


func _on_task_started(hero: String, inst_id: int) -> void:
	print("[TL] START  hero=", hero, " inst=", inst_id)

func _on_task_event(hero: String, inst_id: int, ev: Dictionary) -> void:
	# Пока просто стопаем время и показываем текст события
	_show_event(ev, hero, inst_id)

func _on_task_completed(hero: String, inst_id: int, outcome: Dictionary) -> void:
	var ok := bool(outcome.get("success", true))
	var msg := "Задание завершено: "
	if ok:
		msg += "успех"
	else:
		msg += "провал"
	print("[TL] ", msg, " hero=", hero, " inst=", inst_id)



func _process(delta: float) -> void:
	if event_active:
		return
	if not running:
		#_set_pointer_x()
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
	# очистка визуала
	for c in task_list.get_children():
		if c != card_template:
			c.queue_free()
	if card_template:
		card_template.visible = false

	print("[POOL] size=", GameManager.active_task_pool.size())

	# отрисовка по пулу...


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
		var kind := String(inst.get("kind","daily"))
		# ColorRect у карточки:
		if node is ColorRect:
			# daily – как было (серый)
			if kind == "quest":
				(node as ColorRect).color = Color(0.22, 0.35, 0.55)  # любой контрастный цвет под сюжет
			else:
				(node as ColorRect).color = Color(0.6, 0.6, 0.6)

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
				c.free()   # сразу, без задержки кадра

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
			var kind := String(s.get("kind","daily"))
			if card is ColorRect:
				if kind == "quest":
					card.color = Color(0.22, 0.35, 0.55)
				else:
					card.color = Color(0.6, 0.6, 0.6)
			card.visible = true
			# сброс якорей/флагов, иначе наследует «растяжку» из пула
			card.set_anchors_preset(Control.PRESET_TOP_LEFT)
			card.anchor_right = 0.0
			card.anchor_bottom = 0.0
			card.size_flags_horizontal = 0
			card.size_flags_vertical = 0
			card.set("task_name", String(def.get("title", def_id)))
			card.set("duration_slots", dur)
			if s.has("inst_id"):
				card.set("inst_id", int(s["inst_id"]))
			card.set("schedule_start_slot", start)
			var y = (row.size.y - card.size.y) / 2.0
			card.position = Vector2(start * SLOT_WIDTH, y)
			card.set_size(Vector2(dur * SLOT_WIDTH, card.size.y))
			row.add_child(card)
