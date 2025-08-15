extends Control
signal finished(result: Dictionary)  # {type:"dodge"/"block", grade:"fail"/"good"/"perfect"}

var _running := false
var _t := 0.0
var _dur := 1.0
var _segments: Array = []
var _mode := "single"                 # "single" / "aoe"
var _dodge_win := 0.10
var _block_win := 0.16

@onready var btn_dodge := Button.new()
@onready var btn_block := Button.new()

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)
	focus_mode = Control.FOCUS_ALL

	# Кнопки
	btn_dodge.text = "Уклон (ЛКМ)"
	btn_block.text = "Блок (ПКМ)"
	add_child(btn_dodge)
	add_child(btn_block)
	btn_dodge.visible = false
	btn_block.visible = false
	btn_dodge.pressed.connect(func(): _pick("dodge"))
	btn_block.pressed.connect(func(): _pick("block"))

func start(duration: float, segments: Array, dodge_window: float, block_window: float, mode: String) -> void:
	_dur = max(0.15, duration)
	_segments = []
	for seg in segments:
		if typeof(seg) == TYPE_ARRAY and seg.size() >= 2:
			_segments.append([float(seg[0]), float(seg[1])])
		elif typeof(seg) == TYPE_DICTIONARY:
			var a := float(seg.get("start", 0.45))
			var b := float(seg.get("end",   0.55))
			_segments.append([a, b])
	if _segments.size() == 0:
		_segments = [[0.45, 0.55]]

	_dodge_win = max(0.0, dodge_window)
	_block_win = max(0.0, block_window)
	_mode = mode

	_t = 0.0
	_running = true
	visible = true
	set_process(true)
	queue_redraw()
	grab_focus()

	# Размещение кнопок
	var w := size.x
	btn_dodge.position = Vector2(w * 0.33 - 70, size.y * 0.70 + 30)
	btn_block.position = Vector2(w * 0.66 - 50, size.y * 0.70 + 30)
	btn_dodge.visible = true
	btn_block.visible = true

func _process(dt: float) -> void:
	if not _running: return
	_t += dt
	if _t >= _dur:
		_finish({"type":"none","grade":"fail"})
	queue_redraw()

func _gui_input(ev: InputEvent) -> void:
	if not _running: return
	if ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_LEFT:
			_pick("dodge")
		elif ev.button_index == MOUSE_BUTTON_RIGHT:
			_pick("block")

func _pick(kind: String) -> void:
	if not _running: return
	var x = clamp(_t / _dur, 0.0, 1.0)

	var win := _dodge_win
	if kind == "block":
		win = _block_win

	var success := false
	var perfect := false

	for seg in _segments:
		var a = clamp(float(seg[0]) - win, 0.0, 1.0)
		var b = clamp(float(seg[1]) + win, 0.0, 1.0)
		if x >= a and x <= b:
			success = true
			var mid := (float(seg[0]) + float(seg[1])) * 0.5
			var half := (float(seg[1]) - float(seg[0])) * 0.5
			if abs(x - mid) <= half * 0.30:
				perfect = true
			break

	var grade := "fail"
	if success:
		grade = "perfect" if perfect else "good"
	_finish({"type": kind, "grade": grade})

func _finish(res: Dictionary) -> void:
	if not _running: return
	_running = false
	set_process(false)
	visible = false
	btn_dodge.visible = false
	btn_block.visible = false
	emit_signal("finished", res)

func _draw() -> void:
	var pad := 24.0
	var w = max(200.0, size.x - pad * 2.0)
	var h := 16.0
	var ox = (size.x - w) * 0.5
	var oy := size.y * 0.70

	# трек
	draw_rect(Rect2(Vector2(ox, oy), Vector2(w, h)), Color(0, 0, 0, 0.65))

	# для каждого сегмента рисуем ДВА окна — BLOCK (синий, шире) и DODGE (зелёный, уже)
	for seg in _segments:
		if seg.size() < 2:
			continue
		var a = clamp(float(seg[0]), 0.0, 1.0)
		var b = clamp(float(seg[1]), 0.0, 1.0)

		# BLOCK окно: [a - _block_win ; b + _block_win]
		var ax_b = clamp(a - _block_win, 0.0, 1.0)
		var bx_b = clamp(b + _block_win, 0.0, 1.0)
		var x1 = ox + ax_b * w
		var w1 = max(2.0, (bx_b - ax_b) * w)
		draw_rect(Rect2(Vector2(x1, oy), Vector2(w1, h)), Color(0.25, 0.55, 1.0, 0.45), true)

		# DODGE окно: [a - _dodge_win ; b + _dodge_win] (ужe, сверху)
		var ax_d = clamp(a - _dodge_win, 0.0, 1.0)
		var bx_d = clamp(b + _dodge_win, 0.0, 1.0)
		var x2 = ox + ax_d * w
		var w2 = max(2.0, (bx_d - ax_d) * w)
		var oy2 := oy - h * 0.18
		var h2 := h * 1.36
		draw_rect(Rect2(Vector2(x2, oy2), Vector2(w2, h2)), Color(0.25, 0.9, 0.25, 0.70), true)

	# «стрелка»
	if _running:
		var x = ox + clamp(_t / _dur, 0.0, 1.0) * w
		draw_line(Vector2(x, oy - 10), Vector2(x, oy + h + 10), Color(1, 1, 1, 0.95), 2.0)
