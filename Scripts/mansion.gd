extends Node2D

#var current_day : int = 1  # текущий день, начинаем с 1

func _on_room_1_input_event(viewport:Node, event:InputEvent, shape_idx:int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:

		var panel := get_node("/root/Mansion/Room1PopupPanel")                # убедитесь, что путь верный!
		panel.position = get_node("/root/Mansion/Camera2D/Room1").global_position - get_viewport().get_canvas_transform().origin
		panel.size = Vector2i(0, 0)
		panel.visible = true

		var tw := create_tween()
		tw.tween_property(panel,"size",Vector2i(220, 140),0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_room_2_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:   if event is InputEventMouseButton and event.pressed:
		print("Комната 2 нажата")


func _on_room_3_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:    if event is InputEventMouseButton and event.pressed:
		print("Комната 3 нажата")


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
	$Room1PopupPanel.set_meta("closing", false) # Replace with function body.


func _on_button_exit_pressed() -> void:
	var panel := get_node("/root/Mansion/Room1PopupPanel")   
	# если уже запущено закрытие — не стартуем повторно
	if panel.get_meta("closing", false):
		return
	panel.set_meta("closing", true)

	# обратная анимация размера
	var tw := create_tween()
	tw.tween_property(panel, "size", Vector2i(0, 0), 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)

	# когда Tween закончится → hide()   (popup_hide стрельнёт сам)
	tw.tween_callback(Callable(panel, "hide")) # Replace with function body.
	
