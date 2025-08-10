extends Control

@export var target: Node2D
@export var y_offset := -64.0

@onready var bar: TextureProgressBar = $Bar            # <- путь к твоей полоске
@onready var text_label: Label = $Text          # <- или, например: $"HBox/Value"

func _ready() -> void:
	if bar == null: push_error("HealthBar: узел $Bar не найден")
	if text_label == null: push_error("HealthBar: узел $Text не найден")

func _process(_dt):
	if target == null or !is_instance_valid(target):
		queue_free(); return

	# позиционирование над целью
	var cam := get_viewport().get_camera_2d()
	var world_pos := target.global_position + Vector2(0, y_offset)
	var screen_pos = cam.unproject_position(world_pos) if cam else world_pos
	position = screen_pos - size * 0.5

	# значения
	var max_hp = max(1, int(target.max_health))
	var hp     = clamp(int(target.health), 0, max_hp)
	if bar:
		bar.max_value = max_hp
		bar.value     = hp
	if text_label:
		text_label.text = "%d / %d" % [hp, max_hp]
