# res://UI/Toast.gd
extends CanvasLayer
class_name Toast

var _panel: PanelContainer
var _label: RichTextLabel
var _busy := false
var _queue: Array = []

func _ready() -> void:
	# всегда поверх
	layer = 100
	# панель
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	# отступы
	var m := MarginContainer.new()
	for k in ["left","top","right","bottom"]:
		m.add_theme_constant_override("margin_%s" % k, 12)
	_panel.add_child(m)

	# текст
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	m.add_child(_label)

# Вместо show(...)
func push(msg: String, where: String="top", secs: float=1.8) -> void:
	_queue.append({"msg": msg, "where": where, "secs": secs})
	if not _busy:
		_play_next()

# Опционально: алиас, если где-то уже звали Toast.show(...)
func show_toast(msg: String, where: String="top", secs: float=1.8) -> void:
	push(msg, where, secs)

func ok(msg: String, secs:=1.8, where:="top") -> void:
	push("[color=lime]%s[/color]" % msg, where, secs)

func warn(msg: String, secs:=2.2, where:="top") -> void:
	push("[color=yellow]%s[/color]" % msg, where, secs)

func err(msg: String, secs:=2.5, where:="top") -> void:
	push("[color=salmon]%s[/color]" % msg, where, secs)


func _play_next() -> void:
	if _queue.is_empty():
		_busy = false
		return
	_busy = true
	var it: Dictionary = _queue.pop_front()
	_label.text = it["msg"]

	# размеры и позиция
	var vs := get_viewport().get_visible_rect().size
	_panel.size = Vector2(min(540.0, vs.x - 80.0), 0.0)
	_panel.position = Vector2((vs.x - _panel.size.x)/2.0, _y_for(String(it["where"]), vs))

	_panel.modulate.a = 0.0
	_panel.visible = true

	var tw := create_tween()
	tw.tween_property(_panel, "modulate:a", 1.0, 0.15)
	tw.tween_interval(float(it["secs"]))
	tw.tween_property(_panel, "modulate:a", 0.0, 0.25)
	tw.tween_callback(func():
		_panel.visible = false
		_play_next()
	)

func _y_for(where: String, vs: Vector2) -> float:
	match where:
		"center": return (vs.y - _panel.size.y) / 2.0
		"bottom": return vs.y - _panel.size.y - 28.0
		_:        return 24.0   # top
