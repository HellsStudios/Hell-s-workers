extends Camera2D

# --- Размер рабочей области (в мировых координатах)
@export var world_width: float  = 2750.0
@export var world_height: float = 1200.0
# Левый-верхний мир совпадает с (0,0); позиция камеры у тебя уже «внутрь» двигается в минус по X/Y.

# --- Зум
@export var zoom_min: float = 1.0
@export var zoom_max: float = 2.5
@export var zoom_step: float = 0.1
@export var zoom_to_mouse: bool = false  # если захочешь «к курсору», поставь true

# --- Лимиты (были const, теперь пересчитываемые var)
var LIMIT_LEFT:   float = 0.0     # минимально допустимая позиция.x (обычно отрицательная величина)
var LIMIT_RIGHT:  float = 0.0     # максимум по X (0 — левый край мира)
var LIMIT_TOP:    float = 0.0     # минимум по Y (обычно отрицательная величина)
var LIMIT_BOTTOM: float = 0.0     # максимум по Y (0 — верхний край мира)

# --- Драг (как у тебя)
var dragging: bool = false
var last_mouse_pos: Vector2 = Vector2.ZERO
var drag_enabled: bool = true

func set_drag_enabled(v: bool) -> void:
	drag_enabled = v
	if not v:
		dragging = false

func cancel_drag() -> void:
	dragging = false

func _ready() -> void:
	_recompute_limits()  # стартовые лимиты под текущий зум и размер окна

func _unhandled_input(event: InputEvent) -> void:
	# --- Зум колесиком — отдельно и всегда
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_handle_wheel_zoom(event)
			get_viewport().set_input_as_handled()
			return

	if not drag_enabled:
		return

	# --- ЛКМ: включаем/выключаем drag (без изменений)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			dragging = true
			last_mouse_pos = event.position
		else:
			dragging = false

	# --- Двигаем камеру, пока тянем (как было у тебя)
	elif event is InputEventMouseMotion and dragging:
		var delta: Vector2 = last_mouse_pos - event.position
		position -= delta
		_clamp_to_limits()
		last_mouse_pos = event.position
		get_viewport().set_input_as_handled()

# --------------------------
# ЗУМ колесиком + коррекция позиции и лимитов
# --------------------------
func _handle_wheel_zoom(event: InputEventMouseButton) -> void:
	var before_mouse_world := get_global_mouse_position()

	var factor := 1.0
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		factor = 1.0 + zoom_step
	else:
		factor = 1.0 - zoom_step

	var target = clamp(zoom.x * factor, zoom_min, zoom_max)
	zoom = Vector2(target, target)

	if zoom_to_mouse:
		# Делаем «зум к курсору»: сохраняем мировую точку под курсором
		var after_mouse_world := get_global_mouse_position()
		global_position += before_mouse_world - after_mouse_world

	# Пересчитываем лимиты под новый зум/размер видимой области
	_recompute_limits()
	# И гарантируем, что камера осталась в пределах
	_clamp_to_limits()

# --------------------------
# Пересчёт лимитов под ТЕКУЩИЙ зум и размер окна
# --------------------------
func _recompute_limits() -> void:
	var vp := get_viewport_rect().size            # размер окна в пикселях (например, 1920x1080)
	var vis_w := vp.x / zoom.x                    # сколько мира влезает по X при текущем зуме
	var vis_h := vp.y / zoom.y                    # и по Y

	# Максимально возможный сдвиг "левого-верхнего" края внутрь мира
	var max_scroll_x = max(0.0, world_width  - vis_w)   # 0 если экран шире мира
	var max_scroll_y = max(0.0, world_height - vis_h)   # 0 если экран выше мира

	# ТВОЯ система координат лимитов:
	#   RIGHT/BOTTOM = 0 (совпадение с левым/верхним краем мира),
	#   LEFT/TOP = -максимальный_сдвиг (отрицательные значения)
	LIMIT_RIGHT  = 0.0
	LIMIT_BOTTOM = 0.0
	LIMIT_LEFT   = -max_scroll_x
	LIMIT_TOP    = -max_scroll_y
	# Пример: при world 2750x1200 и zoom=1, vp=1920x1080:
	#   vis_w=1920, vis_h=1080, max_scroll_x=830, max_scroll_y=120
	#   => X: [-830 .. 0], Y: [-120 .. 0] — ровно как ты настроил вручную.

# --------------------------
# Кламп позиции по текущим лимитам (как у тебя)
# --------------------------
func _clamp_to_limits() -> void:
	position.x = clamp(position.x, LIMIT_LEFT,  LIMIT_RIGHT)
	position.y = clamp(position.y, LIMIT_TOP,   LIMIT_BOTTOM)
