extends Node2D   # или Node, если у вас без координат
var _current_visual_order: Array[Node2D] = []  # как иконки реально стоят сейчас
const _SLOT_W := ICON_W + ICON_GAP
const MAX_TOTAL_ANIM := 0.30
const MIN_STEP_DUR   := 0.05
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


func _spawn_enemy_bars():
	# удалить старые
	for bar in enemy_bars.values():
		bar.queue_free()
	enemy_bars.clear()

	for e in enemies:
		var hb: Control = HEALTHBAR_SCN.instantiate()
		world_ui.add_child(hb)
		hb.target = e
		enemy_bars[e] = hb

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
	for i in range(n):
		var icon: TextureRect = char_to_icon[order[i]]
		icon.position = Vector2(i * _SLOT_W, 0)

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
	# 1) убираем дубликаты, сохраняя порядок
	var seen := {}
	var out: Array[Node2D] = []
	for ch in target:
		if not seen.has(ch):
			seen[ch] = true
			out.append(ch)
	# 2) добавляем недостающих из текущего визуального порядка (в конец)
	for ch in _current_visual_order:
		if not seen.has(ch):
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
	if a.speed == b.speed:
		return a.get_instance_id() < b.get_instance_id()
	return a.speed > b.speed
	
func _ready() -> void:
	$UI/ActionPanel.connect("action_selected", Callable(self, "_on_action_selected"))
	action_panel.hide()
	get_viewport().connect("size_changed", Callable(self, "_on_viewport_resized"))
	spawn_party()
	spawn_enemies()
	_spawn_enemy_bars()
	_build_party_hud()
	start_battle()

func _on_viewport_resized() -> void:
	if _current_visual_order.size() > 0:
		_layout_from_order(_current_visual_order)

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
	# скрываем панель, чтобы не кликали второе действие
	action_panel.hide()

	match action_type:
		"attack":
			# базовая атака по одному врагу
			var tgt := _first_alive(enemies)
			if tgt:
				await _do_melee_single(actor, tgt, max(1, int(actor.attack)))
			end_turn()

		"skill":
			if typeof(data) == TYPE_DICTIONARY:
				await _player_use_skill(actor, data)
			else:
				end_turn()

		"item":
			# для примера — самопохил, если предмет лечащий
			if typeof(data) == TYPE_STRING:
				# можно подсунуть цель и здесь
				use_item(data, actor, actor)
			else:
				end_turn()

		"skip":
			end_turn()

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
		var time_to_full = (TURN_THRESHOLD - ch.turn_meter) / max(1.0, ch.speed)
		if time_to_full < min_time:
			min_time = time_to_full
			best_idx = i

	# Прокручиваем время на min_time: всем добавляем прогресс
	for ch in all:
		ch.turn_meter += ch.speed * min_time

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
	var screen_pos: Vector2 = cam.unproject_position(actor.global_position) if cam else actor.global_position
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
			var t = (TURN_THRESHOLD - float(tm[ch])) / max(1.0, float(ch.speed))
			if t < min_time:
				min_time = t
				best = ch
		for ch in all:
			tm[ch] += float(ch.speed) * min_time
		tm[best] -= TURN_THRESHOLD
		order.append(best)
	return order
	
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

func _apply_melee_hit(target: Node2D, damage: int, gate: Dictionary) -> void:
	if gate.get("done", false):
		return
	gate["done"] = true

	if not is_instance_valid(target):
		return

	target.health = max(0, target.health - damage)

	# маленькая тряска цели
	var base := target.position
	var tw := create_tween().set_trans(Tween.TRANS_SINE)
	tw.tween_property(target, "position", base + Vector2(4, 0), 0.05)
	tw.tween_property(target, "position", base - Vector2(3, 0), 0.05)
	tw.tween_property(target, "position", base, 0.05)

	if target.health <= 0:
		_on_enemy_died(target)


func _do_melee_single(user: Node2D, target: Node2D, damage: int) -> void:
	if user == null or target == null or not is_instance_valid(user) or not is_instance_valid(target):
		return

	var start_pos := user.global_position
	var hit_pos   := _approach_point(user, target, 56.0)

	# Подбег
	_play_if_has(user.anim, "run")
	var tw_in := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw_in.tween_property(user, "global_position", hit_pos, 0.18)
	await tw_in.finished

	# Атака
	_play_if_has(user.anim, "attack")

	# Ждём момент удара:
	# 1) если анимация вызовет signal hit_event — применим сразу
	# 2) если нет — применим через небольшой таймаут (фолбэк)
	var gate := {"done": false}

	if user.has_signal("hit_event"):
		# единоразово, чтобы не словить двойной удар
		user.hit_event.connect(Callable(self, "_apply_melee_hit").bind(target, damage, gate), CONNECT_ONE_SHOT)

	# фолбэк-таймер (если сигнал не придёт)
	await get_tree().create_timer(0.15).timeout
	_apply_melee_hit(target, damage, gate)

	# подождём ещё чуть-чуть, чтобы анимация завершилась (без риска зависнуть)
	await get_tree().create_timer(0.10).timeout

	# Возврат
	var tw_out := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw_out.tween_property(user, "global_position", start_pos, 0.18)
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

func _first_alive(arr: Array[Node2D]) -> Node2D:
	for a in arr:
		if a != null and is_instance_valid(a) and a.health > 0:
			return a
	return null

func _approach_point(attacker: Node2D, target: Node2D, dist := 56.0) -> Vector2:
	var a := attacker.global_position
	var b := target.global_position
	var dir := (b - a).normalized()
	return b - dir * dist

func _play_if_has(anim: AnimationPlayer, name: String) -> void:
	if anim and anim.has_animation(name):
		anim.play(name)

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





func process_turn():
	var t0 := Time.get_ticks_msec()
	var ch: Node2D = _pick_next_actor()
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
	if enemy_bars.has(enemy):
		enemy_bars[enemy].queue_free()
		enemy_bars.erase(enemy)

	if enemies.has(enemy):
		enemies.erase(enemy)
	if actors.has(enemy):
		actors.erase(enemy)

	# Иконку в очереди тоже уберём
	if char_to_icon.has(enemy):
		var ic: TextureRect = char_to_icon[enemy]
		if ic: ic.queue_free()
		char_to_icon.erase(enemy)

	# Обновим визуальный порядок очереди (без умершего)
	turn_queue = _panel_order_next()
	_current_visual_order = _normalize_target(turn_queue)
	_layout_from_order(_current_visual_order)

	# Спрячем сам узел врага (или queue_free, если готово)
	if is_instance_valid(enemy):
		enemy.hide()  # или enemy.queue_free()
				
			
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
