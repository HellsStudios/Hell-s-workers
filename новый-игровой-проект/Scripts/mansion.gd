extends Node2D

#var current_day : int = 1  # текущий день, начинаем с 1

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



func _on_room_1_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		$Camera2D.set_drag_enabled(false)
		get_viewport().set_input_as_handled()

		var panel := $Room1PopupPanel
		# переводим мировые координаты в экранные (как у вас):
		var scr_pos = ($Camera2D/Room1.global_position - get_viewport().get_canvas_transform().origin).floor()
		panel.open_from(scr_pos, 0.30)

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

func _ready() -> void:
	set_process(true)  # нужно для таймового логирования
	# ... остальное как у тебя было ...
	GameManager.add_or_update_quest("q_intro", "Первый день", "Осмотрись в поместье.")
	GameManager.add_or_update_quest("q_bag", "Собери сумку", "Переложи 3 предмета герою.")
	GameManager.add_codex_entry("Печать", "Официальная печать Берита — тяжёлая.")
	var got := GameManager.claim_completed_quest_rewards()
	if got.size() > 0:
		Toasts.ok("Вы получили награду за квест(ы): " + ", ".join(got))
	# чтобы увидеть «серым»:
	# GameManager.set_quest_completed("q_intro", true)
	
func _on_manage_button_pressed() -> void:
	cam.set_drag_enabled(false)
	cam.cancel_drag()
	manage_menu.call("open_centered")

func _on_management_menu_popup_hide() -> void:
	cam.set_drag_enabled(true)
	cam.cancel_drag()



func _on_room_2_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:   if event is InputEventMouseButton and event.pressed:
		print("Комната 2 нажата")
		_on_back_to_timeline_pressed()


func _on_room_3_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:    if event is InputEventMouseButton and event.pressed:
		print("Комната 3 нажата")

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
	if event.is_action_pressed("ui_cancel") and $Room1PopupPanel.visible:
		_start_input_quarantine(0.30) # длина твоей анимации 0.25с + запас
		_on_button_exit_pressed()
		get_viewport().set_input_as_handled()
