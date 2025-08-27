extends Control
signal finished(result: Dictionary)

var _running := false
var _t := 0.0
var _dur := 1.0
var _segments: Array = []   # [[from, to], ...] в долях 0..1
var _clicked := false

@export var COLOR_BG        := Color(0, 0, 0, 0.35)
@export var COLOR_SEG_GOOD  := Color(0.30, 1.00, 0.30, 0.55)  # зелёная «успех»
@export var COLOR_SEG_PERF  := Color(1.00, 0.90, 0.20, 0.90)  # ЖЁЛТАЯ «perfect»
@export var COLOR_CURSOR    := Color(1, 1, 1, 1)

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)
	focus_mode = Control.FOCUS_ALL

func start(duration: float, segments: Array) -> void:
	_dur = max(0.1, duration)
	_segments = segments if segments is Array else []
	_t = 0.0
	_clicked = false
	_running = true
	visible = true
	set_process(true)
	queue_redraw()
	grab_focus()

func _process(dt: float) -> void:
	if not _running: return
	_t += dt
	if _t >= _dur:
		_finish(false, false)

	queue_redraw()

func _gui_input(ev: InputEvent) -> void:
	if not _running: return
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		if _clicked: return
		_clicked = true
		var x = clamp(_t / _dur, 0.0, 1.0)
		var success := false
		var perfect := false
		for seg in _segments:
			if seg.size() >= 2:
				var a := float(seg[0]); var b := float(seg[1])
				if x >= a and x <= b:
					success = true
					var mid := (a + b) * 0.5
					var half := (b - a) * 0.5
					# «идеал» — центральные 30% сегмента
					if abs(x - mid) <= half * 0.30:
						perfect = true
					break
		_finish(success, perfect)

func _finish(success: bool, perfect: bool) -> void:
	if not _running: return
	_running = false
	set_process(false)
	visible = false
	emit_signal("finished", {"success": success, "perfect": perfect, "t": _t})

func _draw() -> void:
	# геометрия бара
	var pad := 24.0
	var w  = max(200.0, size.x - pad * 2.0)
	var h  := 16.0
	var ox = (size.x - w) * 0.5
	var oy := size.y * 0.75

	# трек / фон
	draw_rect(Rect2(Vector2(ox, oy), Vector2(w, h)), COLOR_BG, true)

	# сегменты: зелёная зона успеха + жёлтая центральная perfect-зона (30%)
	for seg in _segments:
		if seg.size() >= 2:
			var a = clamp(float(seg[0]), 0.0, 1.0)
			var b = clamp(float(seg[1]), 0.0, 1.0)

			# success (зелёная)
			var sx = ox + a * w
			var sw = max(2.0, (b - a) * w)
			draw_rect(Rect2(Vector2(sx, oy), Vector2(sw, h)), COLOR_SEG_GOOD, true)

			# perfect (жёлтая, центральные 30%)
			var mid  = (a + b) * 0.5
			var half = (b - a) * 0.5
			var perf_half = half * 0.30
			var pa = clamp(mid - perf_half, 0.0, 1.0)
			var pb = clamp(mid + perf_half, 0.0, 1.0)
			var px = ox + pa * w
			var pw = max(2.0, (pb - pa) * w)
			# чуть выше и толще, чтобы читалось поверх зелёного
			var oy2 := oy - h * 0.10
			var h2  := h * 1.20
			draw_rect(Rect2(Vector2(px, oy2), Vector2(pw, h2)), COLOR_SEG_PERF, true)

	# «стрелка» курсора
	if _running:
		var x = ox + clamp(_t / _dur, 0.0, 1.0) * w
		draw_line(Vector2(x, oy - 8), Vector2(x, oy + h + 8), COLOR_CURSOR, 2.0)
