extends Node2D   # или Node, если у вас без координат
var _current_visual_order: Array[Node2D] = []  # как иконки реально стоят сейчас
const _SLOT_W := ICON_W + ICON_GAP
const MAX_TOTAL_ANIM := 0.30
const MIN_STEP_DUR   := 0.05
@export var APPROACH_X := 120.0     # насколько ЛЕВЕЕ цели становиться
@export var APPROACH_Y := 0.0      # вертикальный сдвиг от Y цели (если нужно)
@export var LOCK_Y_TO_TARGET := true
@export var AOE_CENTER_X_OFFSET := 600.0   # подстройка точки в центре по X
@export var AOE_CENTER_Y_OFFSET := -40.0   # подстройка точки в центре по Y
var _target_overlay: Control = null
var _is_acting := false
# Таргет-пикер
var _pick_mode := false
var _pick_btns: Array[Button] = []
var _pick_map : Dictionary = {}   # Button -> Node2D (цель)
var _pending  : Dictionary = {}   # {type:"attack"/"skill_single", actor:Node2D, data:Dictionary}
@onready var qte_bar := $UI/QTEBar
@onready var top_ui := $UI/TopUI
@export var CINE_ZOOM := 1.45    # во сколько раз «приблизить»
@export var CINE_TIME := 0.22    # длительность твина
@export var PICK_BTN_SIZE   := Vector2(96, 96)
@export var PICK_BTN_OFFSET := Vector2(0, -36)   # смещение кнопки над врагом
# ────────── ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ СЦЕНЫ БОЯ ──────────
@onready var world_ui  := $UI/WorldUI
@onready var party_hud := $UI/PartyHUD
const HEALTHBAR_SCN := preload("res://Scenes/health_bar.tscn")
var heroes:  Array[Node2D] = []   # список героев
var enemies: Array[Node2D] = []   # список врагов
const TURN_THRESHOLD := 1000.0
var last_actor: Node2D = null   # кто реально ходит в этот момент
var RECALC_SPEED_EACH_ROUND := true
const ICON_W := 48
const ICON_GAP := 16  # было 8, сделал крупнее
var actors: Array[Node2D] = []   # ← общий список участников
const ICON_SCN := preload("res://scenes/turn_icon.tscn")
const PLACEHOLDER := "res://Assets/icons/characters/placeholder.png"
var char_to_icon: Dictionary = {}  # character -> TextureRect
var turn_queue: Array = []        # очередь ходов               <── объявили!
var current_turn_index: int = 0   # номер активного бойца       <── объявили!
# ─────────────────────────────────────────────────────
var current_actor   : Node2D          # чей ход сейчас
@onready var action_panel := $UI/ActionPanel    # панель с кнопками (Атака / Умения / Предмет)
const CHAR_SCN := preload("res://Scenes/character.tscn")
@onready var hero_slots  := $Battlefield/HeroPositions
@onready var enemy_slots := $Battlefield/EnemyPositions
@onready var turn_panel := $UI/TopUI/TurnQueuePanel
var turn_icons: Array[TextureRect] = []
var enemy_bars: Dictionary = {}  # enemy -> bar
@export var world_camera_path: NodePath   # можно оставить пустым
@export var auto_create_camera := false   # если true, создадим Camera2D при отсутствии
@export var HB_OFFSET_Y := 88.0          # насколько выше головы ставить бар (в пикселях)
@export var HB_SCALE_WITH_ZOOM := true   # масштабировать ли бар при зуме
@export var HB_MIN_SCALE := 0.8
@export var HB_MAX_SCALE := 1.8

var _cam_saved := { "pos": Vector2.ZERO, "zoom": Vector2.ONE, "proc": Node.PROCESS_MODE_INHERIT, "smooth": false }
var _vp_saved_xform: Transform2D = Transform2D.IDENTITY

func _get_view_zoom() -> float:
	var cam := get_viewport().get_camera_2d()
	if cam:
		return cam.zoom.x              # Godot 4: >1 — крупнее
	# фолбэк: зум из canvas_transform (если камеры нет)
	return get_viewport().canvas_transform.get_scale().x

func _get_cam() -> Camera2D:
	# 1) явный путь
	if world_camera_path != NodePath():
		var c := get_node_or_null(world_camera_path) as Camera2D
		if c: return c
	# 2) current камера вьюпорта
	var c2 := get_viewport().get_camera_2d()
	if c2: return c2
	# 3) из группы
	var list := get_tree().get_nodes_in_group("MainCamera")
	if list.size() > 0:
		return list[0] as Camera2D
	# 4) поиск по имени
	var c3 := get_tree().get_root().find_child("Camera2D", true, false) as Camera2D
	if c3: return c3
	# 5) по желанию — создать
	if auto_create_camera:
		var cam := Camera2D.new()
		cam.name = "AutoCamera2D"
		add_child(cam)
		cam.global_position = _guess_world_center()
		cam.make_current()
		return cam
	return null
	
func _guess_world_center() -> Vector2:
	var pts: Array[Vector2] = []
	for h in heroes: if is_instance_valid(h): pts.append(h.global_position)
	for e in enemies: if is_instance_valid(e): pts.append(e.global_position)
	if pts.is_empty(): return Vector2.ZERO
	var s := Vector2.ZERO
	for p in pts: s += p
	return s / pts.size()


func _cam_push_focus(at: Vector2, zoom_factor: float = CINE_ZOOM) -> void:
	var cam := _get_cam()
	if cam:
		_cam_saved.pos    = cam.global_position
		_cam_saved.zoom   = cam.zoom
		_cam_saved.proc   = cam.process_mode
		_cam_saved.smooth = cam.position_smoothing_enabled
		cam.process_mode = Node.PROCESS_MODE_DISABLED
		cam.position_smoothing_enabled = false
		var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(cam, "global_position", at, CINE_TIME)
		tw.parallel().tween_property(cam, "zoom", Vector2(zoom_factor, zoom_factor), CINE_TIME)
		await tw.finished
		return

	# Fallback без камеры: твиним Viewport.canvas_transform
	var vp := get_viewport()
	_vp_saved_xform = vp.canvas_transform

	var z := zoom_factor
	var center := vp.get_visible_rect().size * 0.5
	var target := Transform2D()
	target = target.scaled(Vector2(z, z))
	target.origin = center - at * z

	var from := vp.canvas_transform
	var tw2 := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw2.tween_method(func(t):
		vp.canvas_transform = from.interpolate_with(target, t)
	, 0.0, 1.0, CINE_TIME)
	await tw2.finished

func _cam_pop() -> void:
	var cam := _get_cam()
	if cam:
		var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(cam, "global_position", _cam_saved.pos, CINE_TIME)
		tw.parallel().tween_property(cam, "zoom", _cam_saved.zoom, CINE_TIME)
		await tw.finished
		cam.position_smoothing_enabled = _cam_saved.smooth
		cam.process_mode = _cam_saved.proc
		return

	# Fallback для Viewport.canvas_transform
	var vp := get_viewport()
	var from := vp.canvas_transform
	var to := _vp_saved_xform
	var tw2 := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw2.tween_method(func(t):
		vp.canvas_transform = from.interpolate_with(to, t)
	, 0.0, 1.0, CINE_TIME)
	await tw2.finished

# === Мировые координаты → экранные (для кнопок/панелей), работает в обоих режимах ===
func _world_to_screen(p: Vector2) -> Vector2:
	var cam := get_viewport().get_camera_2d()
	if cam:
		return cam.unproject_position(p)
	return get_viewport().canvas_transform * p
	
func _update_enemy_bars_positions() -> void:
	if enemy_bars.is_empty(): return
	var zoom := _get_view_zoom()
	var s := 1.0
	if HB_SCALE_WITH_ZOOM:
		s = clamp(zoom, HB_MIN_SCALE, HB_MAX_SCALE)

	for e in enemy_bars.keys():
		var bar: Control = enemy_bars[e]
		if not is_instance_valid(e) or not is_instance_valid(bar):
			if is_instance_valid(bar): bar.queue_free()
			enemy_bars.erase(e)
			continue

		var screen := _world_to_screen(e.global_position)
		# позиция — над целью; бар в UI, поэтому задаём глобальные экранные пиксели
		bar.scale = Vector2(s, s)
		bar.global_position = screen + Vector2(0, -HB_OFFSET_Y * s)
	
func _cine_self_test() -> void:
	var cam := _get_cam()
	if cam == null:
		return
	if not cam.is_current():
		print("[CINE] self-test: делаю make_current()")
		cam.make_current()
	print("[CINE] self-test: zoom(before)=", cam.zoom)
	cam.zoom = Vector2(1.8, 1.8)   # должно явно приблизить
	await get_tree().create_timer(0.25).timeout
	cam.zoom = Vector2.ONE
	print("[CINE] self-test: zoom(after)=", cam.zoom)

func _connect_hit_once(user: Node2D, cb: Callable) -> void:
	if user == null: return
	if not is_instance_valid(user): return
	if not user.has_signal("hit_event"): return
	# если уже был коннект — убираем
	if user.hit_event.is_connected(cb):
		user.hit_event.disconnect(cb)
	user.hit_event.connect(cb, CONNECT_ONE_SHOT)

func _disconnect_hit_if_any(user: Node2D, cb: Callable) -> void:
	if user == null: return
	if not is_instance_valid(user): return
	if not user.has_signal("hit_event"): return
	if user.hit_event.is_connected(cb):
		user.hit_event.disconnect(cb)
# ——— применить урон по всем живым врагам (общая точка для АОЕ) ———
func _apply_aoe_once(user: Node2D, damage: int, effects_to_targets: Array) -> void:
	for e in enemies:
		if is_instance_valid(e) and e.health > 0:
			_apply_melee_hit(e, damage, {"done": false}, effects_to_targets, user)
			
func _set_btns_highlight(btns: Array, on := false) -> void:
	for b in btns:
		if not is_instance_valid(b):
			continue

		if on:
			b.self_modulate = Color(1, 1, 1, 1.0)
			b.scale = Vector2(1.08, 1.08)
		else:
			b.self_modulate = Color(1, 1, 1, 0.6)
			b.scale = Vector2.ONE

func _enter_cinematic(targets: Array[Node2D]) -> void:
	# прячем лишний UI
	if action_panel: action_panel.hide()
	if top_ui: top_ui.visible = false
	if party_hud: party_hud.visible = false
	# приглушим прочих врагов
	for e in enemies:
		if not targets.has(e):
			if is_instance_valid(e):
				e.modulate = Color(1,1,1,0.35)

func _exit_cinematic() -> void:
	if top_ui: top_ui.visible = true
	if party_hud: party_hud.visible = true
	for e in enemies:
		if is_instance_valid(e):
			e.modulate = Color(1,1,1,1)
	
func _perform_with_qte(user: Node2D, targets: Array[Node2D], ability: Dictionary) -> void:
	# 1) подготовка позиций/камера/UI
	if targets.size() == 0: return
	var main_tgt: Node2D = targets[0]
	_enter_cinematic(targets)
	_update_enemy_bars_positions()
	await _cam_push_focus(main_tgt.global_position)

	# если физическая и одиночная — подбежали один раз вначале
	var typ := String(ability.get("type",""))
	var need_move := typ == "physical" and targets.size() == 1
	var mover: Node2D = user.get_node_or_null("MotionRoot") as Node2D
	if mover == null: mover = user
	var start_pos := mover.global_position
	if need_move:
		var hit_pos := _approach_point(user, main_tgt)
		_play_if_has(user.anim, "run")
		await create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)\
			.tween_property(mover, "global_position", hit_pos, 0.18).finished

	# 2) цикл по ступеням
	var qte = ability.get("qte", {})
	var steps: Array = qte.get("steps", [])
	var res_on_success = qte.get("on_success", {})
	var res_on_perfect = qte.get("on_perfect", {})
	var res_on_fail    = qte.get("on_fail", {})

	if steps.size() == 0:
		# нет QTE — старое поведение
		for t in targets:
			if is_instance_valid(t) and t.health > 0:
				_apply_melee_hit(t, int(ability.get("damage", user.attack)), {"done": false}, ability.get("effects_to_targets", []), user)
	else:
		for step in steps:
			var clip := "attack"
			if user.anim != null:
				if step.has("anim") and user.anim.has_animation(String(step["anim"])):
					clip = String(step["anim"])
				elif typ == "magic" and user.anim.has_animation("cast"):
					clip = "cast"
				elif user.anim.has_animation("skill"):
					clip = "skill"
			_play_if_has(user.anim, clip)

			# замедление
			var slow := float(step.get("slowmo", 0.0))
			var prev_scale := Engine.time_scale
			if slow > 0.0:
				Engine.time_scale = clamp(1.0 - slow, 0.05, 1.0)

			# запускаем QTE
			var dur := float(step.get("duration", 1.0))
			var segs = step.get("segments", [])
			qte_bar.start(dur, segs)
			var result: Dictionary = await qte_bar.finished

			# возвращаем тайм-скейл
			Engine.time_scale = prev_scale

			# модификаторы по результату
			var mod := {}
			if result.get("perfect", false) and not res_on_perfect.is_empty():
				mod = res_on_perfect
			elif result.get("success", false) and not res_on_success.is_empty():
				mod = res_on_success
			elif not res_on_fail.is_empty():
				mod = res_on_fail

			var dmg_base := int(ability.get("damage", user.attack))
			var mult := float(mod.get("damage_mult", 1.0))
			var dmg := int(round(dmg_base * mult))

			# бонус к длительности эффектов
			var dur_bonus := int(mod.get("duration_bonus", 0))
			var effs: Array = ability.get("effects_to_targets", [])
			if dur_bonus != 0 and effs.size() > 0:
				var patched: Array = []
				for e in effs:
					var d = e.duplicate(true)
					d["duration"] = int(d.get("duration", 0)) + dur_bonus
					patched.append(d)
				effs = patched

			# расширение области (опционально)
			var spread := String(mod.get("spread", "none"))
			var real_targets := targets
			if spread == "all_enemies":
				real_targets = []
				for e in enemies:
					if is_instance_valid(e) and e.health > 0: real_targets.append(e)
			elif spread == "all_allies":
				real_targets = []
				var pool := heroes if user.team == "hero" else enemies
				for a in pool:
					if is_instance_valid(a) and a.health > 0: real_targets.append(a)

			# применяем хит от этой ступени
			for t in real_targets:
				if is_instance_valid(t) and t.health > 0:
					_apply_melee_hit(t, dmg, {"done": false}, effs, user)

			# ждём конца клипа (не дольше разумного)
			await _wait_anim_end(user.anim, clip, 0.8)

	# 3) откат позиций/камеры/UI
	if need_move:
		await create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)\
			.tween_property(mover, "global_position", start_pos, 0.18).finished
	_play_if_has(user.anim, "idle")
	_update_enemy_bars_positions()
	await _cam_pop()
	_exit_cinematic()

func _spawn_enemy_bars():
	for bar in enemy_bars.values():
		if is_instance_valid(bar):
			bar.queue_free()
	enemy_bars.clear()
	_update_enemy_bars_positions()

	if world_ui and world_ui is Control:
		world_ui.visible = true
		world_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE

	for e in enemies:
		if not is_instance_valid(e): 
			continue
		var hb: Control = HEALTHBAR_SCN.instantiate()
		hb.z_as_relative = false
		hb.z_index = 200           # <= безопасно и выше оверлея
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE

		if hb.has_method("set_target"):
			hb.call("set_target", e)
		else:
			hb.set("target", e)

		world_ui.add_child(hb)
		enemy_bars[e] = hb

	print("HB spawned:", enemy_bars.size())


func _build_party_hud():
	party_hud.call("show_party", heroes)

func _orders_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size(): return false
	for i in range(a.size()):
		if a[i] != b[i]: return false
	return true

func _panel_total_w(n: int) -> float:
	return n * ICON_W + max(0, n - 1) * ICON_GAP

func _layout_from_order(order: Array[Node2D]) -> void:
	var n := order.size()
	if n == 0: return
	_center_turn_panel(_panel_total_w(n))
	var x := 0
	for i in range(n):
		var ch := order[i]
		if not char_to_icon.has(ch):   # умер/иконка снята
			continue
		var icon: TextureRect = char_to_icon[ch]
		icon.position = Vector2(x * _SLOT_W, 0)
		x += 1

func _animate_to_order(order: Array[Node2D], dur := 0.15) -> void:
	var n := order.size()
	if n == 0: return
	_center_turn_panel(_panel_total_w(n))
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	for i in range(n):
		var icon: TextureRect = char_to_icon[order[i]]
		tw.tween_property(icon, "position", Vector2(i * _SLOT_W, 0), dur)
	await tw.finished

# один «пузырьковый» шаг к целевому порядку: меняем местами только первую неправильную пару соседей
func _one_adjacent_step_towards(target: Array[Node2D]) -> Array[Node2D]:
	var cur := _current_visual_order.duplicate()
	var n := cur.size()
	if n <= 1: 
		return cur

	# куда «хочет» встать каждый персонаж из target
	var want := {}
	for i in range(target.size()):            # ← длина target!
		want[target[i]] = i

	# всё, чего нет в target (редко, но бывает) — считаем «очень правым»
	var max_idx := target.size()
	for ch in cur:
		if not want.has(ch):
			want[ch] = max_idx
			max_idx += 1

	# найдём первую неправильную пару соседей и поменяем их местами
	for i in range(n - 1):
		var a = cur[i]
		var b = cur[i + 1]
		var ia = int(want.get(a, 999999))
		var ib = int(want.get(b, 999999))
		if ia > ib:
			cur[i] = b
			cur[i + 1] = a
			break

	return cur


func _estimate_swaps(target: Array[Node2D]) -> int:
	var want := {}
	for i in range(target.size()):
		want[target[i]] = i
	var cur := _current_visual_order
	var inv := 0
	for i in range(cur.size()):
		for j in range(i+1, cur.size()):
			var ai := int(want.get(cur[i], 99999))
			var bj := int(want.get(cur[j], 99999))
			if ai > bj:
				inv += 1
	return inv
# полностью доводим визуальный порядок до target — по одному соседнему шагу за анимацию
func _normalize_target(target: Array[Node2D]) -> Array[Node2D]:
	var seen := {}
	var out: Array[Node2D] = []

	# берём только валидных, у кого ЕСТЬ иконка
	for ch in target:
		if ch != null and is_instance_valid(ch) and char_to_icon.has(ch) and not seen.has(ch):
			seen[ch] = true
			out.append(ch)

	# добавляем недостающих из текущего визуального (тоже только валидных)
	for ch in _current_visual_order:
		if ch != null and is_instance_valid(ch) and char_to_icon.has(ch) and not seen.has(ch):
			seen[ch] = true
			out.append(ch)

	return out

func _animate_stepwise_to(target_in: Array[Node2D]) -> void:
	var t0 := Time.get_ticks_msec()

	# нормализуем цель, чтобы множества совпадали
	var target := _normalize_target(target_in)

	# если текущего порядка ещё нет — просто выставим его мгновенно
	if _current_visual_order.size() == 0:
		_current_visual_order = target.duplicate()
		_layout_from_order(_current_visual_order)
		print("[QUEUE-ANIM] cold layout time=", Time.get_ticks_msec()-t0, "ms")
		return

	# если разный размер или множества не совпадают — мгновенный снэп
	if _current_visual_order.size() != target.size():
		_current_visual_order = target.duplicate()
		_layout_from_order(_current_visual_order)
		print("[QUEUE-ANIM] snap(size mismatch) time=", Time.get_ticks_msec()-t0, "ms")
		return

	if _orders_equal(_current_visual_order, target):
		print("[QUEUE-ANIM] no-op time=", Time.get_ticks_msec()-t0, "ms")
		return

	# оцениваем шаг и ограничиваем общее время (чтобы не тянуться)
	var swaps = max(1, _estimate_swaps(target))
	var step_dur = clamp(0.30 / swaps, 0.05, 0.12)  # ~0.3с лимит на всю перестройку

	var guard := 0
	while not _orders_equal(_current_visual_order, target) and guard < 64:
		guard += 1
		var next_step := _one_adjacent_step_towards(target)

		# если шаг не сдвинул порядок — делаем мгновенный снэп и выходим
		if _orders_equal(_current_visual_order, next_step):
			_current_visual_order = target.duplicate()
			_layout_from_order(_current_visual_order)
			print("[QUEUE-ANIM] fallback snap (no swap) time=", Time.get_ticks_msec()-t0, "ms")
			return

		await _animate_to_order(next_step, step_dur)
		_current_visual_order = next_step

	print("[QUEUE-ANIM] done in ", Time.get_ticks_msec()-t0, "ms")

func _name_of(ch: Node2D) -> String:
	return "%s(%s spd=%d m=%.1f)" % [ch.nick, ch.team, int(ch.speed), ch.turn_meter]

func _enter_pick_target(actor: Node2D, typ: String, data: Dictionary) -> void:
	_pending = {"type": typ, "actor": actor, "data": data}
	_pick_mode = true
	action_panel.hide()
	_build_pick_buttons()

func _leave_pick_mode(show_panel := true) -> void:
	_clear_pick_buttons()
	_pick_mode = false
	var a: Node2D = _pending.get("actor")
	_pending.clear()
	if show_panel and a != null and is_instance_valid(a):
		show_player_options(a)

func _build_pick_buttons() -> void:
	_clear_pick_buttons()
	for e in enemies:
		if is_instance_valid(e) and e.health > 0:
			var b := Button.new()
			b.text = "🎯"
			b.size = PICK_BTN_SIZE
			b.focus_mode = Control.FOCUS_NONE
			world_ui.add_child(b)
			_pick_btns.append(b)
			_pick_map[b] = e
			b.pressed.connect(Callable(self, "_on_pick_pressed").bind(b))
	_update_pick_buttons()

func _update_pick_buttons() -> void:
	var cam := get_viewport().get_camera_2d()
	if cam == null: return
	for b in _pick_btns:
		var t: Node2D = _pick_map.get(b)
		if t == null or not is_instance_valid(t):
			b.queue_free()
			continue
		var screen := _world_to_screen(t.global_position)
		b.position = screen + PICK_BTN_OFFSET - b.size * 0.5

func _clear_pick_buttons() -> void:
	for b in _pick_btns:
		if is_instance_valid(b): b.queue_free()
	_pick_btns.clear()
	_pick_map.clear()

func _process(_dt: float) -> void:
	if _pick_mode:
		_update_pick_buttons()
	_update_enemy_bars_positions()


func _print_order(tag: String, steps := 6) -> void:
	var order := _predict_order(min(steps, actors.size()))
	var parts := []
	for i in range(order.size()):
		parts.append("%d:%s" % [i+1, _name_of(order[i])])
	print("[%s] прогноз панели: %s" % [tag, ", ".join(parts)])
	if order.size() > 0:
		print("[%s] первая иконка (по прогнозу): %s" % [tag, order[0].nick])

func _debug_icons_positions(tag: String) -> void:
	# Кто реально слева-направо стоит в TopUI
	var rows := []
	for ch in actors:
		var ic: TextureRect = char_to_icon.get(ch)
		if ic:
			rows.append([ic.position.x, ch.nick])
	rows.sort_custom(func(a, b): return a[0] < b[0])
	var names := []
	for i in range(min(6, rows.size())):
		names.append("%d:%s" % [i+1, rows[i][1]])
	print("[%s] иконки слева→направо: %s" % [tag, ", ".join(names)])

# Удаляем повторы, сохраняя порядок
func _unique_order(arr: Array[Node2D]) -> Array[Node2D]:
	var seen := {}
	var out: Array[Node2D] = []
	for ch in arr:
		if not seen.has(ch):
			seen[ch] = true
			out.append(ch)
	return out

# Порядок для панели во время хода актёра:
# [текущий] + прогноз (без повторов)
func _panel_order_with_current_first(current: Node2D) -> Array[Node2D]:
	var pred := _predict_order(actors.size())
	var arr: Array[Node2D] = []
	arr.append(current)
	arr.append_array(pred)
	return _unique_order(arr)

# Порядок «после хода» (следующие без текущего):
func _panel_order_next() -> Array[Node2D]:
	return _unique_order(_predict_order(actors.size()))

func _speed_less(a, b) -> bool:
	# сортировка по скорости по убыванию, при равной скорости — стабильный тай-брейк
	if _eff_speed(a) == _eff_speed(b):
		return a.get_instance_id() < b.get_instance_id()
	return _eff_speed(a) > _eff_speed(b)
	
func _ready() -> void:
	$UI/ActionPanel.connect("action_selected", Callable(self, "_on_action_selected"))
	action_panel.hide()
	get_viewport().connect("size_changed", Callable(self, "_on_viewport_resized"))
	spawn_party()
	spawn_enemies()
	_spawn_enemy_bars()
	_build_party_hud()
	start_battle()
	await get_tree().process_frame
	_cine_self_test()

func _on_viewport_resized() -> void:
	if _current_visual_order.size() > 0:
		_layout_from_order(_current_visual_order)
	_update_enemy_bars_positions()

func _center_turn_panel(total_w: float) -> void:
	# центр по X через anchors + offsets
	turn_panel.anchor_left  = 0.5
	turn_panel.anchor_right = 0.5
	turn_panel.offset_left  = -total_w / 2.0
	turn_panel.offset_right =  total_w / 2.0
	# высоту можно держать фиксированной высоты иконок
	turn_panel.custom_minimum_size = Vector2(total_w, ICON_W)

func rebuild_turn_queue() -> void:
	# пересобираем очередь из живых инстансов
	turn_queue.clear()
	turn_queue.append_array(heroes)
	turn_queue.append_array(enemies)
	turn_queue = turn_queue.filter(func(c): return c != null)  # на всякий
	# сортируем по скорости по убыванию
	turn_queue.sort_custom(Callable(self, "_speed_less"))

	# ОТЛАДКА: печать состава
	var names := []
	for c in turn_queue:
		names.append("%s(%s spd=%d)" % [c.nick, c.team, int(c.speed)])
	print("Очередь старт:", names)
	
	
func _on_action_selected(action_type: String, actor: Node2D, data):
	if _is_acting: return
	action_panel.hide()

	match action_type:
		"attack":
			var attack_def := {
				"name": "Атака",
				"type": "physical",
				"target": "single_enemy",
				"damage": actor.attack,
				"costs": {"stamina": 5}
			}
			var list: Array[Node2D] = []
			for e in enemies:
				if is_instance_valid(e) and e.health > 0:
					list.append(e)
			if list.is_empty():
				end_turn(); return

			_build_target_overlay(actor, list, func(targets: Array) -> void:
				# targets всегда Array
				if not _can_pay_cost(actor, attack_def):
					show_player_options(actor); return
				_pay_cost(actor, attack_def)

				var tgt: Node2D = targets[0]
				_is_acting = true
				await _do_melee_single(actor, tgt, max(1, actor.attack))
				_is_acting = false
				end_turn()
			, "single")

		"skill":
			var skill: Dictionary = data if typeof(data) == TYPE_DICTIONARY else {}
			var s_target := String(skill.get("target",""))
			var is_magic := String(skill.get("type","")) == "magic"
			var base_dmg := int(skill.get("damage", actor.attack))
			var eff_tgt: Array = skill.get("effects_to_targets", [])
			_apply_self_effects_if_any(actor, skill)

			if s_target == "single_enemy":
				var list: Array[Node2D] = []
				for e in enemies:
					if is_instance_valid(e) and e.health > 0: list.append(e)
				if list.is_empty(): end_turn(); return

				_build_target_overlay(actor, list, func(targets: Array) -> void:
					if not _can_pay_cost(actor, skill):
						show_player_options(actor)
						return
					_pay_cost(actor, skill)

					var tgt: Node2D = targets[0]
					if skill.has("qte"):
						await _perform_with_qte(actor, [tgt], skill)   # ← QTE-путь
					else:
						_is_acting = true
						if is_magic:
							await _do_magic_single(actor, tgt, max(1, base_dmg), eff_tgt)
						else:
							await _do_melee_single(actor, tgt, max(1, base_dmg), eff_tgt)
						_is_acting = false
					end_turn()
				, "single")
			elif s_target == "all_enemies":
				var list_all: Array[Node2D] = []
				for e in enemies:
					if is_instance_valid(e) and e.health > 0:
						list_all.append(e)
				if list_all.is_empty():
					end_turn(); return

				_build_target_overlay(actor, list_all, func(_targets: Array) -> void:
					if not _can_pay_cost(actor, skill):
						show_player_options(actor)
						return
					_pay_cost(actor, skill)

					if skill.has("qte"):
						await _perform_with_qte(actor, list_all, skill)  # ← QTE-путь и для массовых
					else:
						_is_acting = true
						if is_magic:
							await _do_magic_aoe(actor, max(1, base_dmg), eff_tgt)
						else:
							await _do_melee_aoe(actor, max(1, base_dmg), eff_tgt)
						_is_acting = false
					end_turn()
				, "all")
			elif s_target == "self":
				var can := _can_pay_cost(actor, skill)
				if not can:
					show_player_options(actor)
					return
				_pay_cost(actor, skill)

				_is_acting = true
				await _do_support(actor, actor, skill)
				_is_acting = false
				end_turn()

			elif s_target == "single_ally":
				var allies: Array[Node2D] = []
				var pool: Array[Node2D] = []

				if actor.team == "hero":
					pool = heroes
				else:
					pool = enemies

				for a in pool:
					if is_instance_valid(a) and a.health > 0:
						allies.append(a)

				if allies.is_empty():
					end_turn()
					return

				_build_target_overlay(actor, allies, func(targets: Array) -> void:
					if not _can_pay_cost(actor, skill):
						show_player_options(actor)
						return
					_pay_cost(actor, skill)

					var tgt_local: Node2D = targets[0]

					_is_acting = true
					await _do_support(actor, tgt_local, skill)  # ← передаём весь словарь умения
					_is_acting = false
					end_turn()
				, "single")

		"item":
			end_turn()

		"skip":
			end_turn()
			
func _eff_speed(ch: Node2D) -> float:
	if ch != null and is_instance_valid(ch) and ch.has_method("effective_stat"):
		return float(ch.call("effective_stat", "speed"))
	return float(ch.speed)
	
func _apply_effects(list: Array, target: Node2D) -> void:
	if target == null or not is_instance_valid(target): return
	if not target.has_method("add_effect"): return
	for ex in list:
		target.call("add_effect", ex)

# —————————  СОЗДАЁМ  ГЕРОЕВ  —————————
func spawn_party() -> void:
	heroes.clear()
	var party_data := GameManager.make_party_dicts()
	var count = min(hero_slots.get_child_count(), party_data.size())
	for i in range(count):
		var slot: Node2D = hero_slots.get_child(i)
		var hero: Node2D  = CHAR_SCN.instantiate()
		slot.add_child(hero)
		hero.position = Vector2.ZERO
		hero.init_from_dict(party_data[i])
		heroes.append(hero)

# ————————— СОЗДАЁМ  ВРАГОВ —————————
func spawn_enemies() -> void:
	enemies.clear()
	var count := enemy_slots.get_child_count()
	for j in range(count):
		var slot: Node2D = enemy_slots.get_child(j)
		var foe: Node2D  = CHAR_SCN.instantiate()
		slot.add_child(foe)
		foe.position = Vector2.ZERO
		foe.team = "enemy"
		foe.nick = "Enemy%d" % (j+1)
		foe.max_health = 70; foe.health = 70
		foe.speed = 8 + j
		foe.abilities = [
			{"name":"Удар","target":"single_enemy","damage":8,"accuracy":0.9,"crit":0.05}
		]
		enemies.append(foe)

func _pick_next_actor() -> Node2D:
	var all := heroes + enemies
	var best_idx := -1
	var min_time := INF
	
	for i in range(all.size()):
		var ch = all[i]
		var time_to_full = (TURN_THRESHOLD - ch.turn_meter) / max(1.0, _eff_speed(ch))
		if time_to_full < min_time:
			min_time = time_to_full
			best_idx = i

	# Прокручиваем время на min_time: всем добавляем прогресс
	for ch in all:
		ch.turn_meter += _eff_speed(ch) * min_time

	# Победитель пересёк порог — вычитаем порог (перенос переполнения)
	var actor = all[best_idx]
	actor.turn_meter -= TURN_THRESHOLD

	return actor

func update_turn_queue_display():
	# Очищаем предыдущие иконки
	for icon in turn_icons:
		icon.queue_free()
	turn_icons.clear()

	for character in turn_queue:
		
		var nick = character.nick
		var icon_path = "res://Assets/icons/characters/%s.png" % nick
		var icon: TextureRect = ICON_SCN.instantiate()
		if ResourceLoader.exists(icon_path):
			icon.texture = load(icon_path)
		else:
			icon.texture = load("res://Assets/icons/characters/placeholder.png")
		turn_panel.add_child(icon)
		turn_icons.append(icon)

func show_player_options(actor: Node2D) -> void:
	current_actor = actor
	action_panel.show_main_menu(actor)

	var cam := get_viewport().get_camera_2d()
	var screen_pos: Vector2 = _world_to_screen(actor.global_position)
	var panel_pos := screen_pos + Vector2(100, 10)

	var vp_size := get_viewport_rect().size
	var pan_size: Vector2i = action_panel.size
	panel_pos.x = clamp(panel_pos.x, 0, vp_size.x - pan_size.x)
	panel_pos.y = clamp(panel_pos.y, 0, vp_size.y - pan_size.y)

	action_panel.position = panel_pos
	action_panel.show()

	
func use_item(item_key, user, target):
	if not GameManager.inventory.has(item_key):
		return
	var item = GameManager.inventory[item_key]
	if item.quantity <= 0:
		return  # нет в наличии
	match item.effect:
		"heal":
			var amount = item.heal_amount
			target.health = min(target.max_health, target.health + amount)
			#show_popup(user.name + " использует " + item.name + " на " + target.name + " (+"+str(amount)+" HP)")
		"restore_mana":
			var mana_amt = item.mana_amount
			target.mana = min(target.max_mana, target.mana + mana_amt)
			#show_popup(user.name + " восполняет ману " + target.name + " на "+str(mana_amt))
		"damage":
			var dmg = item.damage_amount
			target.health -= dmg
			#show_damage(target, dmg, false)
	# уменьшить количество
	item.quantity -= 1
	# завершить ход
	end_turn()
# --- ПРОГНОЗ ОЧЕРЕДИ ПО ШКАЛЕ (для UI), не мутирует реальное состояние ---
func _predict_order(steps:int = 6) -> Array[Node2D]:
	var all := actors
	if all.is_empty():
		return []
	var tm := {}
	for ch in all: tm[ch] = ch.turn_meter

	var order: Array[Node2D] = []
	for _i in range(min(steps, all.size())):
		var best: Node2D = null
		var min_time := INF
		for ch in all:
			var t = (TURN_THRESHOLD - float(tm[ch])) / max(1.0, _eff_speed(ch))
			if t < min_time:
				min_time = t
				best = ch
		for ch in all:
			tm[ch] += _eff_speed(ch) * min_time
		tm[best] -= TURN_THRESHOLD
		order.append(best)
	return order
	
func _apply_self_effects_if_any(user: Node2D, ability: Dictionary) -> void:
	var self_list: Array = ability.get("effects_to_self", [])
	if self_list.size() > 0:
		_apply_effects(self_list, user)
		
func start_battle() -> void:
	actors = heroes + enemies
	# лёгкий сдвиг для разрыва ничьих
	for ch in actors:
		ch.turn_meter = randf() * 10.0

	_build_turn_icons_fresh()
	await get_tree().process_frame

	# стартовая раскладка — по «следующим»
	turn_queue = _panel_order_next()
	_current_visual_order = turn_queue.duplicate()
	_layout_from_order(_current_visual_order)
	_layout_icons_immediately()    # центр и раскладка по прогнозу
	_print_order("START")            # ← кто «должен» быть первым по панели
	_debug_icons_positions("START")  # ← как реально стоят иконки
	process_turn()

func _do_magic_single(user: Node2D, target: Node2D, damage: int, effects_to_targets: Array = []) -> void:
	if user == null or target == null:
		return
	if not is_instance_valid(user) or not is_instance_valid(target):
		return

	var clip := "idle"
	if user.anim != null:
		if user.anim.has_animation("cast"):
			clip = "cast"
		elif user.anim.has_animation("skill"):
			clip = "skill"
		elif user.anim.has_animation("attack"):
			clip = "attack"
	_play_if_has(user.anim, clip)

	var gate := {"done": false}
	var cb := Callable(self, "_apply_melee_hit").bind(target, damage, gate, effects_to_targets, user)
	_connect_hit_once(user, cb)

	var clip_len := 0.6
	if user.anim != null:
		if user.anim.has_animation(clip):
			clip_len = user.anim.get_animation(clip).length
	var timeout = clamp(0.30 * clip_len, 0.08, 0.60)
	await get_tree().create_timer(timeout).timeout

	_apply_melee_hit(target, damage, gate, effects_to_targets, user)
	_disconnect_hit_if_any(user, cb)

	await _wait_anim_end(user.anim, clip, 1.2)
	_play_if_has(user.anim, "idle")



func _do_magic_aoe(user: Node2D, damage: int, effects_to_targets: Array = []) -> void:
	if user == null or not is_instance_valid(user):
		return

	var clip := "idle"
	if user.anim != null:
		if user.anim.has_animation("cast"):
			clip = "cast"
		elif user.anim.has_animation("skill"):
			clip = "skill"
		elif user.anim.has_animation("attack"):
			clip = "attack"
	_play_if_has(user.anim, clip)

	var gated := {"done": false}
	var cb := Callable(self, "_on_magic_aoe_hit").bind(user, damage, effects_to_targets, gated)
	_connect_hit_once(user, cb)

	var clip_len := 0.6
	if user.anim != null:
		if user.anim.has_animation(clip):
			clip_len = user.anim.get_animation(clip).length
	var timeout = clamp(0.30 * clip_len, 0.08, 0.60)
	await get_tree().create_timer(timeout).timeout

	if not gated.get("done", false):
		_apply_aoe_once(user, damage, effects_to_targets)
		gated["done"] = true

	_disconnect_hit_if_any(user, cb)
	await _wait_anim_end(user.anim, clip, 1.2)
	_play_if_has(user.anim, "idle")

	
func _on_magic_aoe_hit(user: Node2D, damage: int, effects_to_targets: Array, gated: Dictionary) -> void:
	if gated.get("done", false):
		return
	gated["done"] = true
	_apply_aoe_once(user, damage, effects_to_targets)

func _do_support(user: Node2D, target: Node2D, ability: Dictionary) -> void:
	if user == null:
		return
	if target == null or not is_instance_valid(target):
		target = user

	# ── Защита от неправильного типа ──
	if typeof(ability) == TYPE_ARRAY:
		ability = {"effects_to_targets": ability}
	elif typeof(ability) != TYPE_DICTIONARY:
		return

	# Выбор клипа
	var clip := "idle"
	if user.anim != null:
		if user.anim.has_animation("cast"):
			clip = "cast"
		elif user.anim.has_animation("skill"):
			clip = "skill"
	_play_if_has(user.anim, clip)

	# Момент применения ~30% длины клипа
	var clip_len := 0.5
	if user.anim != null and user.anim.has_animation(clip):
		clip_len = user.anim.get_animation(clip).length
	var apply_delay := 0.30 * clip_len
	if apply_delay < 0.06: apply_delay = 0.06
	if apply_delay > 0.60: apply_delay = 0.60
	await get_tree().create_timer(apply_delay).timeout

	# Лечение
	if ability.has("heal"):
		var heal := int(ability.get("heal", 0))
		var new_hp = target.health + heal
		if new_hp > target.max_health: new_hp = target.max_health
		if new_hp < 0: new_hp = 0
		target.health = new_hp

	# Эффекты
	var effs_to_target: Array = ability.get("effects_to_targets", [])
	if effs_to_target.size() > 0:
		_apply_effects(effs_to_target, target)

	var effs_to_self: Array = ability.get("effects_to_self", [])
	if effs_to_self.size() > 0:
		_apply_effects(effs_to_self, user)

	await _wait_anim_end(user.anim, clip, 1.2)
	_play_if_has(user.anim, "idle")

func _apply_melee_hit(target: Node2D, damage: int, gate: Dictionary, effects_to_targets: Array = [], source: Node2D = null) -> void:
	if gate.get("done", false): return
	gate["done"] = true
	if not is_instance_valid(target): return

	target.health = max(0, target.health - damage)

	# эффекты на цель — из способности
	if effects_to_targets.size() > 0:
		_apply_effects(effects_to_targets, target)

	# лёгкая тряска
	var base := target.position
	var tw := create_tween().set_trans(Tween.TRANS_SINE)
	tw.tween_property(target, "position", base + Vector2(4, 0), 0.05)
	tw.tween_property(target, "position", base - Vector2(3, 0), 0.05)
	tw.tween_property(target, "position", base, 0.05)

	if target.health <= 0:
		_on_enemy_died(target)

func _do_melee_aoe(user: Node2D, damage: int, effects_to_targets: Array = []) -> void:
	if user == null or not is_instance_valid(user):
		return

	# подбегаем в центр
	var mover := user.get_node_or_null("MotionRoot") as Node2D
	if mover == null:
		mover = user
	var start_pos := mover.global_position

	var dst := _screen_center_world() + Vector2(AOE_CENTER_X_OFFSET, AOE_CENTER_Y_OFFSET)
	var sumy := 0.0
	var cnt := 0
	for e in enemies:
		if is_instance_valid(e) and e.health > 0:
			sumy += e.global_position.y
			cnt += 1
	if cnt > 0:
		dst.y = sumy / cnt + APPROACH_Y

	_play_if_has(user.anim, "run")
	var tw_in := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw_in.tween_property(mover, "global_position", dst, 0.22)
	await tw_in.finished

	# клип удара
	var clip := "attack"
	if user.anim != null:
		if user.anim.has_animation("skill"):
			clip = "skill"
		elif user.anim.has_animation("attack"):
			clip = "attack"

	_play_if_has(user.anim, clip)

	# сигнал/фолбэк
	var gated := {"done": false}
	var cb := Callable(self, "_on_magic_aoe_hit").bind(user, damage, effects_to_targets, gated)
	_connect_hit_once(user, cb)

	var clip_len := 0.6
	if user.anim != null and user.anim.has_animation(clip):
		clip_len = user.anim.get_animation(clip).length

	var timeout = clamp(0.30 * clip_len, 0.08, 0.60)
	await get_tree().create_timer(timeout).timeout

	if not gated.get("done", false):
		_apply_aoe_once(user, damage, effects_to_targets)
		gated["done"] = true

	_disconnect_hit_if_any(user, cb)

	# важно: дождаться завершения клипа, а потом вернуть позицию
	await _wait_anim_end(user.anim, clip, 1.2)

	var tw_out := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw_out.tween_property(mover, "global_position", start_pos, 0.22)
	await tw_out.finished
	_play_if_has(user.anim, "idle")


func _do_melee_single(user: Node2D, target: Node2D, damage: int, effects_to_targets: Array = []) -> void:
	if user == null or target == null or not is_instance_valid(user) or not is_instance_valid(target):
		return

	var mover := user.get_node_or_null("MotionRoot") as Node2D  # см. вариант Б ниже
	if mover == null: mover = user

	var start_pos := mover.global_position
	var hit_pos   := _approach_point(user, target)  # см. п.2, больше не передаём dist руками

	# Подбег
	_play_if_has(user.anim, "run")
	var tw_in := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw_in.tween_property(mover, "global_position", hit_pos, 0.18)
	await tw_in.finished

	# Атака
	_play_if_has(user.anim, "attack")

	# наносим урон по событию или по таймеру (~30% длины клипа)
	var hit_delay = 0.3 * (user.anim.get_animation("attack").length if user.anim and user.anim.has_animation("attack") else 0.4)
	# ── вместо старого блока с connect() ──
	var gate := {"done": false}
	var cb := Callable(self, "_apply_melee_hit").bind(target, damage, gate, effects_to_targets, user)
	_connect_hit_once(user, cb)

	var clip_len := 0.4
	if user.anim and user.anim.has_animation("attack"):
		clip_len = user.anim.get_animation("attack").length
	await get_tree().create_timer(clamp(0.3 * clip_len, 0.08, 0.45)).timeout

	_apply_melee_hit(target, damage, gate, effects_to_targets, user)  # фолбэк

	# если сигнал так и не выстрелил — снимаем подписку, чтобы не копилась
	_disconnect_hit_if_any(user, cb)

	# дожидаемся конца "attack"
	await _wait_anim_end(user.anim, "attack")

	# Возврат
	var tw_out := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw_out.tween_property(mover, "global_position", start_pos, 0.18)
	await tw_out.finished

	_play_if_has(user.anim, "idle")
	
func _player_use_skill(user: Node2D, skill: Dictionary) -> void:
	# списываем ресурс, если есть
	var cost_type = skill.get("cost_type", null)
	var cost := int(skill.get("cost", 0))
	if cost_type == "mana":
		user.mana = max(0, user.mana - cost)
	elif cost_type == "stamina":
		user.stamina = max(0, user.stamina - cost)

	var ttype := str(skill.get("target", ""))
	if ttype == "single_enemy":
		var tgt := _first_alive(enemies)
		if tgt:
			var dmg := int(skill.get("damage", user.attack))
			await _do_melee_single(user, tgt, max(1, dmg))
	elif ttype == "all_enemies":
		var dmg := int(skill.get("damage", 0))
		for e in enemies:
			if e.health > 0:
				e.health = max(0, e.health - dmg)
				if e.health <= 0:
					_on_enemy_died(e)
	elif ttype == "single_ally" and skill.has("heal"):
		var heal := int(skill.get("heal", 0))
		user.health = min(user.max_health, user.health + heal)
		# можно добавить маленький эффект/анимацию

	end_turn()


func _first_alive_enemy() -> Node2D:
	for e in enemies:
		if is_instance_valid(e) and e.health > 0:
			return e
	return null

func _first_alive(arr: Array[Node2D]) -> Node2D:
	for a in arr:
		if a != null and is_instance_valid(a) and a.health > 0:
			return a
	return null

func _build_target_overlay(user: Node2D, candidates: Array[Node2D], on_pick: Callable, mode: String = "single") -> void:
	# убрать старый
	if _target_overlay and is_instance_valid(_target_overlay):
		_target_overlay.queue_free()

	var ov := Control.new()
	ov.name = "TargetOverlay"
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	ov.focus_mode = Control.FOCUS_ALL
	ov.z_as_relative = false
	ov.z_index = 100  # ниже хп-баров
	ov.anchor_left = 0; ov.anchor_top = 0; ov.anchor_right = 1; ov.anchor_bottom = 1
	ov.offset_left = 0; ov.offset_top = 0; ov.offset_right = 0; ov.offset_bottom = 0
	$UI.add_child(ov)
	_target_overlay = ov

	var bg := ColorRect.new()
	bg.color = Color(0,0,0,0.25)
	bg.anchor_left = 0; bg.anchor_top = 0; bg.anchor_right = 1; bg.anchor_bottom = 1
	ov.add_child(bg)

	var cancel := Button.new()
	cancel.text = "Отмена"
	cancel.position = Vector2(12, 12)
	ov.add_child(cancel)
	cancel.pressed.connect(func():
		if is_instance_valid(_target_overlay):
			_target_overlay.queue_free()
		_target_overlay = null
		action_panel.show_main_menu(user)
	)

	# кнопки над целями
	var cam := get_viewport().get_camera_2d()
	_pick_btns.clear()
	_pick_map.clear()

	for e in candidates:
		if e == null or not is_instance_valid(e) or e.health <= 0:
			continue
		var btn := Button.new()
		btn.text = e.nick
		btn.custom_minimum_size = Vector2(90, 32)
		var sp = cam.unproject_position(e.global_position) if cam else e.global_position
		btn.position = sp + Vector2(-45, -96)
		ov.add_child(btn)

		_pick_btns.append(btn)
		_pick_map[btn] = e

	# подсветка
	if mode == "all":
		for b in _pick_btns:
			b.mouse_entered.connect(Callable(self, "_set_btns_highlight").bind(_pick_btns, true))
			b.mouse_exited.connect(Callable(self, "_set_btns_highlight").bind(_pick_btns, false))
	else:
		for b in _pick_btns:
			b.mouse_entered.connect(Callable(self, "_set_btns_highlight").bind([b], true))
			b.mouse_exited.connect(Callable(self, "_set_btns_highlight").bind([b], false))

	# клик
	for b in _pick_btns:
		b.pressed.connect(Callable(self, "_on_target_button").bind(_pick_map[b], on_pick, mode))

		
func _on_target_button(target: Node2D, on_pick: Callable, mode: String = "single") -> void:
	if _target_overlay and is_instance_valid(_target_overlay):
		_target_overlay.queue_free()
	_target_overlay = null

	if mode == "all":
		var picked: Array[Node2D] = []   # ← типизированный
		for e in enemies:
			if is_instance_valid(e) and e.health > 0:
				picked.append(e)
		await on_pick.call(picked)
	else:
		await on_pick.call([target])

func _screen_center_world() -> Vector2:
	var cam := get_viewport().get_camera_2d()
	return cam.get_screen_center_position() if cam else Vector2.ZERO

func _approach_point(user: Node2D, target: Node2D) -> Vector2:
	var p1 := target.global_position
	var y  := (p1.y if LOCK_Y_TO_TARGET else user.global_position.y) + APPROACH_Y
	# встаём строго слева от цели (по мировому X)
	return Vector2(p1.x - APPROACH_X, y)

func _play_if_has(ap: AnimationPlayer, name: String) -> void:
	if ap and ap.has_animation(name):
		ap.play(name)

func _wait_anim_end(ap: AnimationPlayer, name: String, fallback := 0.0) -> void:
	# Надёжная версия: без лямбд/сигналов, только опрос состояния.
	var limit := fallback
	if ap != null:
		if ap.has_animation(name):
			var L := ap.get_animation(name).length
			if L > 0.0:
				if L > limit:
					limit = L

	var t0 := Time.get_ticks_msec()
	var deadline_ms := int((limit + 0.10) * 1000.0)  # маленький запас

	while Time.get_ticks_msec() - t0 < deadline_ms:
		if ap == null:
			break
		# вышли, если клип уже не играет / сменился
		if not ap.is_playing():
			break
		if String(ap.current_animation) != name:
			break
		await get_tree().process_frame

	# На всякий: если всё ещё тот же клип и он «висит» — стопнем
	if ap != null:
		if ap.is_playing() and String(ap.current_animation) == name:
			ap.stop()


func _build_turn_icons_fresh() -> void:
	for ic in char_to_icon.values(): ic.queue_free()
	char_to_icon.clear()

	# ВАЖНО: по всем участникам, по одному инстансу
	for ch in actors:
		var icon: TextureRect = ICON_SCN.instantiate()
		icon.custom_minimum_size = Vector2(ICON_W, ICON_W)
		icon.size = Vector2(ICON_W, ICON_W)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

		var path := "res://Assets/icons/characters/%s.png" % ch.nick
		if ResourceLoader.exists(path):
			icon.texture = load(path)
		else:
			icon.texture = load(PLACEHOLDER)
		turn_panel.add_child(icon)
		char_to_icon[ch] = icon

func _build_turn_icons_if_needed() -> void:
	if char_to_icon.size() > 0: return
	for ch in turn_queue:
		var icon: TextureRect = ICON_SCN.instantiate()
		# картинка по нику, если есть
		var path = "res://Assets/icons/characters/%s.png" % ch.nick
		icon.texture = load(path) if ResourceLoader.exists(path) else load("res://Assets/icons/characters/placeholder.png")
		turn_panel.add_child(icon)
		char_to_icon[ch] = icon



func _can_pay_cost(user: Node2D, data: Dictionary) -> bool:
	var costs: Dictionary = data.get("costs", {})
	# поддержка старого формата
	if costs.is_empty():
		var ct = data.get("cost_type", null)
		var c  = int(data.get("cost", 0))
		if ct == null or c <= 0: return true
		costs = {}
		costs[String(ct)] = c

	var hp := int(costs.get("hp", 0))
	var mp := int(costs.get("mana", 0))
	var st := int(costs.get("stamina", 0))

	if hp > 0 and user.health <= hp: return false    # не даём умереть оплатой
	if mp > 0 and user.mana   <  mp: return false
	if st > 0 and user.stamina < st: return false
	return true

func _pay_cost(user: Node2D, data: Dictionary) -> void:
	var costs: Dictionary = data.get("costs", {})
	if costs.is_empty():
		var ct = data.get("cost_type", null)
		var c  = int(data.get("cost", 0))
		if ct != null and c > 0:
			costs = {}; costs[String(ct)] = c

	if costs.size() == 0: return

	user.health  = max(1, user.health  - int(costs.get("hp", 0)))   # минимум 1 HP
	user.mana    = max(0, user.mana    - int(costs.get("mana", 0)))
	user.stamina = max(0, user.stamina - int(costs.get("stamina", 0)))

func process_turn():
	var ch: Node2D = _pick_next_actor()

	# тикаем эффекты этого персонажа
	if ch != null and ch.has_method("on_turn_start"):
		ch.call("on_turn_start")

	if ch != null and ch.health <= 0:
		if ch.team == "enemy":
			_on_enemy_died(ch)
		else:
			# TODO: смерть героя
			pass
		end_turn()
		return
	var t0 := Time.get_ticks_msec()
	print("[TURN] picked ", ch.nick, " at ", Time.get_ticks_msec()-t0, "ms from start")

	turn_queue = _panel_order_with_current_first(ch)
	var t1 := Time.get_ticks_msec()
	await _animate_stepwise_to(turn_queue)
	print("[TURN] anim waited ", Time.get_ticks_msec()-t1, "ms before action/panel")

	if ch.team == "hero":
		show_player_options(ch)
	else:
		enemy_action(ch)

func end_turn():
	action_panel.hide()
	turn_queue = _panel_order_next()
	await _animate_stepwise_to(turn_queue)
	_print_order("AFTER_END")          # прогноз на следующий ход
	_debug_icons_positions("AFTER_END")
	process_turn()
	
func enemy_action(enemy):
	var action = choose_enemy_action(enemy)
	perform_action(enemy, action)
	await get_tree().create_timer(0.5).timeout  # небольшая пауза для визуализации
	end_turn()
	
func choose_enemy_action(enemy: Node2D) -> Variant:
	# 1) если есть лечение и кто-то ранен — лечим
	var heal_ability: Dictionary = {}
	for ability in enemy.abilities:
		if ability.get("name", "") == "Исцеление":
			heal_ability = ability
			break

	if heal_ability.size() > 0:
		var lowest_hp_target: Node2D = null
		for ally in enemies:
			if ally.health < ally.max_health:
				if lowest_hp_target == null \
				or float(ally.health) / max(1, ally.max_health) < float(lowest_hp_target.health) / max(1, lowest_hp_target.max_health):
					lowest_hp_target = ally
		if lowest_hp_target and lowest_hp_target.health < lowest_hp_target.max_health * 0.5:
			heal_ability["target_instance"] = lowest_hp_target
			return heal_ability

	# 2) иначе — любая атакующая способность
	var attack_skills: Array = enemy.abilities.filter(func(a): return a.get("damage") != null)
	if attack_skills.size() > 0:
		var choice: Dictionary = attack_skills[randi() % attack_skills.size()]
		if choice.get("target", "") == "single_enemy" and heroes.size() > 0:
			choice["target_instance"] = heroes[randi() % heroes.size()]
		return choice

	# 3) ничего подходящего — пропускаем
	return null

func perform_action(user: Node2D, action: Dictionary) -> void:
	if action == null or action.size() == 0:
		return

	# --- выбор целей ---
	var targets: Array = []
	var tgt = action.get("target", "")
	match tgt:
		"all_enemies":
			targets = enemies if user.team == "hero" else heroes
		"single_ally":
			targets = [action.get("target_instance", user)]
		"self":
			targets = [user]
		"all_allies":
			targets = heroes if user.team == "hero" else enemies
		_:
			targets = []

	# --- затраты ресурса ---
	var cost_type = action.get("cost_type", null)
	var cost      := int(action.get("cost", 0))
	if cost_type == "mana":
		user.mana = max(0, user.mana - cost)
	elif cost_type == "stamina":
		user.stamina = max(0, user.stamina - cost)

	# --- применение эффекта ---
	for target in targets:
		if action.get("damage") != null:
			var damage := int(action.get("damage", 0))
			var acc    := float(action.get("accuracy", 1.0))
			var crit_p := float(action.get("crit", 0.0))

			var hit_roll := randf()
			if hit_roll > acc:
				continue  # промах

			if hit_roll < crit_p:
				damage *= 2  # крит

			if randf() < 0.05:
				continue  # парирование (заглушка)

			target.health -= damage

		elif action.get("heal") != null:
			var heal_amount := int(action.get("heal", 0))
			target.health = min(target.max_health, target.health + heal_amount)
			
func _on_enemy_died(enemy: Node2D):
	if not is_instance_valid(enemy):
		return

	# 1) анимация смерти, если есть
	if enemy.anim and enemy.anim.has_animation("die"):
		enemy.anim.play("die")
		await _wait_anim_end(enemy.anim, "die", 0.6)

	# 2) мягко угасим спрайт (опционально)
	var tw := create_tween().set_trans(Tween.TRANS_SINE)
	tw.tween_property(enemy, "modulate:a", 0.0, 0.18)
	await tw.finished

	# 3) убираем HB/массивы/иконку
	if enemy_bars.has(enemy):
		enemy_bars[enemy].queue_free()
		enemy_bars.erase(enemy)

	enemies.erase(enemy)
	actors.erase(enemy)

	if char_to_icon.has(enemy):
		var ic: TextureRect = char_to_icon[enemy]
		if ic: ic.queue_free()
		char_to_icon.erase(enemy)

	# 4) перестраиваем очередь уже БЕЗ умершего
	turn_queue = _panel_order_next()
	_current_visual_order = _normalize_target(turn_queue)
	_layout_from_order(_current_visual_order)

	# 5) скрываем/удаляем сам узел
	if is_instance_valid(enemy):
		enemy.queue_free()
				
			
func _icons_base_x() -> float:
	var n := turn_queue.size()
	var total_w = n * ICON_W + max(0, n - 1) * ICON_GAP
	return max(0.0, (turn_panel.size.x - total_w) / 2.0)

func _layout_icons_immediately() -> void:
	var n := turn_queue.size()
	if n == 0: return
	var total_w = n * ICON_W + max(0, n - 1) * ICON_GAP
	_center_turn_panel(total_w)
	for i in range(n):
		var ch: Node2D = turn_queue[i]
		var icon: TextureRect = char_to_icon[ch]
		icon.position = Vector2(i * (ICON_W + ICON_GAP), 0)

func _animate_icons_to_queue() -> void:
	var n := turn_queue.size()
	if n == 0: return
	var total_w = n * ICON_W + max(0, n - 1) * ICON_GAP
	_center_turn_panel(total_w)
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	for i in range(n):
		var ch: Node2D = turn_queue[i]
		var icon: TextureRect = char_to_icon[ch]
		tw.tween_property(icon, "position", Vector2(i * (ICON_W + ICON_GAP), 0), 0.25)
	# отладка: кто на первом месте после анимации
	print("[ANIM] первый в панели -> ", turn_queue[0].nick)
	
func _layout_icons_by_prediction() -> void:
	var order := _predict_order(actors.size())
	var n := order.size()
	if n == 0: return

	var total_w = n * ICON_W + max(0, n - 1) * ICON_GAP
	_center_turn_panel(total_w)

	for i in range(n):
		var icon: TextureRect = char_to_icon[order[i]]
		icon.position = Vector2(i * (ICON_W + ICON_GAP), 0)
		
func _animate_icons_by_prediction() -> void:
	var order := _predict_order(actors.size())
	var n := order.size()
	if n == 0: return

	var total_w = n * ICON_W + max(0, n - 1) * ICON_GAP
	_center_turn_panel(total_w)

	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	for i in range(n):
		var icon: TextureRect = char_to_icon[order[i]]
		tw.tween_property(icon, "position", Vector2(i * (ICON_W + ICON_GAP), 0), 0.25)


		
func check_battle_end():
	var heroes_alive = heroes.filter(func(h): return h.health > 0)
	var enemies_alive = enemies.filter(func(e): return e.health > 0)
	#if enemies_alive.size() == 0:
		#battle_victory()
	#elif heroes_alive.size() == 0:
		#battle_defeat()
