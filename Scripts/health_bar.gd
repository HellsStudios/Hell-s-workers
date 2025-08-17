extends Control

@export var target: Node2D
@export var y_offset := -64.0
@export var x_offset := 0.0

@onready var bar: TextureProgressBar = $Bar
@onready var text_label: Label       = $Text
@onready var effects_box: Control    = $Effects

@export var EFFECT_ICON_DIR := "res://Assets/icons/effects"
@export var EFFECT_ICON_FALLBACK := "res://Assets/icons/effects/_default.png"

func _ready() -> void:
	if bar == null: push_error("HealthBar: узел $Bar не найден")
	if text_label == null: push_error("HealthBar: узел $Text не найден")
	if effects_box == null: push_error("HealthBar: узел $Effects не найден")
	_update_all()

func set_target(t: Node2D) -> void:
	target = t
	_update_all()

func _process(_dt: float) -> void:
	if target == null or not is_instance_valid(target):
		queue_free()
		return

	# --- позиционирование над целью (как в вашей старой версии) ---
	var cam := get_viewport().get_camera_2d()
	var world_pos := target.global_position + Vector2(0, y_offset)
	var screen_pos = cam.unproject_position(world_pos) if cam else world_pos
	position = screen_pos - size * 0.5 + Vector2(x_offset, 0)

	_update_stats()
	_refresh_effect_icons()

# ----- значения -----
func _update_stats() -> void:
	var max_hp = max(1, int(target.max_health))
	var hp     = clamp(int(target.health), 0, max_hp)
	if bar:
		bar.max_value = max_hp
		bar.value     = hp
	if text_label:
		text_label.text = "%d / %d" % [hp, max_hp]

# ----- иконки эффектов -----
func _refresh_effect_icons() -> void:
	if effects_box == null: return

	# простой ресинк: очистить и собрать заново
	for c in effects_box.get_children():
		c.queue_free()

	if not target.has_method("get_effects"):
		return

	var arr: Array = target.call("get_effects")
	for ex in arr:
		var id := String(ex.get("id",""))
		if id == "":
			continue

		var path := "%s/%s.png" % [EFFECT_ICON_DIR, id]
		var tex: Texture2D = null
		if ResourceLoader.exists(path):
			tex = load(path)
		elif ResourceLoader.exists(EFFECT_ICON_FALLBACK):
			tex = load(EFFECT_ICON_FALLBACK)

		var tr := TextureRect.new()
		tr.texture = tex
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.custom_minimum_size = Vector2(18, 18)
		tr.tooltip_text = _effect_tooltip(ex)
		effects_box.add_child(tr)

		# маленькая циферка длительности
		var dur := int(ex.get("duration", -1))
		if dur > 0:
			var lab := Label.new()
			lab.text = str(dur)
			lab.modulate = Color(1,1,1,0.9)
			lab.add_theme_font_size_override("font_size", 10)
			lab.position = Vector2(10, 8)
			tr.add_child(lab)

func _effect_tooltip(ex: Dictionary) -> String:
	var name := String(ex.get("name", String(ex.get("id",""))))
	var dur  := int(ex.get("duration", -1))
	return "%s (∞)" % name if dur == -1 else "%s (%d ход.)" % [name, dur]

func _update_all() -> void:
	if target == null or not is_instance_valid(target):
		return
	_update_stats()
	_refresh_effect_icons()
