extends Node2D

var turn_meter: float = 0.0     # 0 .. TURN_THRESHOLD
@onready var anim: AnimationPlayer = $AnimationPlayer
# Параметры персонажа
@export var nick: String = ""
@export var max_health: int = 100
var health: int
@export var max_mana: int = 0
var mana: int
@export var max_stamina: int = 0
var stamina: int
@export var speed: int = 10
var attack: int = 10
var defense: int = 5
signal hit_event
var effects: Array = []
@export var mechanic: Dictionary = {
	# пример по умолчанию
	"id": "",
	"name": "",
	"value": 0,
	"max": 0
}
@onready var hitbox: Area2D = $Hitbox
signal mechanic_changed
# Семь смертных грехов – значения от 0 до 100, например
@export var main_anim: String = "idle"
@export var additional_anim: String = "idle"
@export var spec_anim: String = "idle"
@export var sin_pride: int = 0
@export var sin_greed: int = 0
@export var sin_lust: int = 0
@export var sin_envy: int = 0
@export var sin_gluttony: int = 0
@export var sin_wrath: int = 0
@export var sin_sloth: int = 0
@export var count_anim: int = 10
@export var DEBUG_EFFECTS := false
var dodge_window: float = 0.12
var block_window: float = 0.18
var block_reduce: float = 0.5  # 0.5 = блок режет урон наполовину при «успехе»
var _click_locked: bool = false
# Список способностей (будет заполнен позже)
var abilities: Array = []

# Команда (сторона) персонажа: "hero" или "enemy"
var team: String = ""

func set_mechanic_value(v: int) -> void:
	if mechanic.size() == 0: return
	var mx := int(mechanic.get("max", 0))
	if mx > 0:
		v = clamp(v, 0, mx)
	if int(mechanic.get("value", 0)) == v:
		return
	mechanic["value"] = v
	emit_signal("mechanic_changed")

func _ef_log(msg: String) -> void:
	if DEBUG_EFFECTS:
		print("[EFF] ", String(nick), ": ", msg)

func has_effect(id: String) -> bool:
	for e in effects:
		if String(e.get("id","")) == id:
			return true
	return false

func remove_effect(id: String) -> void:
	var out: Array = []
	for e in effects:
		if String(e.get("id","")) != id:
			out.append(e)
	effects = out
	_refresh_qte_dodge_block_flag()
	_refresh_reflect_equal_flag()
	_refresh_turret_focus_meta()

func clear_effects() -> void:
	effects.clear()

func _effect_find_index(id: String) -> int:
	for i in range(effects.size()):
		var e: Dictionary = effects[i]
		if String(e.get("id","")) == id:
			return i
	return -1

# Мердж прототипа из БД и входных полей.
func _effect_normalize(src: Dictionary) -> Dictionary:
	var rec: Dictionary = {}

	var id := String(src.get("id",""))
	if id != "":
		var proto = GameManager.get_effect_proto(id)
		if not proto.is_empty():
			rec = proto.duplicate(true)

	# поверх прототипа — локальные поля
	for k in src.keys():
		if k == "mods":
			var base: Dictionary = rec.get("mods", {})
			var inc: Dictionary = src["mods"] if src.has("mods") else {}
			for mk in inc.keys():
				base[mk] = inc[mk]
			rec["mods"] = base
		else:
			rec[k] = src[k]

	# обязательные значения по умолчанию
	rec["id"] = id
	if not rec.has("name"):    rec["name"]    = id
	if not rec.has("is_buff"): rec["is_buff"] = false
	if not rec.has("mods"):    rec["mods"]    = {}
	if not rec.has("stack"):   rec["stack"]   = false

	# Определяем перманентность
	var permanent := bool(rec.get("permanent", false))
	if not permanent:
		if rec.has("duration"):
			var d_raw := int(rec.get("duration", 0))
			if d_raw >= 999:
				permanent = true
		else:
			# если duration не указан, а в базе стоит permanent: true
			var base = GameManager.get_effect_proto(id)
			if not base.is_empty() and bool(base.get("permanent", false)):
				permanent = true

	rec["permanent"] = permanent

	if permanent:
		if rec.has("duration"):
			rec.erase("duration")
	else:
		var d := 0
		if rec.has("duration"):
			d = int(rec.get("duration", 0))
		if d < 1:
			d = 1
		rec["duration"] = d

	return rec

# Публичное API: добавление/продление/стак
func add_effect(data: Dictionary) -> void:
	if data == null or typeof(data) != TYPE_DICTIONARY: return
	if not data.has("id"): return

	var in_id := String(data.get("id",""))

	# Взаимоисключение
	if in_id == "apathy":
		remove_effect("psychopathy")
	elif in_id == "psychopathy":
		remove_effect("apathy")

	var rec := _effect_normalize(data)
	if data == null or typeof(data) != TYPE_DICTIONARY:
		return
	if not data.has("id"):
		return


	var id := String(rec.get("id",""))
	var idx := _effect_find_index(id)

	if idx >= 0:
		# Уже есть такой id
		var cur: Dictionary = effects[idx]
		var cur_stack := bool(cur.get("stack", false))
		var new_stack := bool(rec.get("stack", false))

		if cur_stack or new_stack:
			# Разрешаем накопление — кладём отдельной записью
			effects.append(rec)
			_ef_log("stack '" + id + "'")
			return

		# Без стака: апдейт
		var became_perm := bool(cur.get("permanent", false)) or bool(rec.get("permanent", false))
		cur["permanent"] = became_perm

		if not became_perm:
			var cd := int(cur.get("duration", 1))
			var nd := int(rec.get("duration", 1))
			if nd > cd:
				cur["duration"] = nd

		# Обновим информативные поля и модификаторы
		cur["name"]    = rec.get("name", cur.get("name",""))
		cur["is_buff"] = rec.get("is_buff", cur.get("is_buff", false))
		var base_mods: Dictionary = cur.get("mods", {})
		var inc_mods:  Dictionary = rec.get("mods", {})
		for mk in inc_mods.keys():
			base_mods[mk] = inc_mods[mk]
		cur["mods"] = base_mods

		cur["stack"] = cur_stack or new_stack

		# ВАЖНО: пере-присвоить элемент массива (чтобы не попасть на «read-only» мутацию)
		effects[idx] = cur

		_ef_log("refresh '" + id + "' perm=" + str(cur.get("permanent", false)) + " dur=" + str(cur.get("duration", -1)))
	else:
		effects.append(rec)
		_ef_log("add '" + id + "' perm=" + str(rec.get("permanent", false)) + " dur=" + str(rec.get("duration", -1)))
	_refresh_qte_dodge_block_flag()
	_refresh_reflect_equal_flag()
	_refresh_turret_focus_meta()
	
# Пакетное применение списка эффектов (как в умениях/предметах)
func apply_effects(list_in: Array) -> void:
	if list_in == null:
		return
	for e in list_in:
		if typeof(e) == TYPE_DICTIONARY and e.has("id"):
			add_effect(e)

# Тик длительностей. Вызывайте строго один раз за ход на персонажа
# (либо в начале хода, либо в конце — на ваш выбор, но последовательно во всей игре).
func tick_effects_duration() -> void:
	var out: Array = []
	for e in effects:
		var perm := bool(e.get("permanent", false))
		if perm:
			out.append(e)
		else:
			var d := int(e.get("duration", 1)) - 1
			if d > 0:
				e["duration"] = d
				out.append(e)
	effects = out
	_refresh_qte_dodge_block_flag()
	_refresh_reflect_equal_flag()
	_refresh_turret_focus_meta()

# Снимок эффектов (без возможности внешней мутации)
func get_effects_snapshot() -> Array:
	var out: Array = []
	for e in effects:
		out.append((e as Dictionary).duplicate(true))
	return out

# Итоговый стат с учётом mods: <stat> и <stat>_mult
func effective_stat(which: String) -> float:
	var base := 0.0
	if which == "attack":
		base = float(attack)
	elif which == "defense":
		base = float(defense)
	elif which == "speed":
		base = float(speed)
	elif which == "max_health":
		base = float(max_health)
	elif which == "max_mana":
		base = float(max_mana)
	else:
		base = 0.0

	var add := 0.0
	var mult := 1.0
	for e in effects:
		var m: Dictionary = e.get("mods", {})
		if m.has(which):
			add += float(m[which])
		var mkey := which + "_mult"
		if m.has(mkey):
			mult *= float(m[mkey])

	return (base + add) * mult

signal coins_changed
var ether_coins: Array[String] = []  # ["yellow","blue","green"], максимум 7

func coins_count() -> int:
	return ether_coins.size()

func add_coin(kind: String) -> void:
	if ether_coins.size() >= 7:
		ether_coins.pop_front()   # «старые затираются»
	ether_coins.append(kind)
	print("[COINS] +", kind, " -> ", ether_coins)
	emit_signal("coins_changed")

func can_pay_coins(req: Dictionary) -> bool:
	var have := {"yellow":0, "blue":0, "green":0}
	for k in ether_coins:
		have[k] = int(have.get(k,0)) + 1
	for col in req.keys():
		if have.get(col,0) < int(req[col]):
			return false
	return true

func pay_coins(req: Dictionary) -> void:
	if not can_pay_coins(req):
		print("[COINS] not enough to pay ", req, " have=", ether_coins)
		return
	for col in req.keys():
		var need := int(req[col])
		var i := 0
		while i < ether_coins.size() and need > 0:
			if ether_coins[i] == col:
				ether_coins.remove_at(i)
				need -= 1
			else:
				i += 1
	print("[COINS] paid ", req, " -> ", ether_coins)
	emit_signal("coins_changed")

var count = 0
func _ready():
	if is_instance_valid(hitbox) and not hitbox.is_connected("input_event", Callable(self, "_on_hitbox_input_event")):
		hitbox.connect("input_event", Callable(self, "_on_hitbox_input_event"))
	if not anim.is_connected("animation_finished", Callable(self, "_on_anim_finished")):
		anim.connect("animation_finished", Callable(self, "_on_anim_finished"))
	if String(nick) == "Sally":
		if not has_meta("sally_insp"):   set_meta("sally_insp", 0)
		if not has_meta("sally_golden"): set_meta("sally_golden", false)
	_init_abilities()
	if main_anim == "idle":
		play_idle()
	else:
		play_custom()
	if is_instance_valid(hitbox):
		hitbox.input_pickable = true
		if not hitbox.is_connected("input_event", Callable(self, "_on_hitbox_input_event")):
			hitbox.connect("input_event", Callable(self, "_on_hitbox_input_event"))
	
@export var carry_slots_max := 3
@export var forbidden_categories: Array[String] = []
var pack: Dictionary = {}  # id -> количество (то, что ВЗЯТО в бой)



# Вызывать отсюда всю «комплексную» логику, которая раньше была в _on_hitbox_input_event
func handle_click() -> void:
	get_viewport().set_input_as_handled()
	count = count + 1# Запускаем нужную (кастомную) анимацию персонажа
	if count == count_anim:
		play_custom3()
		count = 0
	else:
		play_custom2()


func _on_hitbox_input_event(_vp, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		handle_click()


func can_use_item(id: String) -> bool:
	var def := GameManager.get_item_def(id)
	if def.is_empty():
		return false
	var cat := String(def.get("category",""))
	if forbidden_categories.has(cat):
		return false
	return true

func _pack_types_used() -> int:
	return pack.keys().size()

func pack_add(id: String, count: int) -> int:
	if count <= 0: 
		return 0
	var def := GameManager.get_item_def(id)
	if def.is_empty():
		return 0
	if not pack.has(id) and _pack_types_used() >= carry_slots_max:
		return 0
	var cap := int(def.get("carry_cap", 99))
	var have := int(pack.get(id, 0))
	var space := cap - have
	if space <= 0:
		return 0
	var add := count
	if add > space:
		add = space
	pack[id] = have + add
	return add

func pack_consume(id: String, count: int = 1) -> bool:
	var have := int(pack.get(id, 0))
	if have < count:
		return false
	var left := have - count
	if left > 0:
		pack[id] = left
	else:
		pack.erase(id)
	return true

func play_idle() -> void:
	# Проверяем, не играет ли уже Idle
	if anim.current_animation != "idle":
		anim.play("idle")
		
func _on_anim_finished(name: StringName) -> void:
	# Если закончилась та, что запускали из play_custom2 или play_custom3 — вернуться к main_anim
	if name == additional_anim or name == spec_anim:
		play_custom()
		_click_locked = false

func play_custom() -> void:
	# Проверяем, не играет ли уже Idle
	if anim.current_animation != main_anim:
		anim.play(main_anim)

func play_custom2() -> void:
	# Проверяем, не играет ли уже Idle
	if anim.current_animation != additional_anim:
		_click_locked = true
		anim.play(additional_anim)
		
func play_custom3() -> void:
	# Проверяем, не играет ли уже Idle
	if anim.current_animation != spec_anim:
		_click_locked = true
		anim.play(spec_anim)
	
func _anim_hit_event() -> void:
	emit_signal("hit_event")

func init_from_dict(d: Dictionary) -> void:
	nick = d.get("nick", "Hero")
	team = d.get("team", "hero")
	max_health = d.get("max_health", 100)
	max_mana = d.get("max_mana", 0)
	max_stamina = d.get("max_stamina", 0)
	attack = d.get("attack", 10)
	defense = d.get("defense", 5)
	speed = d.get("speed", 10)
	if d.has("dodge_window"):
		dodge_window = float(d.get("dodge_window", 0.12))
	else:
		dodge_window = 0.12

	if d.has("block_window"):
		block_window = float(d.get("block_window", 0.18))
	else:
		block_window = 0.18

	if d.has("block_reduce"):
		block_reduce = float(d.get("block_reduce", 0.5))
	else:
		block_reduce = 0.5

	health = d.get("hp", max_health)
	mana = d.get("mana", max_mana)
	stamina = d.get("stamina", max_stamina)
	
	# ── Салли начинает с половины максимальной маны ──
	if String(nick) == "Sally":
		mana = int(max_mana * 0.5)

	abilities = d.get("skills", [])
	for i in abilities.size():
		var s = abilities[i]
		var costs = s.get("costs", {})
		var mana_cost := int(costs.get("mana", s.get("mana_cost", 0)))
		s["__base_costs"] = {"mana": mana_cost}
		abilities[i] = s
		# ... ваш старый код инициализации ...
	if d.has("carry_slots_max"):
		carry_slots_max = int(d["carry_slots_max"])
	forbidden_categories.clear()
	var raw_fc: Array = d.get("forbidden_categories", [])
	for v in raw_fc:
		if typeof(v) == TYPE_STRING:
			forbidden_categories.append(v)
		else:
			forbidden_categories.append(String(v))
	pack.clear()
	if d.has("pack"):
		for item in d["pack"]:
			var id := String(item.get("id",""))
			var cnt := int(item.get("count", 0))
			if id != "" and cnt > 0:
				pack[id] = cnt

func _init_abilities():
	if team == "hero":
		# Пример: герои имеют базовую атаку и пару умений
		abilities = [
			{"name": "Атака", "type": "physical", "target": "single_enemy", "damage": 10, "cost_type": null, "cost": 0, "accuracy": 0.9, "crit": 0.1},
			{"name": "Огненный шар", "type": "magic", "target": "all_enemies", "damage": 8, "cost_type": "mana", "cost": 10, "accuracy": 0.85, "crit": 0.2},
			{"name": "Лечение", "type": "magic", "target": "single_ally", "heal": 15, "cost_type": "mana", "cost": 8, "accuracy": 1.0}
		]
	else:
		# Для врагов другие способности
		abilities = [
			{"name": "Удар", "type": "physical", "target": "single_enemy", "damage": 8, "cost_type": null, "cost": 0, "accuracy": 0.9, "crit": 0.05},
			{"name": "Исцеление", "type": "magic", "target": "single_ally", "heal": 10, "cost_type": "mana", "cost": 5, "accuracy": 1.0},
			{"name": "Яд", "type": "magic", "target": "single_enemy", "damage": 5, "effect": "poison", "cost_type": "mana", "cost": 5, "accuracy": 0.8}
		]
		
func _refresh_turret_focus_meta() -> void:
	var active := false
	var basic_mult := 1.0
	var basic_cost := 0
	var end_zero := false
	var end_broken := false
	var initial_shields := 0

	for e in effects:
		var id := String(e.get("id",""))
		if id == "":
			continue
		var proto := GameManager.get_effect_proto(id)
		if typeof(proto) != TYPE_DICTIONARY:
			continue

		var tags = proto.get("tags", [])
		if typeof(tags) == TYPE_ARRAY and tags.has("turret"):
			active = true
			var behavior = proto.get("behavior", {})
			if typeof(behavior) == TYPE_DICTIONARY:
				basic_mult   = float(behavior.get("basic_attack_mult", 1.0))
				basic_cost   = int(behavior.get("basic_attack_charge_cost", 0))
				end_zero     = bool(behavior.get("end_on_zero_charge", false))
				end_broken   = bool(behavior.get("end_on_shields_broken", false))
				initial_shields = int(behavior.get("shield_hits", 0))
			break

	# мета-флаги активности и параметры
	set_meta("turret_active", active)
	set_meta("turret_basic_mult", basic_mult)
	set_meta("turret_basic_charge_cost", basic_cost)
	set_meta("turret_end_on_zero_charge", end_zero)
	set_meta("turret_end_on_shields_broken", end_broken)

	# счётчик щитов: инициализируем только один раз
	if active:
		var cur_left := int(get_meta("turret_shields_left", -1))
		if cur_left < 0:
			set_meta("turret_shields_left", max(0, initial_shields))
			print("[TURRET][CHAR] %s shields init -> %d" % [String(name), int(get_meta("turret_shields_left", 0))])
	else:
		# эффект исчез — сбрасываем к дефолтам (без erase_meta)
		set_meta("turret_shields_left", 0)
		set_meta("turret_basic_mult", 1.0)
		set_meta("turret_basic_charge_cost", 0)
		set_meta("turret_end_on_zero_charge", false)
		set_meta("turret_end_on_shields_broken", false)


func _refresh_reflect_equal_flag() -> void:
	var has_reflect := false
	for e in effects:
		var id := String(e.get("id",""))
		if id == "":
			continue
		var proto := GameManager.get_effect_proto(id)
		if typeof(proto) != TYPE_DICTIONARY:
			continue
		var behavior = proto.get("behavior", {})
		if bool(behavior.get("reflect_equal_damage", false)):
			has_reflect = true
			break
	set_meta("reflect_equal_damage", has_reflect)
# Пересчёт флага запрета QTE-уклонения по активным эффектам
func _refresh_qte_dodge_block_flag() -> void:
	var cnt := 0
	for e in effects:
		var id := String(e.get("id",""))
		if id == "": 
			continue
		var proto := GameManager.get_effect_proto(id)
		if typeof(proto) != TYPE_DICTIONARY:
			continue
		var mods = proto.get("mods", {})
		var behavior = proto.get("behavior", {})
		if bool(mods.get("stun", false)) or bool(behavior.get("qte_dodge_disabled", false)):
			cnt += 1
	set_meta("qte_dodge_blockers", cnt)
	set_meta("qte_dodge_disabled", cnt > 0)

func get_effects() -> Array:
	return effects


func on_turn_start() -> void:
	# DoT
	for ex in effects:
		if ex.has("dot"):
			health = max(0, health - int(ex.get("dot", 0)))
	
	if String(nick) == "Sally":
		if mana <= 0:
			if not has_effect("apathy"):
				add_effect({"id":"apathy"})
		elif max_mana > 0 and mana >= max_mana:
			if not has_effect("psychopathy"):
				add_effect({"id":"psychopathy"})
				
	if String(nick) == "Sally":
		var pool: Array = GameManager.get_sally_words_pool()
		if pool.size() >= 2:
			# Берём два разных случайных слова
			var i := int(randi() % pool.size())
			var j := int(randi() % pool.size())
			while j == i and pool.size() > 1:
				j = int(randi() % pool.size())

			var blue_word := String(pool[i])
			var red_word  := String(pool[j])

			# в mechanic — чтобы HUD/карточки могли показывать
			if not mechanic.has("id") or String(mechanic.get("id","")) != "sally_words":
				mechanic.clear()
				mechanic["id"] = "sally_words"
				mechanic["name"] = "Слова"
			mechanic["blue_word"] = blue_word
			mechanic["red_word"]  = red_word

			# дублируем в meta (если где-то в UI уже используют meta)
			set_meta("sally_words", {"blue": blue_word, "red": red_word})

				
	var mana_drain := 0
	for ex in effects:
		if ex.has("mods"):
			var mods = ex["mods"]
			if typeof(mods) == TYPE_DICTIONARY and mods.has("mana_drain_per_turn"):
				mana_drain += int(mods["mana_drain_per_turn"])
	if mana_drain > 0:
		mana = max(0, mana - mana_drain)
		
	var mana_gain := 0
	for ex in effects:
		if ex.has("mods"):
			var mods = ex["mods"]
			if typeof(mods) == TYPE_DICTIONARY and mods.has("mana_regen"):
				mana_gain += int(mods["mana_regen"])
	if mana_gain > 0:
		mana = min(max_mana, mana + mana_gain)
		
	if String(nick) == "Sally":
		if mana > 0:
			if has_effect("apathy"):
				remove_effect("apathy")

	# реген стамины героя
	if team == "hero" and max_stamina > 0:
		stamina = min(max_stamina, stamina + 10)
		
	#Данте уменьшает мультипликатор
	if String(nick) == "Dante":
		var mul := int(get_meta("dante_mul", 1))
		mul = max(1, mul - 1)            # уменьшаем, но не ниже 1
		set_meta("dante_mul", mul)
	# тик длительности
	var i := 0
	while i < effects.size():
		var ex: Dictionary = effects[i]
		var dur := int(ex.get("duration", -1))
		if dur > 0:
			dur -= 1
			ex["duration"] = dur
			effects[i] = ex
			if dur == 0:
				effects.remove_at(i)
				continue
		i += 1


func get_mechanic() -> Dictionary:
	return mechanic

func add_mechanic_value(delta: int) -> void:
	if mechanic.size() == 0: return
	var v := int(mechanic.get("value", 0)) + delta
	var mx := int(mechanic.get("max", 0))
	if mx > 0: v = clamp(v, 0, mx)
	mechanic["value"] = v
