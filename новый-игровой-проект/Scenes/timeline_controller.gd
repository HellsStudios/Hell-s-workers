extends Node

const SLOT_WIDTH: float = 25.0
var _event_seen: Dictionary = {}
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
var running: bool = false:
	set(value):
		if running == value: return
		running = value
		_apply_drag_lock()  # включаем/выключаем перетаскивание

var current_slot: int = 0           # 0..47
var slot_time_accum: float = 0.0
var base_sec_per_slot: float = 0.7   # 1× скорость
var speed_mult: float = 1.0          # множитель
var sec_per_slot: float = 0.7
var day_end_shown: bool = false
const TOTAL_SLOTS := 48
var _scene_switching := false
var _popup_queue: Array = []      # [{kind:"event"/"finish"/"day_end", ...}]
var _popup_busy: bool = false

var _event_queue: Array = []            # [{ev, hero, inst}]

enum PopupMode { NONE, EVENT, INFO }
var _popup_mode : int = PopupMode.NONE

var _pause_stack := 0

func push_pause() -> void:
	_pause_stack += 1

func pop_pause() -> void:
	_pause_stack = max(0, _pause_stack - 1)

var _finish_queue: Array = []       # элементы: {"hero":String,"inst":int,"success":bool,"rewards":Dictionary}

func _show_finish_popup(hero: String, inst_id: int, success: bool, rewards: Dictionary) -> void:
	_popup_set_mode_info("Ок")
	push_pause()
	popup.title = "Задача провалена"
	if success:
		popup.title = "Задача выполнена" 

	var def_id := ""
	for s in GameManager.scheduled.get(hero, []):
		if int(s.get("inst_id", -1)) == inst_id:
			def_id = String(s.get("def_id",""))
			break
	if def_id == "" and GameManager.task_defs.size() > 0:
		def_id = GameManager._inst_def(inst_id)

	var title := def_id
	if GameManager.task_defs.has(def_id):
		title = String(GameManager.task_defs[def_id].get("title", def_id))

	var parts: Array = []
	var k := int(rewards.get("krestli", 0)); if k>0: parts.append("+%d кр." % k)
	var e := int(rewards.get("etheria", 0)); if e>0: parts.append("+%d эф." % e)

	if rewards.has("items"):
		for it in rewards["items"]:
			if typeof(it)==TYPE_DICTIONARY:
				parts.append("%s×%d" % [GameManager.item_title(String(it.get("id",""))), int(it.get("count",0))])
	if rewards.has("supplies"):
		for sp in rewards["supplies"]:
			if typeof(sp)==TYPE_DICTIONARY:
				parts.append("%s×%d" % [GameManager.supply_title(String(sp.get("id",""))), int(sp.get("count",0))])

	var body := "%s\n%s" % [title, ("Успех" if success else "Провал")]
	if parts.size() > 0:
		body += "\n" + ", ".join(parts)

	popup_text.text = body
	popup.popup_centered()

	# один раз на «Ок»
	popup.confirmed.connect(func():
		popup.hide()
		pop_pause()
		_popup_busy = false
		_show_next_popup()
	, CONNECT_ONE_SHOT)


func _find_start_slot(hero: String, inst_id: int) -> int:
	for s in GameManager.scheduled.get(hero, []):
		if int(s.get("inst_id", -1)) == inst_id:
			return int(s.get("start", -999))
	return -999

func _event_key(start_slot: int, ev: Dictionary) -> String:
	return "%d@%s" % [start_slot, String(ev.get("id", ""))]

func _popup_set_mode_event() -> void:
	_popup_mode = PopupMode.EVENT
	event_active = true
	var ok_btn := popup.get_ok_button()
	if ok_btn:
		ok_btn.visible = false
		ok_btn.disabled = true
	popup.dialog_hide_on_ok = false
	popup.exclusive = true

func _popup_set_mode_info(ok_text: String = "Ок") -> void:
	_popup_mode = PopupMode.INFO
	event_active = false
	var ok_btn := popup.get_ok_button()
	if ok_btn:
		ok_btn.text = ok_text
		ok_btn.visible = true
		ok_btn.disabled = false
	popup.dialog_hide_on_ok = true
	popup.exclusive = true

func _queue_event(ev: Dictionary, hero: String, inst_id: int) -> void:
	_event_queue.append({"ev":ev, "hero":hero, "inst":inst_id})

func _queue_finish(hero: String, inst_id: int, success: bool, rewards: Dictionary) -> void:
	_finish_queue.append({"hero":hero, "inst":inst_id, "success":success, "rewards":rewards})

func _show_next_popup() -> void:
	if _popup_busy:
		return
	# приоритет: сначала финал задач, затем события
	if _finish_queue.size() > 0:
		var f: Dictionary = _finish_queue.pop_front()
		_popup_busy = true
		_show_finish_popup(String(f["hero"]), int(f["inst"]), bool(f["success"]), f["rewards"])
		return
	if _event_queue.size() > 0:
		var e: Dictionary = _event_queue.pop_front()
		_popup_busy = true
		_show_event(e["ev"], String(e["hero"]), int(e["inst"]))


func _format_rewards_bb(rew: Dictionary) -> String:
	var lines: Array[String] = []
	var k := int(rew.get("krestli", 0)); if k > 0: lines.append("• Крестли: [b]+%d[/b]" % k)
	var e := int(rew.get("etheria", 0)); if e > 0: lines.append("• Этерия: [b]+%d[/b]"  % e)
	if rew.has("items"):
		for it in rew["items"]:
			if typeof(it) == TYPE_DICTIONARY:
				lines.append("• %s × %d" % [GameManager.item_title(String(it.get("id",""))), int(it.get("count",0))])
	if rew.has("supplies"):
		for sp in rew["supplies"]:
			if typeof(sp) == TYPE_DICTIONARY:
				lines.append("• %s × %d" % [GameManager.supply_title(String(sp.get("id",""))), int(sp.get("count",0))])
	return "\n".join(lines)



func _on_event_close_requested() -> void:
	if _popup_mode == PopupMode.EVENT:
		Toasts.warn("Нельзя закрыть событие — выберите вариант.")
		popup.call_deferred("popup_centered")
		popup.call_deferred("grab_focus")
	else:
		popup.hide()
		_popup_busy = false
		_show_next_popup()


func _queue_day_end(sum: Dictionary) -> void:
	_popup_queue.append({"kind":"day_end","sum":sum})
	_try_show_popup()

func _try_show_popup() -> void:
	if _popup_busy: return
	if _popup_queue.is_empty(): return
	_popup_busy = true
	var req: Dictionary = _popup_queue.pop_front()
	var kind := String(req.get("kind",""))
	match kind:
		"event":
			_show_event(req["ev"], String(req["hero"]), int(req["inst"]))   # ← твоя рабочая функция
		"finish":
			_show_finish_popup(String(req["hero"]), int(req["inst"]), bool(req["success"]), req.get("rewards", {}))
		"day_end":
			_show_day_end_popup(req.get("sum", {}))
		_:
			_popup_busy = false

func _popups_continue_or_resume() -> void:
	# Вызывай это после закрытия ЛЮБОГО окна
	if not _popup_queue.is_empty():
		# держим паузу, просто показываем следующее
		_popup_busy = false
		_try_show_popup()
	else:
		_popup_busy = false
		event_active = false
		running = true

func _go_mansion() -> void:
	if _scene_switching: return
	_scene_switching = true
	GameManager.reset_day_summary()
	GameManager.mark_timeline_used()
	GameManager.current_phase = 2  # вечер по условию
	get_tree().change_scene_to_file("res://Scenes/mansion.tscn")

func _show_event(ev: Dictionary, hero: String, inst_id: int) -> void:
	_popup_set_mode_event()
	running = false
	popup.title = "Событие"
	popup_text.text = String(ev.get("text", ""))

	for c in popup_buttons.get_children(): c.queue_free()

	var opts: Array = ev.get("options", [])
	if opts.is_empty():
		var b := Button.new()
		b.text = "Продолжить"
		b.focus_mode = Control.FOCUS_ALL
		b.pressed.connect(func():
			_on_event_option_chosen(hero, inst_id, ev, {}))
		popup_buttons.add_child(b)
		b.grab_focus()
	else:
		for i in range(opts.size()):
			var opt_local: Dictionary = opts[i]
			var b := Button.new()
			b.text = String(opt_local.get("text", "Вариант %d" % (i + 1)))
			b.focus_mode = Control.FOCUS_ALL
			b.pressed.connect(func():
				_on_event_option_chosen(hero, inst_id, ev, opt_local))
			popup_buttons.add_child(b)
			if i == 0: b.grab_focus()

	popup.popup_centered()
	popup.grab_focus()

func _on_event_option_chosen(hero: String, inst_id: int, ev: Dictionary, opt: Dictionary) -> void:
	popup.hide()
	GameManager._resolve_event_option(hero, inst_id, ev, opt)
	event_active = false
	_popup_busy = false
	running = true
	_show_next_popup()


func _event_abs_key(st: int, ev: Dictionary) -> String:
	return str(st + int(ev.get("at_rel_slot",-999)))


func _drain_event_queue() -> void:
	if _popup_busy or event_active or _event_queue.is_empty(): return
	var it = _event_queue.pop_front()
	_popup_busy = true
	_show_event(it["ev"], it["hero"], it["inst"])



func _on_task_event(hero: String, inst_id: int, ev: Dictionary) -> void:
	print("[UI] task_event hero=%s inst=%d text=%s" % [hero, inst_id, String(ev.get("text",""))])

	# анти-дубль
	var st := _find_start_slot(hero, inst_id)
	var key := _event_key(st, ev)
	var bucket: Dictionary = _event_seen.get(inst_id, {})
	if bucket.has(key):
		return
	bucket[key] = true
	_event_seen[inst_id] = bucket

	# если заняты — ставим в очередь
	if event_active || popup.visible || _popup_busy:
		_queue_event(ev, hero, inst_id)
		return

	_popup_busy = true
	_show_event(ev, hero, inst_id)


func _show_day_end_popup(sum: Dictionary) -> void:
	event_active = true
	running = false

	var msg := "[center][b]Итоги дня[/b][/center]\n"
	msg += "[b]Крестли:[/b] +%d\n" % int(sum.get("krestli",0))
	msg += "[b]Этерия:[/b] +%d\n"  % int(sum.get("etheria",0))

	var items: Array = sum.get("items", [])
	if items.size() > 0:
		msg += "\n[b]Предметы:[/b]\n"
		for it in items:
			if typeof(it) == TYPE_DICTIONARY:
				msg += "• %s × %d\n" % [GameManager.item_title(String(it.get("id",""))), int(it.get("count",0))]

	var sups: Array = sum.get("supplies", [])
	if sups.size() > 0:
		msg += "\n[b]Припасы:[/b]\n"
		for sp in sups:
			if typeof(sp) == TYPE_DICTIONARY:
				msg += "• %s × %d\n" % [GameManager.supply_title(String(sp.get("id",""))), int(sp.get("count",0))]

	popup.title = "День завершён"
	popup_text.bbcode_enabled = true
	popup_text.text = msg

	for c in popup_buttons.get_children(): c.queue_free()
	var b := Button.new()
	b.text = "В особняк"
	b.focus_mode = Control.FOCUS_ALL
	b.pressed.connect(func():
		popup.hide()
		GameManager.reset_day_summary()
		get_tree().change_scene_to_file("res://Scenes/mansion.tscn")
	, CONNECT_ONE_SHOT)
	popup_buttons.add_child(b)
	b.grab_focus()

	var ok_btn := popup.get_ok_button()
	if ok_btn:
		ok_btn.visible = false
		ok_btn.disabled = true

	popup.popup_centered()
	popup.grab_focus()


func _on_day_end() -> void:
	running = false
	event_active = true  # блокируем инпут таймлайна, пока окно открыто
	_event_queue.clear()
	var sum := GameManager.get_day_summary()
	popup.title = "День завершён"
	popup_text.bbcode_enabled = true
	popup_text.text = _format_day_summary(sum)

	# 1) никаких кастом-кнопок
	for c in popup_buttons.get_children():
		c.queue_free()
	popup_buttons.visible = false

	# 2) используем встроенную ОК
	popup.dialog_hide_on_ok = true
	var ok_btn := popup.get_ok_button()
	if ok_btn:
		ok_btn.visible = true
		ok_btn.disabled = false
		ok_btn.text = "В особняк"

	# 3) не копим повторные подключения
	if popup.confirmed.is_connected(_go_mansion):
		popup.confirmed.disconnect(_go_mansion)
	popup.confirmed.connect(_go_mansion, CONNECT_ONE_SHOT)

	popup.exclusive = true
	popup.popup_centered()
	popup.grab_focus()

func _fmt_items(arr: Array) -> String:
	var parts: Array[String] = []
	for e in arr:
		if typeof(e) == TYPE_DICTIONARY:
			var id := String(e.get("id",""))
			var cnt := int(e.get("count",0))
			if id != "" and cnt > 0:
				parts.append("%s×%d" % [GameManager.item_title(id), cnt])
	return ", ".join(parts)

func _fmt_supplies(arr: Array) -> String:
	var parts: Array[String] = []
	for e in arr:
		if typeof(e) == TYPE_DICTIONARY:
			var id := String(e.get("id",""))
			var cnt := int(e.get("count",0))
			if id != "" and cnt > 0:
				parts.append("%s×%d" % [GameManager.supply_title(id), cnt])
	return ", ".join(parts)

func _format_day_summary(sum: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("[center][b]Итоги дня[/b][/center]")
	lines.append("[center]Крестли: +%d[/center]" % int(sum.get("krestli",0)))
	lines.append("[center]Этерия: +%d[/center]" % int(sum.get("etheria",0)))

	var items := _fmt_items(sum.get("items", []))
	if items != "":
		lines.append("[center]Предметы: %s[/center]" % items)

	var sups := _fmt_supplies(sum.get("supplies", []))
	if sups != "":
		lines.append("[center]Припасы: %s[/center]" % sups)

	return "\n".join(lines)



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
	_event_seen.clear()

func _on_speed_changed(v: float) -> void:
	speed_mult = max(0.01, v)
	sec_per_slot = base_sec_per_slot / speed_mult

func _ready() -> void:
	_build_rows_from_scene()
	_attach_rows_to_heroes()
	_refresh_task_pool()
	_redraw_schedule()
	_reset_day()
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
	
	current_slot = int(GameManager.timeline_clock.get("slot", 0))
	base_sec_per_slot = float(GameManager.timeline_clock.get("slot_sec", 0.7))
	sec_per_slot = base_sec_per_slot / max(0.01, float(speed_spin.value))
	running = bool(GameManager.timeline_clock.get("running", false))
	
		# --- POINTER init ---
	_sync_pointer_rect()
	_set_pointer_x() #сомнительно

	if play_btn and not play_btn.pressed.is_connected(_start):
		play_btn.pressed.connect(_start)
	if pause_btn and not pause_btn.pressed.is_connected(_pause):
		pause_btn.pressed.connect(_pause)
	if speed_spin and not speed_spin.value_changed.is_connected(_on_speed_changed):
		speed_spin.value_changed.connect(_on_speed_changed)

	if time_area and not time_area.resized.is_connected(_sync_pointer_rect):
		time_area.resized.connect(_sync_pointer_rect)

	set_process(true)
	
	if GameManager.task_event.is_connected(_on_task_event):
		GameManager.task_event.disconnect(_on_task_event)
	GameManager.task_event.connect(_on_task_event)
	if GameManager.has_signal("task_started") and not GameManager.task_started.is_connected(_on_task_started):
		GameManager.task_started.connect(_on_task_started)
#	if GameManager.has_signal("task_event") and not GameManager.task_event.is_connected(_on_task_event):
#		GameManager.task_event.connect(_on_task_event)
	if GameManager.has_signal("task_completed") and not GameManager.task_completed.is_connected(_on_task_completed):
		GameManager.task_completed.connect(_on_task_completed)
	if not GameManager.task_finished.is_connected(_on_task_finished):
		GameManager.task_finished.connect(_on_task_finished)

	# ——— EVENT POPUP: ЖЁСТКАЯ БЛОКИРОВКА ———

	popup.exclusive = true                    # модальная блокировка ввода
	popup.dialog_hide_on_ok = false           # "Ок" сам окно не закроет
	if not popup.close_requested.is_connected(_on_event_close_requested):
		popup.close_requested.connect(_on_event_close_requested)

	# спрятать встроенный ОК — будем юзать свои кнопки


		
	if GameManager.has_method("register_timeline"):
		GameManager.register_timeline(self)

func _card_color(kind: String, def: Dictionary) -> Color:
	# battle помечаем либо по tags:["battle"], либо по флагу def["is_battle"]
	var tags: Array = def.get("tags", [])
	var is_battle := bool(def.get("is_battle", false)) or (tags is Array and tags.has("battle"))
	if is_battle:
		return Color("#d24a4a") # красный

	if kind == "daily":
		return Color("#3b82f6") # синий

	# всё остальное (квесты без боя) — жёлтые
	return Color("#eab308")

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
	print("[UI] task_finished hero=", hero, " inst=", inst_id, " success=", success, " rewards=", rewards)
	_clear_event_buttons()  # ← ВАЖНО: очистить старые опции события
	_redraw_schedule()
	_queue_finish(hero, inst_id, success, rewards)
	_show_next_popup()
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


		# этот инстанс завершён — все отметки его событий можно забыть
	_event_seen.erase(inst_id)


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
				#GameManager.finish_task(hero, inst_id, true)  # успех/фэйлы — позже по логике


func _on_task_started(hero: String, inst_id: int) -> void:
	print("[TL] START  hero=", hero, " inst=", inst_id)


func _on_task_completed(hero: String, inst_id: int, outcome: Dictionary) -> void:
	print("[UI] task_completed hero=", hero, " inst=", inst_id, " success=", bool(outcome.get("success", true)))
	var ok := bool(outcome.get("success", true))
	var msg := "Задание завершено: "
	if ok:
		msg += "успех"
	else:
		msg += "провал"
	print("[TL] ", msg, " hero=", hero, " inst=", inst_id)

func _clear_event_buttons() -> void:
	# убрать все кнопки-опции, снять фокус, гарантировать отсутствие подвесов
	if popup_buttons:
		for c in popup_buttons.get_children():
			if c is Button:
				(c as Button).disabled = true
			c.queue_free()
	# на всякий снимаем фокус с диалога вообще

func _task_tooltip(def: Dictionary) -> String:
	var title := String(def.get("title", def.get("id","")))
	var desc  := String(def.get("desc", def.get("description","")))
	var dur   := int(def.get("duration_slots", 4))
	var need_qual: Dictionary = def.get("require", {}).get("qual", {})
	var req_lines: Array = []
	for q in need_qual.keys():
		# если нужен локализованный тайтл — зови GameManager.qual_title
		req_lines.append("%s %d+" % [String(q), int(need_qual[q])])
	var req_txt := ""
	if req_lines.size() > 0:
		req_txt = "\nТребуется: " + ", ".join(req_lines)
	# ToolTip у Control — обычный текст с переносами
	return "%s\n\n%s\nДлительность: %d×15м%s" % [title, desc, dur, req_txt]


func _process(delta: float) -> void:
	if _pause_stack > 0:
		return
	if event_active or not running:
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
			_queue_day_end(GameManager.get_day_summary())
			if not day_end_shown:
				day_end_shown = true
				event_active = true
				_on_day_end()
			return  # дальше ничего не делаем на этом кадре

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



func _apply_drag_lock() -> void:
	# пул задач (слева)
	for c in task_list.get_children():
		if c == card_template: continue
		if c is Control:
			(c as Control).mouse_filter = (
				Control.MOUSE_FILTER_IGNORE if running else Control.MOUSE_FILTER_STOP
			)

	# расписание на строках
	for row in rows:
		for cc in row.get_children():
			if cc is Control:
				if running:
					(cc as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
				else:
					# обычная логика: активные — игнор, остальным разрешаем
					var start = int(cc.get("schedule_start_slot"))
					var dur   = int(cc.get("duration_slots"))
					var now   := current_slot
					var active_task := (start >= 0 and now >= start and now < start + dur)
					(cc as Control).mouse_filter = (
						Control.MOUSE_FILTER_IGNORE if active_task else Control.MOUSE_FILTER_STOP
					)

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
		node.mouse_filter = (Control.MOUSE_FILTER_IGNORE if running else Control.MOUSE_FILTER_STOP)
		# свойства скрипта карточки
		node.tooltip_text = _task_tooltip(def)
		node.set("duration_slots", int(def.get("duration_slots", 4)))
		node.set("task_name", String(def.get("title", def_id)))
		node.set("inst_id", int(inst.get("inst_id", 0)))
		node.set("schedule_start_slot", -1)
		var kind := String(inst.get("kind","daily"))
		if node is ColorRect:
			node.color = _card_color(kind, def)

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
				card.color = _card_color(kind, def)
			card.visible = true
			card.tooltip_text = _task_tooltip(def)
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
			var now := current_slot
			var active_task := false
			if now >= start and now < start + dur:
				active_task = true
			if running:
				card.mouse_filter = Control.MOUSE_FILTER_IGNORE
			else:
				if active_task:
					card.mouse_filter = Control.MOUSE_FILTER_IGNORE  # не получать мышь → DnD не стартует
					card.modulate = Color(1, 1, 1, 0.9)              # лёгкий визуальный намёк (не обязательно)
				else:
					card.mouse_filter = Control.MOUSE_FILTER_STOP
