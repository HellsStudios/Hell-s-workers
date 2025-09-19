# stop_bg.gd
extends Control

@export var character_path: NodePath
var character: Node = null

func _ready() -> void:
	if character_path != NodePath():
		character = get_node(character_path)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		get_viewport().set_input_as_handled()  # гасим фон
		if character and character.has_method("handle_click"):
			character.handle_click()
