extends Button
class_name PotCard

signal clicked(index:int)

var index:int = -1
var title := ""
var subtitle := ""
var health := 100
var stressed := 0
var water := 50
var nutrients := 50
var is_empty := true
var harvest_ready := false

func _ready() -> void:
	_toggle_ui()

func setup(idx:int, data:Dictionary) -> void:
	index = idx
	title = String(data.get("title","Пусто"))
	subtitle = String(data.get("subtitle",""))
	health = int(data.get("health",100))
	stressed = int(data.get("stress",0))
	water = int(data.get("water",50))
	nutrients = int(data.get("nutrients",50))
	is_empty = bool(data.get("empty", true))
	harvest_ready = bool(data.get("harvest_ready", false))
	_toggle_ui()

func _toggle_ui() -> void:
	# текст
	if title == "":
		text = "Пусто"
	else:
		text = title

	# тултип
	var tip := ""
	if subtitle != "":
		tip += subtitle + "\n"
	tip += "Здоровье: %d | Стресс: %d\nВлага: %d | Питание: %d" % [health, stressed, water, nutrients]
	if harvest_ready:
		tip += "\nГОТОВ К СБОРУ!"
	tooltip_text = tip

	# поведение/стили
	disabled = false
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(180, 64)
	add_theme_font_size_override("font_size", 14)
	add_theme_color_override("font_color", Color.WHITE)

	var sb := StyleBoxFlat.new()
	if harvest_ready:
		sb.bg_color = Color(0.18,0.28,0.18,0.95)
	else:
		if is_empty:
			sb.bg_color = Color(0.12,0.12,0.14,0.95)
		else:
			sb.bg_color = Color(0.16,0.18,0.22,0.95)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	add_theme_stylebox_override("normal", sb)

func _pressed() -> void:
	emit_signal("clicked", index)
