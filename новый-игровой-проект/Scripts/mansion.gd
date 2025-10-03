extends Node2D

#var current_day : int = 1  # текущий день, начинаем с 1

# Подменю комнаты 2 (создадим программно, если отсутствует)
var room2_menu: PopupPanel
var room2_menu_vbox: VBoxContainer

# Подтверждение «в таймлайн?»
var timeline_confirm: ConfirmationDialog
# ====== DBG: мышь/ввод после закрытия попапа ======
var DBG_LOG := true
var _dbg_watch_active := false
var _dbg_watch_left := 0
var _dbg_reason := ""
var _dbg_motion_count := 0

var _input_quarantine_t := 0.0
var _cam_proc_prev := true
var _cam_phys_prev := true

@onready var cam: Camera2D = $Camera2D
@onready var manage_menu: PopupPanel = $UI/ManagementMenu
@onready var manage_btn: Button = $UI/TopBar/ManageButton
@onready var resource: Label = $UI/PanelResources/ResourcesLabel
const COND_BUSY: StringName = "busy"
@onready var end_day_confirm: ConfirmationDialog = $UI/EndDayConfirm
@onready var Clickables := $Camera2D/Clickables
@onready var clue_holder: Node = Clickables      # положим Клю туда же, где и кликаблсы
var _active_clue: Node2D = null                  # текущая инстанция
const CONDITION_PRIORITY := {
	COND_BUSY: 100,           # Занят — скрыть всё
	"injury": 80,
	"fatigue": 70,
	"hungry": 60,
	"sad": 50,
	"weird_day": 40,
	"default": 0              # если ничего не подошло
}

func _clue_spawn_points() -> Array:
	var pts: Array = []
	for n in Clickables.get_children():
		if n.is_in_group("clue_point"):
			pts.append(n)
	return pts

func _clue_despawn_local() -> void:
	if is_instance_valid(_active_clue):
		_active_clue.queue_free()
	_active_clue = null

func _clue_spawn_local(scene_path: String) -> void:
	if is_instance_valid(_active_clue): return
	if scene_path == "" or not ResourceLoader.exists(scene_path): return

	var pts := _clue_spawn_points()
	if pts.is_empty():
		push_warning("[Mansion][Clue] Нет точек с группой 'clue_point' под Clickables")
		return

	var scn := load(scene_path)
	var node = scn.instantiate()
	var p = pts[randi() % pts.size()]

	if p is Node2D and node is Node2D:
		(node as Node2D).global_position = (p as Node2D).global_position

	Clickables.add_child(node)
	_active_clue = node

	# уведомляем GM
	GameManager.clue_notify_spawned()

	# сигналы
	if node.has_signal("picked"):
		node.picked.connect(func():
			GameManager.clue_notify_picked()
		)
	if node.has_signal("vanished"):
		node.vanished.connect(func():
			if _active_clue == node:
				_active_clue = null
			GameManager.clue_notify_vanished()
		)

	# на всякий — если у Clue нет AnimationPlayer.spawn, можно подсветить появление
	if node.has_node("AnimationPlayer"):
		var ap: AnimationPlayer = node.get_node("AnimationPlayer")
		if ap and ap.has_animation("spawn"):
			ap.play("spawn")


func _build_click_index() -> void:
	_click_idx.clear()
	_click_all_by_char.clear()

	for node in Clickables.get_children():
		if not (node is Node): # фильтр на всякий случай
			continue
		var name_str := String(node.name)
		var sep := name_str.rfind("_")
		if sep == -1:
			continue
		var char_name := name_str.substr(0, sep)
		var cond_key  := name_str.substr(sep + 1, name_str.length())

		if not _click_idx.has(char_name):
			_click_idx[char_name] = {}
			_click_all_by_char[char_name] = []

		_click_idx[char_name][cond_key] = node
		_click_all_by_char[char_name].append(node)

		# по умолчанию всё скрыто; будем включать нужное
		_set_visible_safe(node, false)
		print("[MANSION][IDX] summary:")
		for k in _click_idx.keys():
			print("   ", k, ":", _click_idx[k].keys())

func _set_visible_safe(n: Node, v: bool) -> void:
	if "visible" in n:
		n.visible = v
	elif n is CanvasItem:
		(n as CanvasItem).visible = v

func update_all_clickables() -> void:
	for char_name in _click_idx.keys():
		var conds: Array[StringName] = _get_conditions_for(char_name)
		_apply_clickables_for(char_name, conds)

func _get_conditions_for(char_name: String) -> Array[StringName]:
	# Автолоад "GameManager" доступен как глобальный объект.
	if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("get_conditions_for"):
		var res = GameManager.get_conditions_for(char_name)
		print("[MANSION][CALL] get_conditions_for('%s') -> %s" % [char_name, str(res)])
		return res
	print("[MANSION][CALL] GameManager missing -> []")
	return []

func _on_conditions_changed(char_name: String) -> void:
	print("[MANSION][EV] conditions_changed hero='", char_name, "'")
	if char_name == "":
		update_all_clickables()
		return
	var conds := _get_conditions_for(char_name)
	_apply_clickables_for(char_name, conds)

func _apply_clickables_for(char_name: String, conds: Array) -> void:
	print("[MANSION][APPLY] hero=", char_name, " conds=", conds)

	# 1) BUSY — скрыть всё
	var has_busy := false
	for v in conds:
		if String(v) == "busy":
			has_busy = true; break
	if has_busy:
		print("[MANSION][APPLY]  -> BUSY: hide all for ", char_name)
		_hide_all_for(char_name)
		return

	# 2) Выбираем по приоритету
	var chosen := ""
	var best := -999
	for c in conds:
		var c_str := String(c)
		var pr := 0
		if CONDITION_PRIORITY.has(c_str): pr = int(CONDITION_PRIORITY[c_str])
		else: pr = 1
		if pr > best and _has_click_node(char_name, c_str):
			best = pr
			chosen = c_str
			print("[MANSION][APPLY]  candidate:", c_str, " pr=", pr)

	# 3) Fallback: default
	if chosen == "":
		var has_def := _has_click_node(char_name, "default")
		print("[MANSION][APPLY]  no candidate; default exists=", has_def)
		if has_def:
			chosen = "default"

	print("[MANSION][APPLY]  SHOW ->", char_name, "/", chosen)
	_show_only(char_name, chosen)


func _hide_all_for(char_name: String) -> void:
	if not _click_all_by_char.has(char_name):
		return
	for n in _click_all_by_char[char_name]:
		_set_visible_safe(n, false)

func _has_click_node(char_name: String, cond_key: String) -> bool:
	return _click_idx.has(char_name) and _click_idx[char_name].has(cond_key)

func _show_only(char_name: String, cond_key: String) -> void:
	_hide_all_for(char_name)
	if cond_key == "":
		return
	if _has_click_node(char_name, cond_key):
		_set_visible_safe(_click_idx[char_name][cond_key], true)

# { "Berit": { "hungry": Node, "injury": Node, "default": Node, ... }, ... }
var _click_idx: Dictionary = {}
# { "Berit": [Node, Node, ...] } — для быстрого скрытия всех
var _click_all_by_char: Dictionary = {}

func _on_room_1_input_event(_vp, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_cam_set_drag(false)
		get_viewport().set_input_as_handled()
		# было: $Room1PopupPanel.open_from(...)
		# стало:
		if is_instance_valid(manage_menu) and manage_menu.has_method("open_cooking_tab"):
			manage_menu.call("open_cooking_tab")

func _start_input_quarantine(sec: float = 0.30) -> void:
	# глушим мир на sec секунд
	_input_quarantine_t = max(_input_quarantine_t, sec)
	if $Camera2D:
		_cam_proc_prev = $Camera2D.is_processing()
		_cam_phys_prev = $Camera2D.is_physics_processing()
		$Camera2D.set_process(false)
		$Camera2D.set_physics_process(false)

func _dbg(msg: String) -> void:
	if DBG_LOG:
		print("[MANSION][DBG] ", msg)

func _dbg_btns_state(event: InputEvent = null) -> String:
	var pos := get_viewport().get_mouse_position()
	var l := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var r := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var m := Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)

	var extra := ""
	if event is InputEventMouseMotion:
		extra = " motion_mask=%d rel=%s" % [event.button_mask, event.relative]
	elif event is InputEventMouseButton:
		extra = " ev_btn=%d pressed=%s dbl=%s pos=%s" % [event.button_index, event.pressed, event.double_click, event.position]

	return "pos=%s L=%s R=%s M=%s%s" % [str(pos), str(l), str(r), str(m), extra]

func _dbg_start_watch(reason: String, frames := 45) -> void:
	_dbg_reason = reason
	_dbg_watch_active = true
	_dbg_watch_left = frames
	_dbg_motion_count = 0
	_dbg("WATCH start (%s), frames=%d | %s" % [_dbg_reason, frames, _dbg_btns_state()])

func _dbg_stop_watch() -> void:
	_dbg("WATCH stop  (%s). motions=%d | %s" % [_dbg_reason, _dbg_motion_count, _dbg_btns_state()])
	_dbg_watch_active = false
	_dbg_reason = ""
	_dbg_watch_left = 0
# ====== /DBG ======

func _on_back_to_timeline_pressed() -> void:
	if GameManager.has_method("goto_timeline"):
		GameManager.goto_timeline()

func _process(delta: float) -> void:
	if _input_quarantine_t > 0.0:
		_input_quarantine_t -= delta
		if _input_quarantine_t <= 0.0 and $Camera2D:
			$Camera2D.set_process(_cam_proc_prev)
			$Camera2D.set_physics_process(_cam_phys_prev)
	resource.text = str("Крестли: ",int(GameManager.krestli))

			
@onready var timeline_button := $Camera2D/Room2 # подставь свой путь



func _on_ToTimelineButton_pressed() -> void:
	if GameManager.timeline_used_today:
		GameManager.toast("Сегодня вы уже занимались делами.")
		return
	# заходим днём
	GameManager.current_phase = 1
	_apply_phase_visuals()
	get_tree().change_Scene_to_file("res://Scenes/timeline.tscn")


func _ready() -> void:
		# 1) построить индекс кликабельных узлов и сразу всё спрятать
	_build_click_index()
	update_all_clickables()  # первичная отрисовка

	# 2) подписка на сигнал и моментальный «пинок» на обновление
	if not GameManager.is_connected("conditions_changed", _on_conditions_changed):
		GameManager.conditions_changed.connect(_on_conditions_changed)
	_on_conditions_changed("")  # обновить всех
	PauseManager.set_mode(Pause.Mode.GENERIC)
	set_process(true)  # нужно для таймового логирования
	# ... остальное как у тебя было ...
	_apply_phase_visuals()
	GameManager.add_or_update_quest("q_intro", "Первый день", "Осмотрись в поместье.")
	GameManager.add_or_update_quest("q_bag", "Собери сумку", "Переложи 3 предмета герою.")
	GameManager.add_codex_entry("Печать", "Официальная печать Берита — тяжёлая.")
	var got := GameManager.claim_completed_quest_rewards()
	if got.size() > 0:
		Toasts.ok("Вы получили награду за квест(ы): " + ", ".join(got))
	# чтобы увидеть «серым»:
	# GameManager.set_quest_completed("q_intro", true)
	if not GameManager.get_meta("intro_dialog_shown", false):
		GameManager.set_meta("intro_dialog_shown", true)
		GameManager.play_dialog("d_intro_berit_sally", self)
	if not GameManager.is_connected("dialog_finished", _on_dialog_finished):
		GameManager.dialog_finished.connect(_on_dialog_finished)
	if !is_instance_valid(end_day_confirm):
		end_day_confirm = ConfirmationDialog.new()
		end_day_confirm.name = "EndDayConfirm"
		end_day_confirm.title = "Завершить день?"
		end_day_confirm.dialog_text = "Перейти к следующему дню?"
		add_child(end_day_confirm)
	end_day_confirm.confirmed.connect(_on_end_day_confirmed)
	if end_day_confirm.has_signal("canceled") and not end_day_confirm.canceled.is_connected(_on_end_day_closed):
		end_day_confirm.canceled.connect(_on_end_day_closed)
	if not end_day_confirm.close_requested.is_connected(_on_end_day_closed):
		end_day_confirm.close_requested.connect(_on_end_day_closed)
	# на всякий, если есть popup_hide в твоей версии:
	if end_day_confirm.has_signal("popup_hide") and not end_day_confirm.popup_hide.is_connected(_on_end_day_closed):
		end_day_confirm.popup_hide.connect(_on_end_day_closed)
		# ── CLUE: подписки на запросы от GameManager
	if not GameManager.is_connected("clue_spawn_requested", _on_clue_spawn_requested):
		GameManager.clue_spawn_requested.connect(_on_clue_spawn_requested)
	if not GameManager.is_connected("clue_clear_requested", _on_clue_clear_requested):
		GameManager.clue_clear_requested.connect(_on_clue_clear_requested)
	if is_instance_valid(manage_menu):
		if not manage_menu.popup_hide.is_connected(_on_management_menu_popup_hide):
			manage_menu.popup_hide.connect(_on_management_menu_popup_hide)
		if manage_menu.has_signal("close_requested") and \
			(not manage_menu.close_requested.is_connected(_on_management_menu_popup_hide)):
			manage_menu.close_requested.connect(_on_management_menu_popup_hide)

	_build_room2_menu()
	_build_timeline_confirm()
	if cam:
		cam.cancel_drag()
		cam.set_drag_enabled(true)

func _on_room2_menu_timeline_pressed() -> void:
	# Сначала закрываем меню (чтобы не лежало поверх подтверждения)
	_close_room2_menu()

	# Проверка: уже использован таймлайн сегодня?
	if GameManager.timeline_used_today:
		GameManager.toast("Сегодня вы уже занимались делами.")
		return

	# Покажем подтверждение
	timeline_confirm.title = "Перейти в таймлайн?"
	timeline_confirm.dialog_text = "Перейти к таймлайну (дневные дела)?"
	timeline_confirm.popup_centered_ratio(0.25)

	# камеру пока не дёргаем — окно само перехватит фокус

func _on_timeline_confirmed() -> void:
	# игрок согласился
	# у тебя таймлайн — это дневная фаза:
	GameManager.current_phase = 1
	# аккуратно возвращаем управление сценой
	if cam:
		cam.cancel_drag()
		_cam_set_drag(true)
	# и переходим
	if GameManager.has_method("goto_timeline"):
		GameManager.goto_timeline()
	else:
		get_tree().change_Scene_to_file("res://Scenes/timeline.tscn")

func _on_timeline_closed() -> void:
	# если закрыли окно, вернём перетаскивание
	if cam:
		cam.cancel_drag()
		_cam_set_drag(true)


func _open_room2_menu(mouse_pos: Vector2 = Vector2.ZERO) -> void:
	if room2_menu == null:
		return

	if cam:
		cam.cancel_drag()
		_cam_set_drag(false)
	_start_input_quarantine(0.20)

	var vp := get_viewport_rect()
	var size := Vector2(300, 0)
	var pos := mouse_pos + Vector2(16, 16)
	pos.x = clamp(pos.x, 0.0, vp.size.x - size.x)
	pos.y = clamp(pos.y, 0.0, vp.size.y - 200.0)

	room2_menu_vbox.modulate = Color(1, 1, 1, 0)
	room2_menu.position = Vector2i(pos) + Vector2i(0, 8)
	room2_menu.popup()

	var tw := create_tween()
	tw.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(room2_menu,      "position",  Vector2i(pos), 0.15)   # позицию tween'им у окна
	tw.parallel().tween_property(room2_menu_vbox, "modulate:a", 1.0, 0.15) # альфу tween'им у контента

func _ui_blocked() -> bool:
	return (is_instance_valid(room2_menu) and room2_menu.visible) \
		or (is_instance_valid(timeline_confirm) and timeline_confirm.visible) \
		or (is_instance_valid(end_day_confirm) and end_day_confirm.visible) \
		or (is_instance_valid(manage_menu) and manage_menu.visible)

func _cam_set_drag(v: bool) -> void:
	if cam:
		cam.cancel_drag()
		cam.set_drag_enabled(v)

func _close_room2_menu() -> void:
	if room2_menu == null or not room2_menu.visible:
		return
	var tw := create_tween()
	tw.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(room2_menu_vbox, "modulate:a", 0.0, 0.12)
	tw.parallel().tween_property(room2_menu, "position", room2_menu.position + Vector2i(0, 6), 0.12)
	tw.tween_callback(Callable(room2_menu, "hide"))

	if cam:
		cam.cancel_drag()
		_cam_set_drag(true)



func _build_room2_menu() -> void:
	# если уже есть в сцене — возьмём, иначе создадим
	room2_menu = $UI/Room2Menu if has_node("UI/Room2Menu") else null
	if room2_menu == null:
		room2_menu = PopupPanel.new()
		room2_menu.name = "Room2Menu"
		# ставим в UI-дерево, чтобы было поверх
		if has_node("UI"):
			$UI.add_child(room2_menu)
		else:
			add_child(room2_menu)

	# Внутренности
	room2_menu_vbox = VBoxContainer.new()
	room2_menu_vbox.custom_minimum_size = Vector2(280, 0)
	room2_menu.add_child(room2_menu_vbox)
	room2_menu.close_requested.connect(_close_room2_menu)
	if room2_menu.has_signal("popup_hide") and not room2_menu.popup_hide.is_connected(_close_room2_menu):
		room2_menu.popup_hide.connect(_close_room2_menu)

	# Кнопка 1: Таймлайн
	var b_timeline := Button.new()
	b_timeline.text = "К таймлайну"
	b_timeline.pressed.connect(_on_room2_menu_timeline_pressed)
	room2_menu_vbox.add_child(b_timeline)

	# (запас для будущих опций)
	# var b_something := Button.new()
	# b_something.text = "Другая опция"
	# b_something.pressed.connect(_on_room2_menu_other_pressed)
	# room2_menu_vbox.add_child(b_something)

	# Разделитель + Закрыть
	var sep := HSeparator.new()
	room2_menu_vbox.add_child(sep)

	var b_close := Button.new()
	b_close.text = "Отмена"
	b_close.pressed.connect(_close_room2_menu)
	room2_menu_vbox.add_child(b_close)


func _build_timeline_confirm() -> void:
	timeline_confirm = $UI/TimelineConfirm if has_node("UI/TimelineConfirm") else null
	if timeline_confirm == null:
		timeline_confirm = ConfirmationDialog.new()
		timeline_confirm.name = "TimelineConfirm"
		timeline_confirm.title = "Перейти в таймлайн?"
		timeline_confirm.dialog_text = "Вы уверены, что хотите перейти на сцену таймлайна?"
		if has_node("UI"):
			$UI.add_child(timeline_confirm)
		else:
			add_child(timeline_confirm)
	timeline_confirm.confirmed.connect(_on_timeline_confirmed)
	if timeline_confirm.has_signal("popup_hide") and not timeline_confirm.popup_hide.is_connected(_on_timeline_closed):
		timeline_confirm.popup_hide.connect(_on_timeline_closed)
	timeline_confirm.close_requested.connect(_on_timeline_closed)


func _on_clue_spawn_requested(scene_path: String) -> void:
	_clue_despawn_local()
	_clue_spawn_local(scene_path)

func _on_clue_clear_requested() -> void:
	_clue_despawn_local()

func _on_end_day_closed() -> void:
	_fix_stuck_mouse()
	# вернуть управление камерой
	if cam:
		cam.cancel_drag()
		_cam_set_drag(true)

func _on_end_day_confirmed() -> void:
	var candidate := "d_end_of_day_%d" % GameManager.day
	var dlg_id := (candidate if GameManager.dialog_exists(candidate) else "d_end_of_day")

	if GameManager.has_signal("dialog_finished"):
		GameManager.dialog_finished.connect(func(id, _r):
			if id == dlg_id:
				_finish_day_flow()
				_fix_stuck_mouse()
				# ← ВОТ ЭТО ВЕРНЁТ СКРОЛЛ ПОСЛЕ ПОДТВЕРЖДЕНИЯ
				if cam:
					cam.cancel_drag()
					_cam_set_drag(true)
		, CONNECT_ONE_SHOT)
	else:
		_finish_day_flow()
		_fix_stuck_mouse()
		if cam:
			cam.cancel_drag()
			_cam_set_drag(true)

	GameManager.play_dialog(dlg_id, self)


func _finish_day_flow() -> void:
	# Победа?
	if GameManager.check_victory_and_maybe_quit(self):
		return
	# Заканчиваем день
	GameManager.end_day()
	_apply_phase_visuals()

func _fix_stuck_mouse() -> void:
	var vp := get_viewport()
	if vp:
		vp.set_input_as_handled()
		vp.gui_release_focus()
	if cam:
		cam.cancel_drag()

	await get_tree().process_frame  # дождаться, пока окно реально спрячется

	var pos := (vp.get_mouse_position() if vp else Vector2.ZERO)
	for b in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		var ev := InputEventMouseButton.new()
		ev.button_index = b
		ev.pressed = false
		ev.position = pos
		Input.parse_input_event(ev)



func _apply_phase_visuals() -> void:
	var col := Color(1, 0.95, 0.8) # утро
	match GameManager.current_phase:
		0: col = Color(1, 0.95, 0.8)
		1: col = Color(1, 1, 1)
		2: col = Color(1, 0.8, 0.6)
		3: col = Color(0.2, 0.2, 0.4)
	$Camera2D/CanvasModulate.color = col

	var label := get_node("/root/Mansion/UI/PanelDay/DayLabel")
	label.text = "День: %d %s" % [GameManager.day, GameManager.phase_names[GameManager.current_phase]]


func _maybe_play_intro() -> void:
	if not GameManager.dialog_seen("d_intro_berit_sally"):
		GameManager.play_dialog("d_intro_berit_sally")
	
func _on_manage_button_pressed() -> void:
	_cam_set_drag(false)
	cam.cancel_drag()
	manage_menu.call("open_centered")

func _on_management_menu_popup_hide() -> void:
	_cam_set_drag(true)
	cam.cancel_drag()

func _on_dialog_finished(id: String, res: Dictionary) -> void:
	if id != "d_intro_berit_sally":
		return

func _on_room_2_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:   if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		print("Комната 2 нажата")
		if GameManager.timeline_used_today:
			GameManager.toast("Сегодня вы уже занимались делами.")
		else:
			_open_room2_menu(event.position)


func _on_room_3_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		print("Комната 3 нажата")
		if event is InputEventMouseButton and event.pressed:
			# Если уже вечер/ночь или таймлайн пройден — можно завершать день
			end_day_confirm.dialog_text = "Закончить день и перейти к утру?"
			end_day_confirm.popup_centered_ratio(0.25)
			if cam:
				cam.cancel_drag()
				_cam_set_drag(false)
			_start_input_quarantine(0.25) 

func _release_mouse_buttons() -> void:
	var pos := get_viewport().get_mouse_position()
	for b in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		if Input.is_mouse_button_pressed(b):
			var ev := InputEventMouseButton.new()
			ev.button_index = b
			ev.pressed = false
			ev.position = pos
			Input.parse_input_event(ev)
			
func _on_button_exit_pressed() -> void:
	var panel := $Room1PopupPanel
	if panel.get_meta("closing", false):
		return
	panel.set_meta("closing", true)

	$Camera2D.cancel_drag()               # ← на всякий

	var tw := create_tween()
	tw.tween_property(panel, "size", Vector2i(0, 0), 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(Callable(panel, "hide"))

func _on_NextPhaseButton_pressed():
	GameManager.current_phase += 1
	if GameManager.current_phase > 3:
		GameManager.current_phase = 0
		GameManager.day += 1
	match GameManager.current_phase:
		0: get_node("/root/Mansion/Camera2D/CanvasModulate").color = Color(1, 0.95, 0.8)    # утро
		1: get_node("/root/Mansion/Camera2D/CanvasModulate").color = Color(1, 1, 1)         # день
		2: get_node("/root/Mansion/Camera2D/CanvasModulate").color = Color(1, 0.8, 0.6)     # вечер
		3: get_node("/root/Mansion/Camera2D/CanvasModulate").color = Color(0.2, 0.2, 0.4)   # ночь (темный синий)  # переходим на следующий день после ночи
	get_node("/root/Mansion/UI/PanelDay/DayLabel").text = "День: %d %s" % [GameManager.day, GameManager.phase_names[GameManager.current_phase]] # Replace with function body.
	update_room_states()
	
func update_room_states():
	var rooms := get_tree().get_nodes_in_group("rooms")
	for room in rooms:
		if room.has_node("Lamp"):
			var lamp := room.get_node("Lamp") as DirectionalLight2D
			if GameManager.current_phase == 3:
				lamp.visible = true
			else:
				lamp.visible = false

func _on_room_1_popup_panel_popup_hide() -> void:
	$Room1PopupPanel.set_meta("closing", false)
	$Camera2D.set_drag_enabled(true)      # ← ВКЛ. drag обратно


func _unhandled_input(event: InputEvent) -> void:
	# Глушим любые мышиные события, пока идёт карантин
	if _input_quarantine_t > 0.0 and (event is InputEventMouseMotion or event is InputEventMouseButton):
		get_viewport().set_input_as_handled()
		return

	# Закрытие по ESC (тоже с карантином)
	#if event.is_action_pressed("ui_cancel") and $Room1PopupPanel.visible:
		#_start_input_quarantine(0.30) # длина твоей анимации 0.25с + запас
		#_on_button_exit_pressed()
		#get_viewport().set_input_as_handled()
