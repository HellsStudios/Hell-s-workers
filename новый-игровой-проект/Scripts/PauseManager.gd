extends Node
class_name Pause

const MENU_SCN := preload("res://Scenes/pause_menu.tscn")

enum Mode { GENERIC, BATTLE, TIMELINE, MANSION }

var default_mode: int = Mode.GENERIC

func set_mode(mode: int) -> void:
	# старый стиль: сначала set_mode(), потом open()/toggle()
	_mode = mode
	default_mode = mode

func configure(mode: int) -> void:
	# если где-то вызывалось configure()
	set_mode(mode)

func open_with_mode(mode: int) -> void:
	# удобный алиас
	open(mode)

var _layer: CanvasLayer
var _menu: Control
var _mode: int = Mode.GENERIC

func is_open() -> bool:
	return is_instance_valid(_menu)

func toggle(mode: int = Mode.GENERIC) -> void:
	if is_open(): close()
	else: open(mode)

func open(mode: int = -1) -> void:
	if is_open(): return
	if mode == -1:
		mode = default_mode          # <<< вот это главное
	_mode = mode

	if _layer == null:
		_layer = CanvasLayer.new()
		_layer.name = "PauseLayer"
		_layer.layer = 128
		_layer.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
		get_tree().root.add_child(_layer)

	_menu = MENU_SCN.instantiate()
	_menu.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	_layer.add_child(_menu)

	# передать режим внутрь меню (чтобы тексты/логика подстроились)
	if _menu.has_method("configure"):
		_menu.call("configure", _mode)

	_menu.resume_requested.connect(close, CONNECT_ONE_SHOT)
	_menu.exit_requested.connect(_on_exit, CONNECT_ONE_SHOT)

	await get_tree().process_frame
	get_tree().paused = true
	_menu.call_deferred("grab_default_focus")

func close() -> void:
	if not is_open(): return
	get_tree().paused = false
	_menu.queue_free()
	_menu = null

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	var scene := get_tree().current_scene
	var mode := Mode.MANSION
	if scene:
		var nm := scene.name.to_lower()
		if nm == "timeline":
			mode = Mode.TIMELINE
		elif nm == "battle" or scene.is_in_group("scene:battle"):
			mode = Mode.BATTLE
	open(mode)

func _on_exit() -> void:
	# 1) всегда прибираем окно паузы (UI), чтобы ничего не висело сверху
	if is_open():
		close()  # внутри снимется paused и меню удалится

	# 2) выполняем действие по режиму
	match _mode:
		Mode.BATTLE:
			if GameManager.has_method("battle_defeat"):
				GameManager.battle_defeat()
			else:
				get_tree().quit()
		Mode.TIMELINE:
			if GameManager.has_method("return_to_mansion_keep_timeline"):
				GameManager.return_to_mansion_keep_timeline()
			else:
				get_tree().quit()
		_:
			get_tree().quit()
