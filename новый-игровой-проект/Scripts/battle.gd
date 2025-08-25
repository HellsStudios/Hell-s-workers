extends Node2D   # или Node, если у вас без координат
var _current_visual_order: Array[Node2D] = []  # как иконки реально стоят сейчас
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
const _SLOT_W := ICON_W + ICON_GAP
var actors: Array[Node2D] = []   # ← общий список участников
const ICON_SCN := preload("res://Scenes/turn_icon.tscn")
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
@export var AOE_CAM_ZOOM := 1.12         # мягкий зум для AoE (меньше CINE_ZOOM)
@export var AOE_CAM_SHIFT_PX := 180.0    # сдвиг камеры вправо в пикселях экрана
@export var ENCOUNTER_ENEMIES: Array = []   # список id врагов из JSON/GM
@export var DEBUG_SALLY := true

func _collect_participants() -> Array:
	var arr: Array = []
	for h in heroes:
		if is_instance_valid(h) and "nick" in h:
			arr.append(h.nick)
	return arr

func _dante_basic_attack_apply_turret(actor: Node2D, dmg_in: int) -> int:
	if actor == null or not is_instance_valid(actor):
		return dmg_in
	if String(actor.nick) != "Dante":
		return dmg_in
	if not bool(actor.get_meta("turret_active", false)):
		return dmg_in

	var mult  = float(actor.get_meta("turret_basic_mult", 1.0))
	if mult < 1.0:
		mult = 1.0
	var cost  = int(actor.get_meta("turret_basic_charge_cost", 0))
	var base  = max(0, int(dmg_in))
	var out   = int(round(base * mult))

	# списание заряда, если задана стоимость
	if cost > 0:
		var charge = int(actor.get_meta("dante_charge", 0))
		var new_charge = charge - cost
		if new_charge < 0: new_charge = 0
		actor.set_meta("dante_charge", new_charge)
		if actor.has_signal("charge_changed"):
			actor.emit_signal("charge_changed", new_charge)
		print("[TURRET][DANTE] basic mult=%.2f cost=%d charge %d -> %d" % [mult, cost, charge, new_charge])

		# на нуле — удалить эффект, если требуется
		if new_charge == 0 and bool(actor.get_meta("turret_end_on_zero_charge", false)):
			var removed := false
			if actor.has_method("remove_effects_by_tag"):
				actor.remove_effects_by_tag("turret")
				removed = true
			elif actor.has_method("remove_effect_by_id"):
				actor.remove_effect_by_id("focus_D")
				removed = true
			print("[TURRET][DANTE] charge zero -> turret removed")

	return out

func _turret_absorb_if_any(target: Node2D, attacker: Node2D, dmg: int) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if dmg <= 0:
		return false

	var left := int(target.get_meta("turret_shields_left", 0))
	if left <= 0:
		return false

	# поглощаем удар
	left -= 1
	target.set_meta("turret_shields_left", left)
	print("[TURRET][ABSORB] tgt=%s absorbed hit (%d). left=%d" % [String(target.name), dmg, left])

	# визуальный поп щита — если у тебя есть такой хук
	if has_method("_play_shield_pop"):
		call("_play_shield_pop", target)

	# щиты кончились — снять эффект, если настроено и есть способ
	if left <= 0 and bool(target.get_meta("turret_end_on_shields_broken", false)):
		var removed := false
		if target.has_method("remove_effects_by_tag"):
			target.remove_effects_by_tag("turret")
			removed = true
		elif target.has_method("remove_effect_by_id"):
			target.remove_effect_by_id("focus_D")
			removed = true
		print("[TURRET][ABSORB] shields broken on %s; removed=%s" % [String(target.name), removed])

	return true


func _has_reflect_equal_damage(u: Node2D) -> bool:
	return u != null and is_instance_valid(u) and bool(u.get_meta("reflect_equal_damage", false))

func _is_qte_dodge_blocked(u: Node2D) -> bool:
	return u != null and is_instance_valid(u) and bool(u.get_meta("qte_dodge_disabled", false))
# --- DANTE HELPERS ---
func _dante_can_enhance(user: Node2D, skill: Dictionary) -> bool:
	if user == null or not is_instance_valid(user): return false
	if String(user.nick) != "Dante": return false
	var need := GameManager.get_dante_charge_cost(skill)
	if need <= 0: return false
	var have := int(user.get_meta("dante_charge", 0))
	return have >= need

func _dante_consume_charge(user: Node2D, skill: Dictionary) -> void:
	var need := GameManager.get_dante_charge_cost(skill)
	if need <= 0: return
	var have := int(user.get_meta("dante_charge", 0))
	var left := have - need
	if left < 0: left = 0
	user.set_meta("dante_charge", left)
	if user.has_signal("charge_changed"):
		user.emit_signal("charge_changed", left)

# берём блок усиления из JSON (consume/e nhance у тебя в dante_enhance.json)
func _dante_get_enhance_block(skill_name: String) -> Dictionary:
	if GameManager.has_method("get_dante_enhance_block"):
		return GameManager.get_dante_enhance_block(skill_name)
	# если геттера нет — просто пусто (не валим бой)
	return {}

# делаем ЛОКАЛЬНУЮ копию скилла с полями:
#  - damage_mult (если есть)
#  - _dante_gen_fx (Array эффектов на все цели)
#  - _dante_per_fx (Dictionary: "id:Dante"/"ally_other"/"enemy_other" -> Array эффектов)
func _dante_build_enhanced_skill(user: Node2D, base_skill: Dictionary) -> Dictionary:
	var skill := base_skill.duplicate(true)
	var name := String(skill.get("name",""))
	if name == "":
		return skill

	var enh := _dante_get_enhance_block(name)
	if enh.is_empty():
		return skill

	var gen = enh.get("generic", {})
	if typeof(gen) == TYPE_DICTIONARY and not gen.is_empty():
		if gen.has("damage_mult"):
			var cur_mult := float(skill.get("damage_mult", 1.0))
			var add_mult := float(gen.get("damage_mult", 1.0))
			skill["damage_mult"] = cur_mult * add_mult
		var gen_effs = gen.get("effects_to_targets", [])
		if typeof(gen_effs) == TYPE_ARRAY and gen_effs.size() > 0:
			skill["_dante_gen_fx"] = gen_effs

	var per = enh.get("per_target", {})
	if typeof(per) == TYPE_DICTIONARY and not per.is_empty():
		var map := {}
		if per.has("Dante"):       map["id:Dante"]    = per["Dante"].get("effects_to_targets", [])
		if per.has("Sally"):       map["id:Sally"]    = per["Sally"].get("effects_to_targets", [])
		if per.has("Berit"):       map["id:Berit"]    = per["Berit"].get("effects_to_targets", [])
		if per.has("ally_other"):  map["ally_other"]  = per["ally_other"].get("effects_to_targets", [])
		if per.has("enemy_other"): map["enemy_other"] = per["enemy_other"].get("effects_to_targets", [])
		skill["_dante_per_fx"] = map
	return skill

# навесить собранные эффекты на конкретные ЦЕЛИ В ЭТОЙ ВЕТКЕ
# generic -> на весь переданный group
# per_target:
#   - id:Dante/Sally/Berit -> на цели из group с таким nick
#   - ally_other -> на союзников из group, кроме самого user
#   - enemy_other -> на врагов из group
func _dante_apply_collected_fx(user: Node2D, skill: Dictionary, group: Array) -> void:
	var gen = skill.get("_dante_gen_fx", [])
	if typeof(gen) == TYPE_ARRAY and gen.size() > 0:
		for u in group:
			if is_instance_valid(u):
				_apply_effects(gen, u)

	var per = skill.get("_dante_per_fx", {})
	if typeof(per) != TYPE_DICTIONARY or per.is_empty():
		return

	for tag in ["id:Dante", "id:Sally", "id:Berit"]:
		if per.has(tag):
			var arr = per[tag]
			if typeof(arr) == TYPE_ARRAY and arr.size() > 0:
				var who = tag.replace("id:", "")
				for u in group:
					if is_instance_valid(u) and String(u.nick) == who:
						_apply_effects(arr, u)

	if per.has("ally_other"):
		var arr2 = per["ally_other"]
		if typeof(arr2) == TYPE_ARRAY and arr2.size() > 0:
			for u in group:
				if is_instance_valid(u) and String(u.team) == String(user.team) and u != user:
					_apply_effects(arr2, u)

	if per.has("enemy_other"):
		var arr3 = per["enemy_other"]
		if typeof(arr3) == TYPE_ARRAY and arr3.size() > 0:
			for u in group:
				if is_instance_valid(u) and String(u.team) != String(user.team):
					_apply_effects(arr3, u)
# --- /DANTE HELPERS ---


func _sally_dbg(stage: String, actor: Node2D, skill: Dictionary, extra: Dictionary = {}) -> void:
	if not DEBUG_SALLY: return
	if actor == null or not is_instance_valid(actor): return
	if String(actor.nick) != "Sally": return

	var nm := String(skill.get("name","<unnamed>"))
	var costd: Dictionary = skill.get("costs", skill.get("cost", {}))
	var mana_cost := int(costd.get("mana", skill.get("mana_cost", 0)))
	var is_blue := bool(skill.get("__sally_blue", false))
	var is_red  := bool(skill.get("__sally_red", false))
	var is_gold := bool(skill.get("__sally_gold", false))
	print(
		"[SALLY][", stage, "] ",
		"skill='", nm, "' ",
		"mana=", actor.mana, "/", actor.max_mana, " ",
		"mana_cost=", mana_cost, " ",
		"flags{blue=", is_blue, " red=", is_red, " gold=", is_gold, "} ",
		"extra=", extra
	)
# параметры защиты по умолчанию
@export var DODGE_WINDOW_DEFAULT := 0.01
@export var BLOCK_WINDOW_DEFAULT := 0.16
@export var BLOCK_REDUCE_DEFAULT := 0.50

@onready var defense_qte := $UI/DefenseQTE  # узел с DefenseQTE.gd
@export var MAGIC_SINGLE_ZOOM := 1.08
@export var MAGIC_CAM_SHIFT_PX := -100.0

signal battle_finished(result: String)
var _devour_map := {}

@export var SUPPORT_CAM_SHIFT_PX := 180.0   # баффы: герои ← (влево), враги → (вправо)

@export var EXIT_SCENE := ""      # если не пусто и ресурс существует — уйдём туда; иначе просто quit()
var _battle_over := false

var _cam_saved := { "pos": Vector2.ZERO, "zoom": Vector2.ONE, "proc": Node.PROCESS_MODE_INHERIT, "smooth": false }
var _vp_saved_xform: Transform2D = Transform2D.IDENTITY

func _get_dante():
	# если у тебя список союзных героев называется иначе — замени party_heroes на свой
	for h in heroes:
		if String(h.nick) == "Dante":
			return h
	return null
	
func _dante_inc_mul(by: int) -> void:
	var d = _get_dante()
	if d == null: return
	var mul := int(d.get_meta("dante_mul", 1))
	mul = clamp(mul + by, 1, 5)
	d.set_meta("dante_mul", mul)
	# print_debug("[DANTE][mul] +%d -> %d" % [by, mul])

func _dante_add_charge(base: int, reason := "") -> void:
	if _has_dante(heroes):
		var d = _get_dante()
		if d == null: return
		var mul := int(d.get_meta("dante_mul", 1))
		mul = max(1, mul)
		var add := base * mul
		var cur := int(d.get_meta("dante_charge", 0))
		var nxt = clamp(cur + add, 0, 100)
		d.set_meta("dante_charge", nxt)
		# print_debug("[DANTE][charge] +%d x%d = %d -> %d (%s)" % [base, mul, add, nxt, reason])

func _sally_psycho_auto(actor: Node2D) -> void:
	# --- собрать живых врагов ---
	var enemy_pool: Array[Node2D] = (enemies if String(actor.team) == "hero" else heroes)
	var enemies_alive: Array[Node2D] = []
	for n in enemy_pool:
		if is_instance_valid(n) and n.health > 0:
			enemies_alive.append(n)
	if enemies_alive.is_empty():
		return
	var tgt: Node2D = enemies_alive[int(randi() % enemies_alive.size())]

	# --- союзники для синергий ---
	var ally_pool: Array[Node2D] = (heroes if String(actor.team) == "hero" else enemies)
	var berit: Node2D = null
	var dante: Node2D = null
	for a in ally_pool:
		if is_instance_valid(a) and a.health > 0:
			var nk := String(a.nick)
			if nk == "Berit": berit = a
			elif nk == "Dante": dante = a

	# --- рандомный выбор действия из доступных ---
	var options: Array[String] = ["heavy"]
	if berit != null: options.append("throw_berit")
	if dante != null: options.append("dante_aoe")
	var choice := options[int(randi() % options.size())]

	# ─────────────────────────────────────
	# ВЕТКИ
	# ─────────────────────────────────────
	match choice:
		"throw_berit":
			_is_acting = true
			# cast у Салли
			var ap: AnimationPlayer = actor.anim
			var clip := "cast"
			_play_if_has(ap, clip)
			var clip_len := (ap.get_animation(clip).length if ap and ap.has_animation(clip) else 0.5)
			await get_tree().create_timer(clamp(0.30 * clip_len, 0.06, 0.60)).timeout

			# Берит «полетел» к цели и обратно + урон цели, стан Бериту
			var mover: Node2D = (berit.get_node_or_null("MotionRoot") as Node2D)
			if mover == null: mover = berit
			var start_pos := mover.global_position
			var hit_pos := ( _approach_point_for(berit, tgt) if has_method("_approach_point_for") else tgt.global_position )

			var tw_in := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
			tw_in.tween_property(mover, "global_position", hit_pos, 0.18)
			await tw_in.finished

			var dmg_b = max(1, berit.attack)
			tgt.health = max(0, tgt.health - dmg_b)
			if tgt.health <= 0: _on_enemy_died(tgt)

			_apply_effects([{"id":"stun","duration":1}], berit)

			_play_if_has(berit.anim, "evasion")
			var tw_out := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			tw_out.tween_property(mover, "global_position", start_pos, 0.20)
			await tw_out.finished
			await _wait_anim_end(berit.anim, "evasion", 0.9)
			_play_if_has(berit.anim, "idle")

			await _wait_anim_end(ap, clip, 0.95)
			_play_if_has(ap, "idle")
			_is_acting = false
			return

		"dante_aoe":
			_is_acting = true
			# cast у Салли
			var ap2: AnimationPlayer = actor.anim
			var clip2 := "cast"
			_play_if_has(ap2, clip2)
			var clip_len2 := (ap2.get_animation(clip2).length if ap2 and ap2.has_animation(clip2) else 0.5)
			await get_tree().create_timer(clamp(0.30 * clip_len2, 0.06, 0.60)).timeout

			# Данте бьёт «block» по всем, всем врагам стан на 1, сам Данте тоже стан на 1
			_play_if_has(dante.anim, "block")
			var dmg_d = max(1, dante.attack)
			for e in enemy_pool:
				if is_instance_valid(e) and e.health > 0:
					e.health = max(0, e.health - dmg_d)
					_apply_effects([{"id":"stun","duration":1}], e)
					if e.health <= 0: _on_enemy_died(e)

			_apply_effects([{"id":"stun","duration":1}], dante)

			await _wait_anim_end(dante.anim, "block", 0.9)
			_play_if_has(dante.anim, "idle")

			await _wait_anim_end(ap2, clip2, 0.95)
			_play_if_has(ap2, "idle")
			_is_acting = false
			return

		_:
			# базовый тяжёлый удар + самоурон
			_is_acting = true
			var heavy = max(1, int(actor.attack * 1.5))
			await _do_melee_single(actor, tgt, heavy)
			actor.health = max(0, actor.health - 5)
			_is_acting = false

func _is_devoured(u: Node2D) -> bool:
	return u != null and is_instance_valid(u) and bool(u.get_meta("devoured", false))

func _has_effect(u: Node2D, id: String) -> bool:
	if u == null or not is_instance_valid(u): return false
	if u.has_method("list_effects"):
		for e in u.call("list_effects"):
			if typeof(e) == TYPE_DICTIONARY and String(e.get("id","")) == id:
				return true
	return false

func _is_action_blocked(u: Node2D) -> bool:
	if u == null or not is_instance_valid(u):
		return false
	if _is_devoured(u):
		return true

	var effs: Array = []
	if u.has_method("get_effects"):
		effs = u.call("get_effects")
	elif u.has_variable("effects"):
		effs = u.effects

	for e in effs:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var mods: Dictionary = e.get("mods", {})
		if bool(mods.get("stun", false)):
			return true
		if bool(mods.get("skip_turn", false)):
			return true
		# бэкомпат по старым айдишникам
		var eid := String(e.get("id", ""))
		if eid == "hypnosis" or eid == "stun":
			return true
	return false

func _apply_berit_recipe_if_any(user: Node2D, skill: Dictionary) -> Dictionary:
	if user == null or not is_instance_valid(user):
		return skill
	if String(user.nick) != "Berit":
		return skill

	var recipe := GameManager.get_berit_recipe(String(skill.get("name","")))
	if recipe.size() == 0:
		return skill

	var need: Dictionary = recipe.get("consume", {})
	if user.has_method("can_pay_coins"):
		if not user.can_pay_coins(need):
			return skill
	else:
		return skill

	# 1) списываем нужные монеты
	user.pay_coins(need)

	# 2) начисляем монеты из рецепта
	var grants: Dictionary = recipe.get("grant", {})
	for k in grants.keys():
		var n := int(grants[k])
		for i in range(n):
			user.add_coin(k)

	# 3) формируем усиленную копию умения
	var enhanced := skill.duplicate(true)
	var enh: Dictionary = recipe.get("enhance", {})

	# урон/хил
	if enh.has("damage_mult"):
		var d := int(enhanced.get("damage", user.attack))
		enhanced["damage"] = int(round(d * float(enh["damage_mult"])))
	if enh.has("heal_mult"):
		var h := int(enhanced.get("heal", 0))
		enhanced["heal"] = int(round(h * float(enh["heal_mult"])))

	# бонус длительности для уже существующих эффектов
	if enh.has("duration_bonus"):
		var bonus := int(enh.get("duration_bonus", 0))
		if bonus != 0:
			for key in ["effects_to_targets","effects_to_self"]:
				var arr: Array = enhanced.get(key, [])
				if arr.size() > 0:
					var patched: Array = []
					for e in arr:
						var d2 = e.duplicate(true)
						d2["duration"] = int(d2.get("duration", 0)) + bonus
						patched.append(d2)
					enhanced[key] = patched

	# добавочные эффекты
	if enh.has("add_effects_to_targets"):
		var extra_t: Array = enh.get("add_effects_to_targets", [])
		var base_t: Array = enhanced.get("effects_to_targets", [])
		enhanced["effects_to_targets"] = base_t + extra_t

	if enh.has("add_effects_to_self"):
		var extra_s: Array = enh.get("add_effects_to_self", [])
		var base_s: Array = enhanced.get("effects_to_self", [])
		enhanced["effects_to_self"] = base_s + extra_s

	# смена таргета (например, на all_enemies)
	if enh.has("target"):
		enhanced["target"] = String(enh["target"])

	return enhanced

# кто в партии
func _get_hero_by_name(name: String) -> Node2D:
	for h in heroes:
		if is_instance_valid(h) and String(h.nick) == name:
			return h
	return null

func _party_has(name: String) -> bool:
	return _get_hero_by_name(name) != null

# счётчики для условий «синих» и «зелёных» монет
var _mana_spent_pool := 0              # суммарная потраченная героями мана для "blue"
var _enemy_debuff_applied := 0         # сколько наложено дебаффов для "green"

func _ai_map_style(style_raw: String) -> String:
	var s := style_raw.strip_edges().to_lower()
	# RU → EN (внутренние коды)
	if s.begins_with("aggressive"): return "aggressive"
	if s.begins_with("support") or s.begins_with("суп"): return "support"
	if s.begins_with("coward"): return "cowardly"
	if s.begins_with("cunning"): return "cunning"
	# на всякий — поддержим англ варианты
	if s in ["aggressive","support","cowardly","cunning"]:
		return s
	return "aggressive"

func _ai_style_of(enemy: Node2D) -> String:
	# читаем из meta, если проставили при спавне (см. п.3)
	var raw := "aggressive"
	if enemy != null and enemy.has_meta("ai_style"):
		raw = String(enemy.get_meta("ai_style"))
	return _ai_map_style(raw)

func _ai_base_weights(style: String) -> Dictionary:
	# БАЗОВЫЕ веса категорий (потом модифицируем по ситуации)
	match style:
		"aggressive":
			return {"attack_single": 40, "attack_aoe": 30, "debuff": 10, "ally_buff": 5, "self_buff": 10, "heal": 5}
		"support":
			return {"attack_single": 15, "attack_aoe": 10, "debuff": 10, "ally_buff": 30, "self_buff": 10, "heal": 25}
		"cowardly":
			return {"attack_single": 12, "attack_aoe": 8,  "debuff": 10, "ally_buff": 10, "self_buff": 45, "heal": 15}
		"cunning":
			return {"attack_single": 30, "attack_aoe": 10, "debuff": 30, "ally_buff": 10, "self_buff": 15, "heal": 5}
		_:
			return {"attack_single": 30, "attack_aoe": 20, "debuff": 15, "ally_buff": 10, "self_buff": 15, "heal": 10}

func _ai_split_abilities(enemy: Node2D) -> Dictionary:
	var out := {
		"heal": [], "self_buff": [], "ally_buff": [],
		"debuff": [], "attack_single": [], "attack_aoe": []
	}
	for a in enemy.abilities:
		if typeof(a) != TYPE_DICTIONARY: continue
		var tgt := String(a.get("target",""))
		var has_dmg = a.has("damage")
		var has_heal = a.has("heal")
		var eff_self: Array = a.get("effects_to_self", [])
		var eff_t: Array = a.get("effects_to_targets", [])

		if has_heal:
			out["heal"].append(a); continue

		if eff_self.size() > 0 and tgt == "self":
			out["self_buff"].append(a); continue

		if eff_t.size() > 0 and (tgt == "single_ally" or tgt == "all_allies"):
			out["ally_buff"].append(a)  # групповые/союзные баффы
			# не continue — умение могло иметь урон, но обычно — нет

		if eff_t.size() > 0 and (tgt == "single_enemy" or tgt == "all_enemies"):
			out["debuff"].append(a)     # дебаффы на врагов

		if has_dmg:
			if tgt == "single_enemy": out["attack_single"].append(a)
			elif tgt == "all_enemies": out["attack_aoe"].append(a)
	return out

func _weighted_choice(weights: Dictionary) -> String:
	var total := 0.0
	for k in weights.keys():
		var w := float(weights[k]); if w < 0.0: w = 0.0
		weights[k] = w
		total += w
	if total <= 0.0:
		return ""  # пусть вызывающий решит fallback
	var r := randf() * total
	for k in weights.keys():
		r -= float(weights[k])
		if r <= 0.0:
			return k
	return weights.keys()[0]

func _ally_lowest_hp(pool: Array[Node2D]) -> Node2D:
	var best: Node2D = null
	var best_ratio := 999.0
	for a in pool:
		if not is_instance_valid(a) or a.health <= 0 or _is_devoured(a): continue
		var ratio = float(a.health) / max(1, a.max_health)
		if ratio < best_ratio:
			best_ratio = ratio
			best = a
	return best

func _random_alive(pool: Array[Node2D]) -> Node2D:
	var arr: Array[Node2D] = []
	for a in pool:
		if is_instance_valid(a) and a.health > 0 and not _is_devoured(a):
			arr.append(a)
	if arr.is_empty(): return null
	return arr[randi() % arr.size()]

func _ai_need_self_buff(enemy: Node2D, self_buffs: Array) -> bool:
	# если в баффе есть id и он уже висит — «не нужно»
	for sb in self_buffs:
		var list: Array = sb.get("effects_to_self", [])
		for ex in list:
			var eid := String(ex.get("id",""))
			if eid != "" and enemy.has_method("has_effect") and enemy.call("has_effect", eid):
				return false
	# иначе — считаем, что нужно
	return self_buffs.size() > 0

func _ai_get_focus(enemy: Node2D) -> Node2D:
	# хранит «жертву» для коварного стиля
	if enemy.has_meta("ai_focus"):
		var f: Node2D = enemy.get_meta("ai_focus")
		if is_instance_valid(f) and f.health > 0:
			return f
	# выбираем нового — самый «битый» герой
	var f2 := _ally_lowest_hp(heroes)
	if f2 != null:
		enemy.set_meta("ai_focus", f2)
	return f2

func _play_defense_reaction(target: Node2D, defres: Dictionary) -> void:
	if target == null or not is_instance_valid(target):
		return

	var t := String(defres.get("type", "none"))
	var g := String(defres.get("grade", "fail"))

	var mover: Node2D = target.get_node_or_null("MotionRoot") as Node2D
	if mover == null:
		mover = target
	var start := mover.global_position

	var ap = target.anim
	var old_speed := 1.0
	if ap != null:
		old_speed = ap.speed_scale
		ap.speed_scale = 2.0

	if t == "dodge" and (g == "good" or g == "perfect"):
		var clip := "evasion"
		if ap != null and ap.has_animation(clip):
			ap.play(clip)
		var dx := 26.0
		if String(target.team) == "hero":
			dx = -26.0
		var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(mover, "global_position", start + Vector2(dx, 0), 0.05)
		tw.tween_property(mover, "global_position", start, 0.06)
		await tw.finished
		if ap != null:
			await _wait_anim_end(ap, clip, 0.35)

	elif t == "block":
		var clip2 := "block"
		if ap != null and ap.has_animation(clip2):
			ap.play(clip2)
		var dir := 1.0
		if String(target.team) == "hero":
			dir = -1.0
		var k := 10.0
		var twb := create_tween().set_trans(Tween.TRANS_SINE)
		twb.tween_property(mover, "global_position", start + Vector2(dir * k, 0), 0.03)
		twb.tween_property(mover, "global_position", start, 0.04)
		await twb.finished
		if ap != null:
			await _wait_anim_end(ap, clip2, 0.35)

	if ap != null:
		ap.speed_scale = old_speed
		_play_if_has(ap, "idle")
		
func _push_focus_with_screen_shift(center_world: Vector2, target_zoom: float, screen_dx_px: float, label: String) -> void:
	var z := target_zoom
	if z <= 0.0:
		z = _get_view_zoom()
	if z <= 0.001:
		z = 1.0
	var dx_world := screen_dx_px / z
	var target := center_world + Vector2(dx_world, 0.0)
	print("[CINE] label=", label, " center=", center_world, " zoom=", z, " dx_px=", screen_dx_px, " -> dx_world=", dx_world, " target=", target)
	await _cam_push_focus(target, z)

func _magic_cam_shift_world(attacker: Node2D, target_zoom: float) -> float:
	var z := target_zoom
	if z <= 0.001:
		z = 1.0
	var sx := MAGIC_CAM_SHIFT_PX / z
	if attacker != null and attacker.team == "enemy":
		sx = -sx
	print("[CINE] MAGIC_CAM_SHIFT_PX=", MAGIC_CAM_SHIFT_PX, " target_zoom=", z, " world_shift=", sx)
	return sx

func _approach_point_for(attacker: Node2D, target: Node2D) -> Vector2:
	var p1 := target.global_position
	var y := 0.0
	if LOCK_Y_TO_TARGET:
		y = p1.y
	else:
		y = attacker.global_position.y
	y += APPROACH_Y

	var dx := APPROACH_X
	if attacker != null and attacker.team == "enemy":
		return Vector2(p1.x + dx, y)
	return Vector2(p1.x - dx, y)

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

func _enter_cinematic(attacker: Node2D, targets: Array[Node2D]) -> void:
	if action_panel:
		action_panel.hide()
	if top_ui:
		top_ui.visible = false
	if party_hud:
		party_hud.visible = false

	var fade := 0.35

	if attacker != null and is_instance_valid(attacker):
		if String(attacker.team) == "hero":
			for e in enemies:
				if is_instance_valid(e) and not targets.has(e):
					e.modulate = Color(1, 1, 1, fade)
		else:
			for h in heroes:
				if is_instance_valid(h) and not targets.has(h):
					h.modulate = Color(1, 1, 1, fade)

func _defense_reaction_tween(target: Node2D, defres: Dictionary) -> Tween:
	if target == null or not is_instance_valid(target):
		return null

	var t := String(defres.get("type", "none"))
	var g := String(defres.get("grade", "fail"))
	var mover: Node2D = target.get_node_or_null("MotionRoot") as Node2D
	if mover == null:
		mover = target
	var start := mover.global_position

	var ap = target.anim
	if ap != null:
		ap.speed_scale = 2.0
		if t == "dodge" and (g == "good" or g == "perfect") and ap.has_animation("evasion"):
			ap.play("evasion")
		elif t == "block" and ap.has_animation("block"):
			ap.play("block")

	if t == "dodge" and (g == "good" or g == "perfect"):
		var dx := 26.0
		if String(target.team) == "hero":
			dx = -26.0
		var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(mover, "global_position", start + Vector2(dx, 0), 0.05)
		tw.tween_property(mover, "global_position", start, 0.06)
		tw.finished.connect(func():
			if ap != null:
				ap.speed_scale = 1.0
				_play_if_has(ap, "idle"))
		return tw

	if t == "block":
		var dir := 1.0
		if String(target.team) == "hero":
			dir = -1.0
		var k := 10.0
		var twb := create_tween().set_trans(Tween.TRANS_SINE)
		twb.tween_property(mover, "global_position", start + Vector2(dir * k, 0), 0.03)
		twb.tween_property(mover, "global_position", start, 0.04)
		twb.finished.connect(func():
			if ap != null:
				ap.speed_scale = 1.0
				_play_if_has(ap, "idle"))
		return twb

	return null

func _start_defense_reaction(target: Node2D, defres: Dictionary) -> Dictionary:
	if target == null or not is_instance_valid(target):
		return {}

	var t := String(defres.get("type", "none"))
	var g := String(defres.get("grade", "fail"))

	var mover: Node2D = target.get_node_or_null("MotionRoot") as Node2D
	if mover == null:
		mover = target
	var start := mover.global_position

	var ap = target.anim
	if ap != null:
		ap.speed_scale = 2.0   # поднимем всегда на время реакции

	var clip := ""
	var tw: Tween = null

	if t == "dodge" and (g == "good" or g == "perfect"):
		clip = "evasion"
		if ap != null and ap.has_animation(clip):
			ap.play(clip)
		var dx := 26.0
		if String(target.team) == "hero":
			dx = -26.0
		tw = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(mover, "global_position", start + Vector2(dx, 0), 0.05)
		tw.tween_property(mover, "global_position", start, 0.06)

	elif t == "block":
		clip = "block"
		if ap != null and ap.has_animation(clip):
			ap.play(clip)
		var dir := 1.0
		if String(target.team) == "hero":
			dir = -1.0
		var k := 10.0
		tw = create_tween().set_trans(Tween.TRANS_SINE)
		tw.tween_property(mover, "global_position", start + Vector2(dir * k, 0), 0.03)
		tw.tween_property(mover, "global_position", start, 0.04)

	# Всегда вернём структуру, даже без tw/clip — чтобы потом гарантированно сделать reset.
	return {"tw": tw, "ap": ap, "clip": clip}

func _play_defense_reaction_parallel(targets: Array[Node2D], defres: Dictionary) -> void:
	var recs: Array = []
	for t in targets:
		if is_instance_valid(t) and t.health > 0:
			var rec := _start_defense_reaction(t, defres)
			if rec.size() > 0:
				recs.append(rec)

	# ждём твины
	for rec in recs:
		var tw: Tween = rec.get("tw")
		if tw != null:
			await tw.finished

	# ждём клипы и обязательно откатываем speed_scale + idle
	for rec in recs:
		var ap: AnimationPlayer = rec.get("ap")
		var clip := String(rec.get("clip", ""))
		if ap != null:
			if clip != "":
				await _wait_anim_end(ap, clip, 0.35)
			ap.speed_scale = 1.0
			_play_if_has(ap, "idle")

func _exit_cinematic() -> void:
	if top_ui:
		top_ui.visible = true
	if party_hud:
		party_hud.visible = true
	for h in heroes:
		if is_instance_valid(h):
			h.modulate = Color(1, 1, 1, 1)
	for e in enemies:
		if is_instance_valid(e):
			e.modulate = Color(1, 1, 1, 1)
	
func _perform_with_qte(user: Node2D, targets: Array[Node2D], ability: Dictionary) -> void:
	if user == null:
		return
	if not is_instance_valid(user):
		return
	if targets.size() == 0:
		return

	var s_target := String(ability.get("target", ""))
	var is_aoe := s_target == "all_enemies"
	var typ := String(ability.get("type", ""))
	var need_move := typ == "physical"
	var has_damage := ability.has("damage")
	var has_heal := ability.has("heal")
	var has_eff_t := ability.has("effects_to_targets")
	var has_eff_s := ability.has("effects_to_self")
	var is_support := (has_heal or has_eff_t or has_eff_s) and not has_damage

	# --- центр AoE как в _do_melee_aoe ---
	var aoe_focus := _screen_center_world() + Vector2(AOE_CENTER_X_OFFSET, AOE_CENTER_Y_OFFSET)
	var sumy := 0.0
	var cnt := 0
	for e in enemies:
		if is_instance_valid(e):
			if e.health > 0:
				sumy += e.global_position.y
				cnt += 1
	if cnt > 0:
		aoe_focus.y = sumy / cnt + APPROACH_Y

	# --- камера перед действием ---
	if is_aoe:
		var cam_focus := aoe_focus
		var side_px := AOE_CAM_SHIFT_PX
		if typ == "magic":
			side_px = MAGIC_CAM_SHIFT_PX
		if is_support:
			side_px = SUPPORT_CAM_SHIFT_PX

		# знак: обычные атаки — герои вправо, враги влево;
		# баффы — герои влево, враги вправо
		if user != null and user.team == "enemy":
			if is_support:
				side_px = +abs(side_px)   # враг — вправо
			else:
				side_px = -abs(side_px)   # враг — влево
		else:
			if is_support:
				side_px = -abs(side_px)   # герой — влево
			else:
				side_px = +abs(side_px)   # герой — вправо

		var tag := "PLAYER_AOE"
		if typ == "magic": tag = "PLAYER_AOE_MAGIC"
		if is_support: tag = "PLAYER_AOE_SUPPORT"
		await _push_focus_with_screen_shift(cam_focus, AOE_CAM_ZOOM, side_px, tag)
	else:
		var main_tgt: Node2D = targets[0]
		# точка фокуса: для self — сам кастер; для single_ally — середина между кастером и целью; иначе как было
		var focus_point := main_tgt.global_position
		if is_support:
			if String(s_target) == "self":
				focus_point = user.global_position
			else:
				focus_point = (user.global_position + main_tgt.global_position) * 0.5

		var side_px2 := MAGIC_CAM_SHIFT_PX
		if is_support:
			side_px2 = SUPPORT_CAM_SHIFT_PX

		if user != null and user.team == "enemy":
			if is_support:
				side_px2 = +abs(side_px2)   # враг — вправо
			else:
				side_px2 = -abs(side_px2)   # враг — влево
		else:
			if is_support:
				side_px2 = -abs(side_px2)   # герой — влево
			else:
				side_px2 = +abs(side_px2)   # герой — вправо

		var tag2 := "PLAYER_SINGLE"
		if typ == "magic": tag2 = "PLAYER_SINGLE_MAGIC"
		if is_support: tag2 = "PLAYER_SUPPORT"
		await _push_focus_with_screen_shift(focus_point, MAGIC_SINGLE_ZOOM, side_px2, tag2)

	_enter_cinematic(user, targets)
	_update_enemy_bars_positions()

	# --- движение бойца (как раньше) ---
	var mover: Node2D = user.get_node_or_null("MotionRoot") as Node2D
	if mover == null:
		mover = user
	var start_pos := mover.global_position

	var move_mode := "none"  # "single" / "aoe"
	if typ == "physical":
		if is_aoe:
			move_mode = "aoe"
		elif targets.size() == 1:
			move_mode = "single"

	if move_mode == "single":
		var hit_pos := _approach_point_for(user, targets[0])
		_play_if_has(user.anim, "run")
		var tw_in := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw_in.tween_property(mover, "global_position", hit_pos, 0.18)
		await tw_in.finished
	elif move_mode == "aoe":
		_play_if_has(user.anim, "run")
		var tw_in2 := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw_in2.tween_property(mover, "global_position", aoe_focus, 0.22)
		await tw_in2.finished

	# --- QTE-ступени ---
	var qte_dict = ability.get("qte", {})
	var steps: Array = qte_dict.get("steps", [])
	var res_on_success = qte_dict.get("on_success", {})
	var res_on_perfect = qte_dict.get("on_perfect", {})
	var res_on_fail    = qte_dict.get("on_fail", {})

	if steps.size() == 0:
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

			var slow := float(step.get("slowmo", 0.0))
			var prev_scale := Engine.time_scale
			if slow > 0.0:
				var s := 1.0 - slow
				if s < 0.05: s = 0.05
				Engine.time_scale = s

			var dur := float(step.get("duration", 1.0))
			var segs = step.get("segments", [])
			qte_bar.start(dur, segs)
			var result: Dictionary = await qte_bar.finished
			Engine.time_scale = prev_scale

			var mod := {}
			if result.get("perfect", false) and res_on_perfect.size() > 0:
				mod = res_on_perfect
			elif result.get("success", false) and res_on_success.size() > 0:
				mod = res_on_success
			elif res_on_fail.size() > 0:
				mod = res_on_fail

			var dmg_base := int(ability.get("damage", user.attack))
			var mult := 1.0
			if mod.has("damage_mult"):
				mult = float(mod.get("damage_mult"))
			var dmg := int(round(dmg_base * mult))

			var effs: Array = ability.get("effects_to_targets", [])
			var heal_base := int(ability.get("heal", 0))
			var heal_mult := 1.0
			if mod.has("heal_mult"):
				heal_mult = float(mod.get("heal_mult"))

			# если есть эффекты, увеличим длительность
			var effs_self: Array = ability.get("effects_to_self", [])
			if mod.has("duration_bonus") and (effs.size() > 0 or effs_self.size() > 0):
				var bonus2 := int(mod.get("duration_bonus"))
				if bonus2 != 0:
					if effs.size() > 0:
						var patched2: Array = []
						for e2 in effs:
							var d2 = e2.duplicate(true)
							d2["duration"] = int(d2.get("duration", 0)) + bonus2
							patched2.append(d2)
						effs = patched2
					if effs_self.size() > 0:
						var patched_self: Array = []
						for e3 in effs_self:
							var d3 = e3.duplicate(true)
							d3["duration"] = int(d3.get("duration", 0)) + bonus2
							patched_self.append(d3)
						effs_self = patched_self

			# выбор целей этой ступени (random_enemies / all_enemies)
			var real_targets := targets
			if step.has("select"):
				var sel = step["select"]
				var mode := String(sel.get("mode", ""))
				if mode == "random_enemies":
					var cnt_pick := int(sel.get("count", 1))
					var pool: Array = []
					for e in enemies:
						if is_instance_valid(e) and e.health > 0:
							pool.append(e)
					pool.shuffle()
					real_targets = []
					var n = min(cnt_pick, pool.size())
					for i in range(n):
						real_targets.append(pool[i])
				elif mode == "all_enemies":
					real_targets = []
					for e in enemies:
						if is_instance_valid(e) and e.health > 0:
							real_targets.append(e)

			for t in real_targets:
				if is_instance_valid(t) and t.health > 0:
					if has_damage:
						var final := dmg
						var is_crit := false

						# шанс на крит из способности (если задан)
						var crit_ch := float(ability.get("crit", 0.0))
						# модификаторы цели (эвейд/крит-уязвимость)
						var mods := _query_incoming_mods(t)
						var evade := float(mods.get("evade", 0.0))
						var crit_mul := float(mods.get("crit_mult", 1.0))

						# эвейд
						if randf() < evade:
							_show_popup_number(t, 0, "miss", false)
						else:
							# крит
							if crit_ch > 0.0 and randf() < crit_ch:
								is_crit = true
								final = int(round(final * 1.5 * crit_mul))
							if final > 0:
								_apply_melee_hit(t, final, {"done": false}, effs, user, is_crit)
					else:
						# support: heal + эффекты-на-цель
						if heal_base > 0:
							var heal_amt := int(round(heal_base * heal_mult))
							t.health = min(t.max_health, max(0, t.health + heal_amt))
							_show_popup_number(t, heal_amt, "heal")
						if effs.size() > 0:
							_apply_effects(effs, t)

			# эффекты на себя
			if effs_self.size() > 0:
				_apply_effects(effs_self, user)

			await _wait_anim_end(user.anim, clip, 0.8)

	# --- откат ---
	if move_mode != "none":
		var tw_out := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw_out.tween_property(mover, "global_position", start_pos, 0.22)
		await tw_out.finished

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
	
# --- Салли: подмешать синие/красные слова и «золото» (ничего лишнего) ---
func _sally_apply_words_and_gold(actor: Node2D, skill: Dictionary) -> Dictionary:
	if actor == null or not is_instance_valid(actor): 
		return skill
	if String(actor.nick) != "Sally":
		return skill

	var desc_txt := String(skill.get("desc", skill.get("description", skill.get("text","")))).to_lower()
	var words: Dictionary = actor.get_meta("sally_words", {})
	var blue_w := String(words.get("blue","")).to_lower()
	var red_w  := String(words.get("red","")).to_lower()

	var has_blue := false
	var has_red  := false
	if blue_w != "" and desc_txt.findn(blue_w) != -1:
		has_blue = true
	if red_w != "" and desc_txt.findn(red_w) != -1:
		has_red = true

	# Красное: удвоить манакост
	if has_red:
		var cost = skill.get("costs", skill.get("cost", {}))
		if typeof(cost) == TYPE_DICTIONARY:
			var m0 := int(cost.get("mana", skill.get("mana_cost", 0)))
			if m0 > 0:
				cost["mana"] = m0 * 2
				skill["costs"] = cost
				if skill.has("mana_cost"):
					skill.erase("mana_cost")
		skill["__sally_red"] = true

	# Синее: усиление из GameManager
	if has_blue:
		var enh := GameManager.get_sally_enhance(String(skill.get("name","")), "blue")
		if typeof(enh) == TYPE_DICTIONARY and not enh.is_empty():
			if enh.has("damage_mult"):    skill["damage_mult"]    = float(enh["damage_mult"])
			if enh.has("heal_mult"):      skill["heal_mult"]      = float(enh["heal_mult"])
			if enh.has("duration_bonus"): skill["duration_bonus"] = int(enh["duration_bonus"])
			if enh.has("free_cost") and bool(enh["free_cost"]):
				var c2 = skill.get("costs", {})
				if typeof(c2) == TYPE_DICTIONARY:
					c2["mana"] = 0
					skill["costs"] = c2
					if skill.has("mana_cost"):
						skill.erase("mana_cost")
		skill["__sally_blue"] = true

	# «Золото»: если активна эйфория — золотой буст + 0 маны
	if bool(actor.get_meta("sally_golden", false)):
		var enh_g := GameManager.get_sally_enhance(String(skill.get("name","")), "gold")
		if typeof(enh_g) == TYPE_DICTIONARY and not enh_g.is_empty():
			if enh_g.has("damage_mult"):    skill["damage_mult"]    = float(enh_g["damage_mult"])
			if enh_g.has("heal_mult"):      skill["heal_mult"]      = float(enh_g["heal_mult"])
			if enh_g.has("duration_bonus"): skill["duration_bonus"] = int(enh_g["duration_bonus"])
		var c_gold = skill.get("costs", {})
		if typeof(c_gold) != TYPE_DICTIONARY:
			c_gold = {}
		c_gold["mana"] = 0
		skill["costs"] = c_gold
		if skill.has("mana_cost"):
			skill.erase("mana_cost")
		skill["__sally_gold"] = true

	return skill


# --- Берит: +1 синяя монета за КАЖДЫЕ суммарные 20 маны команды ---
func _berit_award_team_mana_coins(actor: Node2D, mana_before: int) -> void:
	var spent = max(0, mana_before - actor.mana)
	if spent <= 0:
		return
	var berit: Node2D = null
	for h in heroes:
		if is_instance_valid(h) and String(h.nick) == "Berit":
			berit = h
			break
	if berit == null:
		return
	var acc = int(berit.get_meta("team_mana_spent_accum", 0)) + spent
	while acc >= 20:
		if berit.has_method("add_coin"):
			berit.add_coin("blue")
		acc -= 20
	berit.set_meta("team_mana_spent_accum", acc)


# Заменить существующую версию
func _sally_after_cast(actor: Node2D, skill: Dictionary, mana_before: int) -> void:
	if actor == null or String(actor.nick) != "Sally":
		return

	# --- мана-рефанд: ТОЛЬКО синие, и НИКОГДА при красном/золотом ---
	var refund_ok := bool(skill.get("__sally_blue", false)) \
		and not bool(skill.get("__sally_red", false)) \
		and not bool(skill.get("__sally_gold", false))
	if refund_ok:
		var spent = max(0, mana_before - actor.mana)
		if spent > 0:
			actor.mana = min(actor.max_mana, actor.mana + spent * 2)
		if DEBUG_SALLY and String(actor.nick) == "Sally":
			var will_refund := 0
			if refund_ok and spent > 0:
				will_refund = spent * 2
			print("[SALLY][refund] mana_before=", mana_before, " after_pay=", actor.mana, " spent=", spent, " refund=", will_refund,
				  " flags{blue=", bool(skill.get("__sally_blue", false)),
				  " red=", bool(skill.get("__sally_red", false)),
				  " gold=", bool(skill.get("__sally_gold", false)), "}")

	# --- вдохновение ---
	var mech: Dictionary = actor.mechanic
	mech["id"] = "inspiration"
	mech["name"] = "Вдохновение"
	mech["max"] = 3
	var v := int(mech.get("value", 0))
	var v0 := int(mech.get("value", 0))   # до изменений
	# +1 стак даём только за «чисто синее» (если одновременно красное — без прироста)
	if bool(skill.get("__sally_blue", false)) and not bool(skill.get("__sally_red", false)):
		v = min(3, v + 1)

	# «золото» тратит все стаки и выключает эйфорию
	if bool(skill.get("__sally_gold", false)):
		v = 0
		actor.set_meta("sally_golden", false)

	mech["value"] = v
	actor.mechanic = mech
	
	# авто-эйфория при 3 стаках (для следующего действия)
	actor.set_meta("sally_golden", v >= 3)
	if DEBUG_SALLY and String(actor.nick) == "Sally":
		print("[SALLY][inspiration] before=", v0, " after=", v, " golden=", bool(actor.get_meta("sally_golden", false)))
	
# Делает глубокую копию умения, сбрасывает флаги и восстанавливает стоимость из __base_costs (если есть)
func _prepare_skill_for_cast(actor: Node, skill_in: Dictionary) -> Dictionary:
	var s := skill_in.duplicate(true)

	# Сброс временных флагов
	if s.has("__sally_blue"):
		s.erase("__sally_blue")
	if s.has("__sally_red"):
		s.erase("__sally_red")
	if s.has("__sally_gold"):
		s.erase("__sally_gold")

	# Восстановление базовой стоимости
	var base_costs = s.get("__base_costs", null)
	if base_costs == null:
		# Если ещё не сохранена база, считаем её из текущих полей (единоразово)
		var costs = s.get("costs", {})
		var mana_cost := int(costs.get("mana", s.get("mana_cost", 0)))
		base_costs = {"mana": mana_cost}
		s["__base_costs"] = base_costs

	# Принудительно выставляем текущие costs из базы
	var mc := int(base_costs.get("mana", 0))
	s["costs"] = {"mana": mc}
	if s.has("mana_cost"):
		s.erase("mana_cost") # чтобы не было дублирования форматов

	return s

func _ready() -> void:
	var payload := GameManager.get_battle_payload()
	ENCOUNTER_ENEMIES = Array(payload.get("enemies", [])).duplicate()
	$UI/ActionPanel.connect("action_selected", Callable(self, "_on_action_selected"))
	action_panel.hide()
	get_viewport().connect("size_changed", Callable(self, "_on_viewport_resized"))
	spawn_party()
	var berit := _get_hero_by_name("Berit")
	if action_panel and berit and berit.has_signal("coins_changed"):
		if not berit.is_connected("coins_changed", Callable(action_panel, "_on_berit_coins_changed")):
			berit.connect("coins_changed", Callable(action_panel, "_on_berit_coins_changed"))
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
	
# Накопитель командных трат маны (герои)
var _team_mana_spent_heroes: int = 0

# --- SALLY: helpers for Inspiration ---
func _get_sally_insp(actor: Node) -> int:
	var v := 0
	if actor == null or not is_instance_valid(actor):
		return 0
	# из mechanic
	var mech = actor.mechanic
	if typeof(mech) == TYPE_DICTIONARY and mech.has("inspiration"):
		var node = mech["inspiration"]
		v = int(node.get("value", 0))
	# из meta как запасной источник
	var meta_v := int(actor.get_meta("sally_insp", 0))
	if v == 0 and meta_v > 0:
		v = meta_v
	return v

func _set_sally_insp(actor: Node, v: int) -> void:
	if actor == null or not is_instance_valid(actor):
		return
	var mech = actor.mechanic
	if typeof(mech) != TYPE_DICTIONARY:
		mech = {}
	var node = mech.get("inspiration", {"id":"inspiration", "value":0, "max":3})
	var max_v := int(node.get("max", 3))
	if v < 0:
		v = 0
	if v > max_v:
		v = max_v
	node["value"] = v
	mech["inspiration"] = node
	actor.mechanic = mech
	actor.set_meta("sally_insp", v)            # дублируем в meta на случай потери узла
	actor.set_meta("sally_golden", v >= max_v) # флаг «золота»
	if DEBUG_SALLY and String(actor.nick) == "Sally":
		print("[SALLY][inspiration] set -> ", v, "/", max_v, " golden=", v >= max_v)


func _award_berit_by_team_mana(spent: int, team: String) -> void:
	if spent <= 0:
		return
	# Считаем только траты команды героев (если нужно — легко расширить на врагов)
	if String(team) != "hero":
		return

	_team_mana_spent_heroes += spent
	while _team_mana_spent_heroes >= 20:
		_team_mana_spent_heroes -= 20
		# ищем Берита и выдаём синюю монету
		for h in heroes:
			if is_instance_valid(h) and String(h.nick) == "Berit":
				if h.has_method("add_coin"):
					h.call("add_coin", "blue")
				break

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
				if String(actor.nick) == "Dante":
					var __base := int(actor.attack)
					var __dmg  = _dante_basic_attack_apply_turret(actor, __base)
					await _do_melee_single(actor, tgt, max(1, __dmg), [])
				else:
					await _do_melee_single(actor, tgt, max(1, actor.attack))
				_is_acting = false
				end_turn()
			, "single")
		"skill":
			# всегда работаем с КОПИЕЙ, иначе цены «залипают» в abilities героя
			var skill: Dictionary = (data.duplicate(true) if typeof(data) == TYPE_DICTIONARY else {})

			# убираем временные флаги прошлого каста (на всякий случай)
			if skill.has("__sally_blue"):    skill.erase("__sally_blue")
			if skill.has("__sally_red"):     skill.erase("__sally_red")
			if skill.has("__sally_gold"):    skill.erase("__sally_gold")
			if skill.has("__sally_refunded"):skill.erase("__sally_refunded")

			# восстанавливаем БАЗОВУЮ цену перед любыми цветными модификациями
			var base_costs = skill.get("__base_costs", null)
			if typeof(base_costs) == TYPE_DICTIONARY:
				var costs = skill.get("costs", {})
				if typeof(costs) != TYPE_DICTIONARY:
					costs = {}
				costs["mana"] = int(base_costs.get("mana", costs.get("mana", skill.get("mana_cost", 0))))
				skill["costs"] = costs
				if skill.has("mana_cost"):
					skill.erase("mana_cost")

			_apply_self_effects_if_any(actor, skill)

			# --- Салли: применить синие/красные слова (по описанию) ---
			if String(actor.nick) == "Sally":
				var desc_txt := String(skill.get("desc", skill.get("description", skill.get("text","")))).to_lower()
				var words: Dictionary = actor.get_meta("sally_words", {})
				var blue_w := String(words.get("blue","")).to_lower()
				var red_w  := String(words.get("red","")).to_lower()

				var has_blue := (blue_w != "" and desc_txt.findn(blue_w) != -1)
				var has_red  := (red_w  != "" and desc_txt.findn(red_w)  != -1)

				# Красное: удвоить манакост, если есть
				if has_red:
					var cost = skill.get("costs", skill.get("cost", {}))
					if typeof(cost) == TYPE_DICTIONARY:
						var m0 := int(cost.get("mana", skill.get("mana_cost", 0)))
						if m0 > 0:
							cost["mana"] = m0 * 2
							skill["costs"] = cost
							if skill.has("mana_cost"):
								skill.erase("mana_cost")
					skill["__sally_red"] = true

				# Синее: подмешать усиление из GameManager (только доступные ключи)
				if has_blue:
					var enh := GameManager.get_sally_enhance(String(skill.get("name","")), "blue")
					if typeof(enh) == TYPE_DICTIONARY and not enh.is_empty():
						if enh.has("damage_mult"):    skill["damage_mult"]    = float(enh["damage_mult"])
						if enh.has("heal_mult"):      skill["heal_mult"]      = float(enh["heal_mult"])
						if enh.has("duration_bonus"): skill["duration_bonus"] = int(enh["duration_bonus"])
						if enh.has("free_cost") and bool(enh["free_cost"]):
							var c2 = skill.get("costs", {})
							if typeof(c2) == TYPE_DICTIONARY:
								c2["mana"] = 0
								skill["costs"] = c2
								if skill.has("mana_cost"):
									skill.erase("mana_cost")
					skill["__sally_blue"] = true

				# Если «золото» активно — подмешать золотое усиление и обнулить манакост
				if bool(actor.get_meta("sally_golden", false)):
					var enh_g := GameManager.get_sally_enhance(String(skill.get("name","")), "gold")
					if typeof(enh_g) == TYPE_DICTIONARY and not enh_g.is_empty():
						if enh_g.has("damage_mult"):    skill["damage_mult"]    = float(enh_g["damage_mult"])
						if enh_g.has("heal_mult"):      skill["heal_mult"]      = float(enh_g["heal_mult"])
						if enh_g.has("duration_bonus"): skill["duration_bonus"] = int(enh_g["duration_bonus"])
					var c_gold = skill.get("costs", {})
					if typeof(c_gold) != TYPE_DICTIONARY: c_gold = {}
					c_gold["mana"] = 0
					skill["costs"] = c_gold
					if skill.has("mana_cost"): skill.erase("mana_cost")
					skill["__sally_gold"] = true
			# --- конец блока Салли ---

			# — Попытка усиления Берита ДО выбора ветки —
			if String(actor.nick) == "Berit":
				print("[BERIT] try recipe for '", String(skill.get("name","")), "' coins=", (actor.ether_coins if actor and actor.has_method("coins_count") else []))
				skill = _maybe_apply_berit_enhance(actor, skill)
				if skill.has("__berit_enhanced"): print("[BERIT] enhanced=true")
			

				
			var is_magic := String(skill.get("type","")) == "magic"
			var base_dmg := int(skill.get("damage", actor.attack))
			var eff_tgt: Array = skill.get("effects_to_targets", [])

			var s_target := String(skill.get("target",""))
			if s_target == "single_enemy":
				var list: Array[Node2D] = []
				for e in enemies:
					if is_instance_valid(e) and e.health > 0: list.append(e)
				if list.is_empty(): end_turn(); return

				_build_target_overlay(actor, list, func(targets: Array) -> void:
					if not _can_pay_cost(actor, skill):
						show_player_options(actor)
						return
					var mana_before = actor.mana
					_pay_cost(actor, skill)

					var tgt: Node2D = targets[0]
					if String(actor.nick) == "Dante" and _dante_can_enhance(actor, skill):
						skill = _dante_build_enhanced_skill(actor, skill)
						_dante_consume_charge(actor, skill)
					# если есть множитель урона — учитываем его
					if skill.has("damage_mult"):
						var dm := float(skill.get("damage_mult", 1.0))
						var dmg_now := int(round(max(1.0, float(base_dmg) * dm)))
						base_dmg = max(1, dmg_now)
					if skill.has("qte"):
						await _perform_with_qte(actor, [tgt], skill)   # ← QTE-путь
					else:
						_is_acting = true
						if is_magic:
							await _do_magic_single(actor, tgt, max(1, base_dmg), eff_tgt)
						else:
							await _do_melee_single(actor, tgt, max(1, base_dmg), eff_tgt)
						_is_acting = false

					# ADD: сколько реально потрачено маны (до возможного возврата)
					var spent_for_award = max(0, mana_before - actor.mana)
					_award_berit_by_team_mana(spent_for_award, actor.team)  # ADD

					# возврат маны Салли — только «синее» и не «красное/золото», и только один раз
					if String(actor.nick) == "Sally" \
					and bool(skill.get("__sally_blue", false)) \
					and not bool(skill.get("__sally_red", false)) \
					and not bool(skill.get("__sally_gold", false)) \
					and not bool(skill.get("__sally_refunded", false)):
						if spent_for_award > 0:
							actor.mana = min(actor.max_mana, actor.mana + spent_for_award * 2)
						skill["__sally_refunded"] = true   # ADD: защита от дубля

					# пост-обновление вдохновения (механика + мета) / сброс «золота»
					# пост-обновление вдохновения
					_sally_apply_inspiration_after_cast(actor, skill)

					if String(actor.nick) == "Dante":
						_dante_apply_collected_fx(actor, skill, [tgt])
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
					var mana_before = actor.mana
					_pay_cost(actor, skill)
					# --- DANTE: усиление и списание ---
					if String(actor.nick) == "Dante" and _dante_can_enhance(actor, skill):
						skill = _dante_build_enhanced_skill(actor, skill)
						_dante_consume_charge(actor, skill)
					if skill.has("damage_mult"):
						var dm := float(skill.get("damage_mult", 1.0))
						var dmg_now := int(round(max(1.0, float(base_dmg) * dm)))
						base_dmg = max(1, dmg_now)
					if skill.has("qte"):
						await _perform_with_qte(actor, list_all, skill)  # ← QTE-путь и для массовых
					else:
						_is_acting = true
						if is_magic:
							await _do_magic_aoe(actor, max(1, base_dmg), eff_tgt)
						else:
							await _do_melee_aoe(actor, max(1, base_dmg), eff_tgt)
						_is_acting = false

					# ADD: трата маны -> монеты Бериту
					var spent_for_award = max(0, mana_before - actor.mana)
					_award_berit_by_team_mana(spent_for_award, actor.team)  # ADD

					# возврат маны Салли — только «синее» и не «красное/золото», и только один раз
					if String(actor.nick) == "Sally" \
					and bool(skill.get("__sally_blue", false)) \
					and not bool(skill.get("__sally_red", false)) \
					and not bool(skill.get("__sally_gold", false)) \
					and not bool(skill.get("__sally_refunded", false)):
						if spent_for_award > 0:
							actor.mana = min(actor.max_mana, actor.mana + spent_for_award * 2)
						skill["__sally_refunded"] = true  # ADD

					# пост-обновление вдохновения
					_sally_apply_inspiration_after_cast(actor, skill)
					if String(actor.nick) == "Dante":
						_dante_apply_collected_fx(actor, skill, list_all)
					end_turn()
				, "all")

			elif s_target == "self":
				var list_self: Array[Node2D] = []
				if is_instance_valid(actor) and actor.health > 0:
					list_self.append(actor)
				if list_self.is_empty():
					end_turn()
					return

				_build_target_overlay(actor, list_self, func(_targets: Array) -> void:
					if not _can_pay_cost(actor, skill):
						show_player_options(actor)
						return

					var mana_before = actor.mana
					_pay_cost(actor, skill)

					if String(actor.nick) == "Dante" and _dante_can_enhance(actor, skill):
						skill = _dante_build_enhanced_skill(actor, skill)
						_dante_consume_charge(actor, skill)

					if skill.has("qte"):
						await _perform_with_qte(actor, [actor], skill)
					else:
						_is_acting = true
						await _do_support(actor, actor, skill)
						_is_acting = false

					# монеты Бериту за трату маны
					var spent_for_award = max(0, mana_before - actor.mana)
					_award_berit_by_team_mana(spent_for_award, actor.team)

					# возврат маны Салли (только blue, без red/gold, один раз)
					if String(actor.nick) == "Sally" \
					and bool(skill.get("__sally_blue", false)) \
					and not bool(skill.get("__sally_red", false)) \
					and not bool(skill.get("__sally_gold", false)) \
					and not bool(skill.get("__sally_refunded", false)):
						if spent_for_award > 0:
							actor.mana = min(actor.max_mana, actor.mana + spent_for_award * 2)
						skill["__sally_refunded"] = true

					# пост-обновления
					_sally_apply_inspiration_after_cast(actor, skill)
					if String(actor.nick) == "Dante":
						_dante_apply_collected_fx(actor, skill, [actor])

					end_turn()
				, "single")

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
					var mana_before = actor.mana
					_pay_cost(actor, skill)
					if String(actor.nick) == "Dante" and _dante_can_enhance(actor, skill):
						skill = _dante_build_enhanced_skill(actor, skill)
						_dante_consume_charge(actor, skill)
					var tgt_local: Node2D = targets[0]

					_is_acting = true
					await _do_support(actor, tgt_local, skill)  # ← передаём весь словарь умения
					_is_acting = false

					# ADD: трата маны -> монеты Бериту
					var spent_for_award = max(0, mana_before - actor.mana)
					_award_berit_by_team_mana(spent_for_award, actor.team)  # ADD

					# возврат маны Салли — только «синее» и не «красное/золото», и только один раз
					if String(actor.nick) == "Sally" \
					and bool(skill.get("__sally_blue", false)) \
					and not bool(skill.get("__sally_red", false)) \
					and not bool(skill.get("__sally_gold", false)) \
					and not bool(skill.get("__sally_refunded", false)):
						if spent_for_award > 0:
							actor.mana = min(actor.max_mana, actor.mana + spent_for_award * 2)
						skill["__sally_refunded"] = true  # ADD

					# пост-обновление вдохновения
					_sally_apply_inspiration_after_cast(actor, skill)
					if String(actor.nick) == "Dante":
						_dante_apply_collected_fx(actor, skill, [tgt_local])
					end_turn()
				, "single")

			elif s_target == "all_allies":
				var group: Array[Node2D] = []
				if actor.team == "hero":
					for h in heroes:
						if is_instance_valid(h) and h.health > 0:
							group.append(h)
				else:
					for e in enemies:
						if is_instance_valid(e) and e.health > 0:
							group.append(e)

				if group.is_empty():
					end_turn()
					return

				if not _can_pay_cost(actor, skill):
					show_player_options(actor)
					return
				var mana_before = actor.mana
				_pay_cost(actor, skill)
				if String(actor.nick) == "Dante" and _dante_can_enhance(actor, skill):
					skill = _dante_build_enhanced_skill(actor, skill)
					_dante_consume_charge(actor, skill)
				if skill.has("qte"):
					await _perform_with_qte(actor, group, skill)  # ← теперь баффы союзников тоже через QTE
				else:
					# старый «без QTE» путь — оставить как запасной
					_is_acting = true
					var ap = actor.anim
					var clip := "cast"
					if ap != null:
						if ap.has_animation("cast"):
							clip = "cast"
						elif ap.has_animation("skill"):
							clip = "skill"
					_play_if_has(ap, clip)
					var clip_len := 0.5
					if ap != null and ap.has_animation(clip):
						clip_len = ap.get_animation(clip).length
					var apply_delay = clamp(0.30 * clip_len, 0.06, 0.60)
					await get_tree().create_timer(apply_delay).timeout
					if skill.has("heal"):
						var heal := int(skill.get("heal", 0))
						for ally in group:
							ally.health = min(ally.max_health, max(0, ally.health + heal))
					var effs: Array = skill.get("effects_to_targets", [])
					if effs.size() > 0:
						for ally in group: _apply_effects(effs, ally)
					await _wait_anim_end(ap, clip, 1.2)
					_play_if_has(ap, "idle")
					_is_acting = false

				# ADD: трата маны -> монеты Бериту
				var spent_for_award = max(0, mana_before - actor.mana)
				_award_berit_by_team_mana(spent_for_award, actor.team)  # ADD

				# возврат маны Салли — только «синее» и не «красное/золото», и только один раз
				if String(actor.nick) == "Sally" \
				and bool(skill.get("__sally_blue", false)) \
				and not bool(skill.get("__sally_red", false)) \
				and not bool(skill.get("__sally_gold", false)) \
				and not bool(skill.get("__sally_refunded", false)):
					if spent_for_award > 0:
						actor.mana = min(actor.max_mana, actor.mana + spent_for_award * 2)
					skill["__sally_refunded"] = true  # ADD

				# пост-обновление вдохновения
				_sally_apply_inspiration_after_cast(actor, skill)
				if String(actor.nick) == "Dante":
					_dante_apply_collected_fx(actor, skill, group)
				end_turn()

		"item":
			var item_id := String(data)
			_handle_item_use(actor, item_id)

		"skip":
			end_turn()
			
func _handle_item_use(user: Node2D, item_id: String) -> void:
	if user == null or not is_instance_valid(user):
		show_player_options(current_actor)
		return

	var def := GameManager.get_item_def(item_id)
	if def.is_empty():
		show_player_options(user)
		return

	# если герой не может использовать эту категорию
	if user.has_method("can_use_item"):
		if not user.call("can_use_item", item_id):
			show_player_options(user)
			return

	var tgt_mode := String(def.get("target", "self"))

	if tgt_mode == "self":
		_is_acting = true
		await _apply_item(user, user, item_id, def)
		_is_acting = false
		# после применения предмета
		if user != null and String(user.nick) == "Berit":
			user.add_coin("yellow")
		end_turn()
		return

	if tgt_mode == "single_ally":
		var allies: Array[Node2D] = []
		var pool: Array[Node2D] = []
		if user.team == "hero":
			pool = heroes
		else:
			pool = enemies
		for a in pool:
			if is_instance_valid(a) and a.health > 0:
				allies.append(a)
		if allies.size() == 0:
			show_player_options(user)
			return

		_build_target_overlay(user, allies, func(targets: Array) -> void:
			var tgt_local: Node2D = targets[0]
			_is_acting = true
			await _apply_item(user, tgt_local, item_id, def)
			_is_acting = false
			if user != null and String(user.nick) == "Berit":
				user.add_coin("yellow")
			end_turn()
		, "single")
		return

	if tgt_mode == "all_allies":
		var group: Array[Node2D] = []
		if user.team == "hero":
			group = heroes
		else:
			group = enemies
		_is_acting = true
		for g in group:
			if is_instance_valid(g) and g.health > 0:
				await _apply_item(user, g, item_id, def, true)
		_is_acting = false
		if user != null and String(user.nick) == "Berit":
			user.add_coin("yellow")
		end_turn()
		return

	# при желании можно добавить "single_enemy"/"all_enemies" для боевых бомб и т.п.
	show_player_options(user)


func _apply_item(user: Node2D, target: Node2D, id: String, def: Dictionary, skip_anim := false) -> void:
	# списываем из ЛИЧНОГО рюкзака; если нет — ничего не делаем
	if not user.pack_consume(id, 1):
		return

	# играем «поддерживающую» анимацию — она же отработает heal/эффекты если мы соберём ability-словарь
	var effect := String(def.get("effect",""))
	var ability := {}

	# 1) лечение — полностью отдаём в _do_support (он корректно лечит по "heal")
	if effect == "heal":
		ability["heal"] = int(def.get("heal", 0))

	# 2) бафф — завернём в effects_to_self/targets, тогда _do_support сам навесит эффекты
	if effect == "buff":
		var b = def.get("buff", {})
		if typeof(b) == TYPE_DICTIONARY:
			var ex := {
				"type": "stat_buff",
				"stat": String(b.get("stat","attack")),
				"amount": int(b.get("amount", 0)),
				"duration": int(b.get("duration", 1))
			}
			# если цель — сам пользователь, кладём в effects_to_self, иначе — на цель
			if target == user:
				ability["effects_to_self"] = [ex]
			else:
				ability["effects_to_targets"] = [ex]

	# анимация (если не попросили пропустить)
	if not skip_anim:
		await _do_support(user, target, ability)

	# 3) восполнение маны — _do_support не делает этого, поэтому применим прямо тут
	if effect == "restore_mana":
		var mp := int(def.get("mana", 0))
		target.mana = min(target.max_mana, target.mana + mp)

	# 4) прямой урон предметом (если потребуется позже)
	if effect == "damage":
		var dmg := int(def.get("damage", 0))
		target.health = max(0, target.health - dmg)
		if target.health <= 0:
			_on_enemy_died(target)

	# на всякий — обновим подписи на кнопках предметов
	if action_panel and action_panel.visible:
		action_panel.update_item_buttons()
			
func _eff_speed(ch: Node2D) -> float:
	if ch != null and is_instance_valid(ch) and ch.has_method("effective_stat"):
		return float(ch.call("effective_stat", "speed"))
	return float(ch.speed)
	
func _apply_effects(list: Array, target: Node2D) -> void:
	if target == null or not is_instance_valid(target): return
	if not target.has_method("add_effect"): return
	var debuffs_applied := 0
	for ex in list:
		target.call("add_effect", ex)
		if target.team == "enemy" and not bool(ex.get("is_buff", false)):
			debuffs_applied += 1

	if debuffs_applied > 0 and _party_has("Dante"):
		_enemy_debuff_applied += debuffs_applied
		if debuffs_applied > 0:
			_dante_add_charge(3 * debuffs_applied, "team_debuffs")
		var berit := _get_hero_by_name("Berit")
		
		while _enemy_debuff_applied >= 3:
			_enemy_debuff_applied -= 3
			_dante_inc_mul(2)
			if berit != null:
				berit.add_coin("green")

# —————————  СОЗДАЁМ  ГЕРОЕВ  —————————
func spawn_party() -> void:
	heroes.clear()
	var party_data := GameManager.make_party_dicts()
	var count = min(hero_slots.get_child_count(), party_data.size())
	for i in range(count):
		var slot: Node2D = hero_slots.get_child(i)
		var hero: Node2D  = CHAR_SCN.instantiate()
		slot.add_child(hero)
		GameManager.apply_battle_start_augments(hero, hero.nick)
		hero.position = Vector2.ZERO
		hero.init_from_dict(party_data[i])
		heroes.append(hero)

func _segments_to_pairs(raw: Array) -> Array:
	var out: Array = []
	for seg in raw:
		if typeof(seg) == TYPE_ARRAY and seg.size() >= 2:
			out.append([float(seg[0]), float(seg[1])])
		elif typeof(seg) == TYPE_DICTIONARY:
			var a := float(seg.get("start", 0.45))
			var b := float(seg.get("end",   0.55))
			out.append([a, b])
	return out
	
func _defense_single(duration: float, segments: Array, target: Node2D) -> Dictionary:
	if defense_qte == null:
		return {"type":"none","grade":"fail"}
	var dodge_w := DODGE_WINDOW_DEFAULT
	var block_w := BLOCK_WINDOW_DEFAULT
	# читаем окна именно у защитника (героя), если заданы
	if target != null and is_instance_valid(target):
		if target.has_method("get_defense_windows"):
			var w = target.call("get_defense_windows")
			if typeof(w) == TYPE_DICTIONARY:
				if w.has("dodge"): dodge_w = float(w["dodge"])
				if w.has("block"): block_w = float(w["block"])
		else:
			if target.has_meta("dodge_window"): dodge_w = float(target.get_meta("dodge_window"))
			if target.has_meta("block_window"): block_w = float(target.get_meta("block_window"))
	defense_qte.call("start", duration, segments, dodge_w, block_w, "single")
	var res: Dictionary = await defense_qte.finished
	return res

func _defense_aoe(duration: float, segments: Array) -> Dictionary:
	if defense_qte == null:
		return {"type":"none","grade":"fail"}
	# групповая защита — общее окно по умолчанию
	defense_qte.call("start", duration, segments, DODGE_WINDOW_DEFAULT, BLOCK_WINDOW_DEFAULT, "aoe")
	var res: Dictionary = await defense_qte.finished
	return res

func _apply_damage_with_defense(base_damage: int, defres: Dictionary) -> int:
	var t := String(defres.get("type","none"))
	var g := String(defres.get("grade","fail"))

	# Уклон — надёжнее: любой успех = 100% уклон (потом можно расширить логикой контры)
	if t == "dodge":
		if g == "good" or g == "perfect":
			return 0

	# Блок: good — частичное снижение, perfect — полный блок
	if t == "block":
		if g == "perfect":
			return 0
		if g == "good":
			var red = clamp(BLOCK_REDUCE_DEFAULT, 0.0, 1.0)
			return int(round(float(base_damage) * (1.0 - red)))

	# промах по защите — полный урон
	return base_damage

# ————————— СОЗДАЁМ  ВРАГОВ —————————
func spawn_enemies() -> void:
	enemies.clear()
	var count = min(enemy_slots.get_child_count(), ENCOUNTER_ENEMIES.size())
	for j in range(count):
		var slot: Node2D = enemy_slots.get_child(j)
		var foe: Node2D  = CHAR_SCN.instantiate()
		slot.add_child(foe)
		foe.position = Vector2.ZERO

		# грузим деф из БД
		var def := GameManager.get_enemy_def(ENCOUNTER_ENEMIES[j])
		if typeof(def) == TYPE_DICTIONARY and def.size() > 0:
			if foe.has_method("init_from_dict"):
				foe.call("init_from_dict", def)
			else:
				# фолбэк
				foe.team = "enemy"
				foe.nick = String(def.get("nick","Enemy"))
				foe.max_health = int(def.get("max_health", 70))
				foe.health = foe.max_health
				foe.attack = int(def.get("attack", 8))
				foe.defense = int(def.get("defense", 3))
				foe.speed = int(def.get("speed", 7))
				foe.abilities = def.get("abilities", [])
				foe.set_meta("ai_style", String(def.get("ai_style", "агрессивный")))
		else:
			# совсем фолбэк, если БД не нашлась
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

	# выбираем только тех, кто не «съеден»
	for i in range(all.size()):
		var ch = all[i]
		if not is_instance_valid(ch): continue
		if _is_devoured(ch): continue
		var time_to_full = (TURN_THRESHOLD - ch.turn_meter) / max(1.0, _eff_speed(ch))
		if time_to_full < min_time:
			min_time = time_to_full
			best_idx = i

	# если (патологично) не нашли — берём первого валидного
	if best_idx == -1:
		for i in range(all.size()):
			if is_instance_valid(all[i]):
				best_idx = i
				min_time = (TURN_THRESHOLD - all[i].turn_meter) / max(1.0, _eff_speed(all[i]))
				break

	# прокрутка времени всем
	for ch in all:
		if is_instance_valid(ch):
			ch.turn_meter += _eff_speed(ch) * min_time

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
	if String(actor.nick) == "Sally" and actor.has_effect("psychopathy"):
		action_panel.hide()
		await _sally_psycho_auto(actor)
		end_turn()
		return
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

func _on_pick_pressed(btn: Button) -> void:
	if not _pick_mode: return
	if not _pick_map.has(btn): return
	var target: Node2D = _pick_map[btn]
	# На всякий — завершаем режим выбора и возвращаем панель действий
	_leave_pick_mode(true)
	print("[PICK] выбран таргет: ", (target.nick if target and is_instance_valid(target) else "<null>"))

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
		if user.anim.has_animation("item use"):
			clip = "item use"
		elif user.anim.has_animation("cast"):
			clip = "cast"
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
		var old_hp = target.health
		var new_hp = clamp(old_hp + heal, 0, target.max_health)
		target.health = new_hp
		var delta = new_hp - old_hp
		if delta > 0:
			_show_popup_number(target, delta, "heal")

	# Эффекты
	var effs_to_target: Array = ability.get("effects_to_targets", [])
	if effs_to_target.size() > 0:
		_apply_effects(effs_to_target, target)
		_dante_add_charge(2, "buff")

	var effs_to_self: Array = ability.get("effects_to_self", [])
	if effs_to_self.size() > 0:
		_apply_effects(effs_to_self, user)
		_dante_add_charge(2, "self_buff")

	await _wait_anim_end(user.anim, clip, 1.2)
	_play_if_has(user.anim, "idle")

func _apply_melee_hit(target: Node2D, damage: int, gate: Dictionary, effects_to_targets: Array = [], source: Node2D = null, is_crit := false) -> void:
	if gate.get("done", false): return
	gate["done"] = true
	if not is_instance_valid(target): return

	# попап: сначала показать, потом применить
	if damage > 0:
		_show_popup_number(target, damage, ("crit" if is_crit else "dmg"), is_crit)

	target.health = max(0, target.health - damage)

	# эффекты на цель
	if effects_to_targets.size() > 0:
		_apply_effects(effects_to_targets, target)

	# лёгкая тряска
	var base := target.position
	var mover: Node2D = target.get_node_or_null("MotionRoot") as Node2D
	if mover == null:
		mover = target
	var before := mover.global_position
	print("[SHAKE] start target=", target.nick, " pos=", before)

	# лёгкая тряска (через MotionRoot, в глобальных координатах)
	

	print("[SHAKE] start target=", target.nick, " pos=", before)

	var tw := create_tween().set_trans(Tween.TRANS_SINE)
	tw.tween_property(mover, "global_position", before + Vector2(4, 0), 0.05)
	tw.tween_property(mover, "global_position", before - Vector2(3, 0), 0.05)
	tw.tween_property(mover, "global_position", before, 0.05)
	await tw.finished

	var after := mover.global_position
	var moved := false
	if after != before:
		moved = true
	print("[SHAKE] end   target=", target.nick, " pos=", after, " moved=", moved, " delta=", after - before)

	if target.health <= 0:
		_on_enemy_died(target)
	check_battle_end()

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
	var hit_pos   := _approach_point_for(user, target)  # см. п.2, больше не передаём dist руками

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
		var sp: Vector2
		if cam:
			sp = cam.unproject_position(e.global_position)
		else:
			sp = e.global_position
		btn.position = sp + Vector2(-45, -96)
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
	if cam:
		return cam.get_screen_center_position()
	return Vector2.ZERO

func _approach_point(user: Node2D, target: Node2D) -> Vector2:
	var p1 := target.global_position
	var y := (p1.y if LOCK_Y_TO_TARGET else user.global_position.y) + APPROACH_Y
	var x := p1.x - APPROACH_X        # по умолчанию слева (для героев)
	if user != null and is_instance_valid(user):
		if String(user.team) == "enemy":
			x = p1.x + APPROACH_X    # враги — справа от цели
	return Vector2(x, y)

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
		

func _sally_sync_inspiration_ui() -> void:
	# Находим Салли среди героев и дёргаем UI-механику из meta
	for h in heroes:
		if is_instance_valid(h) and String(h.nick) == "Sally":
			var v := int(h.get_meta("sally_insp", 0))
			# Поддерживаем «золото» как флаг в meta
			h.set_meta("sally_golden", v >= 3)
			# Обновляем отображение механики на карточке
			if h.has_method("set_mechanic"):
				h.call("set_mechanic", "inspiration", "Вдохновение", 0, 3, v)
			elif h.has_method("set_mechanic_value"):
				h.call("set_mechanic_value", v)
			if DEBUG_SALLY:
				print("[SALLY][sync] meta=", v, " golden=", bool(h.get_meta("sally_golden", false)))
			return

func _sally_apply_inspiration_after_cast(actor: Node, skill: Dictionary) -> void:
	if String(actor.nick) != "Sally":
		return

	# Инициализируем механику, если её ещё нет/не та
	var mech: Dictionary = actor.get_mechanic()
	if String(mech.get("id","")) != "inspiration":
		# создаём «каркас», значение берём если вдруг уже было
		var init_val := int(mech.get("value", 0))
		actor.mechanic = {"id":"inspiration","name":"Вдохновение","value":init_val,"max":3}
		mech = actor.get_mechanic()

	var v := int(mech.get("value", 0))
	var v0 := v

	# +1 только за «синее» и если НЕ «красное»
	if bool(skill.get("__sally_blue", false)) and not bool(skill.get("__sally_red", false)):
		v = min(3, v + 1)

	# «золотое» умение сбрасывает стаки
	if bool(skill.get("__sally_gold", false)):
		v = 0
		actor.set_meta("sally_golden", false)

	# ВАЖНО: меняем через API, чтобы UI/карточка подхватили (signal mechanic_changed)
	actor.set_meta("sally_insp", v)
	actor.set_meta("sally_golden", v >= 3)

	if DEBUG_SALLY:
		print("[SALLY][inspiration] before=", v0, " after=", v, " golden=", bool(actor.get_meta("sally_golden", false)))


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
	# --- DEBUG: логируем проверку оплаты для Салли ---
	if DEBUG_SALLY and String(user.nick) == "Sally":
		var dbg_cost := {"hp": hp, "mana": mp, "stamina": st}
		print("[SALLY][can_pay] mana=", user.mana, "/", user.max_mana, " cost=", dbg_cost)
	if hp > 0 and user.health <= hp: return false    # не даём умереть оплатой
	if mp > 0 and user.mana   <  mp: return false
	if st > 0 and user.stamina < st: return false
	return true

func _pay_cost(user: Node2D, data: Dictionary) -> void:
	# 1) Нормализуем формат стоимости (сливаем старый cost_type/cost в costs)
	var costs: Dictionary = {}
	var src_costs: Dictionary = data.get("costs", {})
	for k in src_costs.keys():
		costs[String(k)] = int(src_costs[k])

	var ct = data.get("cost_type", null)
	var c  = int(data.get("cost", 0))
	if ct != null and c > 0:
		var key := String(ct)
		costs[key] = int(costs.get(key, 0)) + c

	if costs.size() == 0:
		return

	# 2) Считаем потраченную ману ОДИН раз, после нормализации
	var spent_hp  := int(costs.get("hp", 0))
	var spent_mp  := int(costs.get("mana", 0))
	var spent_sta := int(costs.get("stamina", 0))
	var __sally_before_mana = user.mana
	# 3) Применяем
	if spent_hp > 0:
		user.health  = max(1, user.health  - spent_hp)   # не умираем оплатой
	if spent_mp > 0:
		user.mana    = max(0, user.mana    - spent_mp)
	if spent_sta > 0:
		user.stamina = max(0, user.stamina - spent_sta)
		# --- DEBUG: факт оплаты ---
	if DEBUG_SALLY and String(user.nick) == "Sally" and spent_mp > 0:
		print("[SALLY][pay_cost] spent_mp=", spent_mp, " before=", __sally_before_mana, " after=", user.mana)
	# 4) Синие монеты Бериту: суммируем всю потраченную героями ману, если в партии есть Sally
	if spent_mp > 0 and user.team == "hero" and _party_has("Sally"):
		_mana_spent_pool += spent_mp
		var berit := _get_hero_by_name("Berit")
		while _mana_spent_pool >= 20 and berit != null:
			_mana_spent_pool -= 20
			berit.add_coin("blue")   # Character.gd должен эмитить coins_changed

func _maybe_apply_berit_enhance(actor: Node2D, skill: Dictionary) -> Dictionary:
	if actor == null or not is_instance_valid(actor): return skill
	if String(actor.nick) != "Berit": return skill

	var name := String(skill.get("name","")).strip_edges()
	var recipe := GameManager.get_berit_recipe(name)
	if recipe.is_empty():
		print("[BERIT] no recipe for '", name, "'.")
		return skill

	if not actor.can_pay_coins(recipe.get("consume", {})):
		print("[BERIT] recipe exists for '", name, "' but coins are not enough. have=", actor.ether_coins, " need=", recipe.get("consume", {}))
		return skill

	print("[BERIT] APPLY recipe for '", name, "'. before=", actor.ether_coins)

	# 1) списать
	actor.pay_coins(recipe.get("consume", {}))
	# 2) выдать
	var grants: Dictionary = recipe.get("grant", {})
	for k in grants.keys():
		for i in range(int(grants[k])): actor.add_coin(k)

	# 3) собрать усиленную копию
	var enhanced := skill.duplicate(true)
	var enh = recipe.get("enhance", {})

	if enh.has("damage_mult"):
		var d := int(enhanced.get("damage", actor.attack))
		enhanced["damage"] = int(round(d * float(enh["damage_mult"])))

	if enh.has("target"):
		enhanced["target"] = String(enh["target"])  # например "all_enemies"

	enhanced["__berit_enhanced"] = true
	print("[BERIT] OK. after=", actor.ether_coins, " target=", String(enhanced.get("target","")), " dmg=", int(enhanced.get("damage", 0)))
	return enhanced


func process_turn():
	if _battle_over:
		return
	var ch: Node2D = _pick_next_actor()
	_sally_sync_inspiration_ui()
	if _is_action_blocked(ch):
		# DoT + универсальные моды (например, mana_drain_per_turn)
		if ch.has_method("get_effects"):
			var arr: Array = ch.call("get_effects")
			for e in arr:
				if typeof(e) != TYPE_DICTIONARY:
					continue
				# DoT
				if e.has("dot"):
					ch.health = max(0, ch.health - int(e.get("dot", 0)))
				# универсальный дрен маны по модификатору
				var mods: Dictionary = e.get("mods", {})
				if mods.has("mana_drain_per_turn"):
					ch.mana = max(0, ch.mana - int(mods.get("mana_drain_per_turn", 0)))

		# Тик длительностей (чтобы стан и пр. сходили)
		if ch.has_method("tick_effects_duration"):
			ch.call("tick_effects_duration")

		# Если умер от DoT — просто завершаем ход (дальнейшая логика и так разрулит)
		end_turn()
		return

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
	# ── Sally: восстановить value из meta в саму механику до UI/кнопок
	if String(ch.nick) == "Sally":
		var v := int(ch.get_meta("sally_insp", 0))
		var mech = ch.mechanic
		if typeof(mech) != TYPE_DICTIONARY: mech = {}
		mech["id"] = "inspiration"
		mech["name"] = "Вдохновение"
		mech["max"] = 3
		mech["value"] = clamp(v, 0, 3)
		ch.mechanic = mech
		if DEBUG_SALLY:
			print("[SALLY][turn_begin] restore=", v)

	if is_instance_valid(current_actor) and String(current_actor.nick) == "Sally":
		var mech = current_actor.mechanic
		if typeof(mech) != TYPE_DICTIONARY:
			mech = {}

		var has_insp = typeof(mech) == TYPE_DICTIONARY and mech.has("inspiration")
		if not has_insp:
			var v_meta := int(current_actor.get_meta("sally_insp", 0))
			if v_meta > 0:
				mech["inspiration"] = {"id":"inspiration","name":"Вдохновение","value":v_meta,"max":3}
				current_actor.mechanic = mech
				if DEBUG_SALLY:
					print("[SALLY][insp_restore] restored_from_meta=", v_meta)

		# чисто для лога текущего значения (без перезаписи!)
		var v_dbg := 0
		if typeof(current_actor.mechanic) == TYPE_DICTIONARY and current_actor.mechanic.has("inspiration"):
			v_dbg = int(current_actor.mechanic["inspiration"].get("value", 0))
		if DEBUG_SALLY:
			print("[SALLY][turn_begin] insp=", v_dbg)
	turn_queue = _panel_order_with_current_first(ch)
	var t1 := Time.get_ticks_msec()
	await _animate_stepwise_to(turn_queue)
	print("[TURN] anim waited ", Time.get_ticks_msec()-t1, "ms before action/panel")

	if ch.team == "hero":
		show_player_options(ch)
	else:
		enemy_action(ch)

func _has_dante(arr) -> bool:
	for h in arr:
		if h != null and is_instance_valid(h) and String(h.nick) == "Dante":
			return true
	return false

func end_turn():
	if _battle_over:
		return
	action_panel.hide()
	turn_queue = _panel_order_next()
	await _animate_stepwise_to(turn_queue)
	_print_order("AFTER_END")          # прогноз на следующий ход
	_debug_icons_positions("AFTER_END")
	process_turn()
	
func enemy_action(enemy: Node2D) -> void:
	var action = choose_enemy_action(enemy)
	if action == null:
		print("[TURN] ", enemy.nick, " — нет действия, пропуск")
		end_turn()
		return

	print("[TURN] ", enemy.nick, " начинает действие: ", String(action.get("name","<безымянное>")))
	await perform_action(enemy, action)
	print("[TURN] ", enemy.nick, " завершил действие")
	end_turn()
	
func choose_enemy_action(enemy: Node2D) -> Variant:
	if enemy == null or not is_instance_valid(enemy):
		return null

	var style := _ai_style_of(enemy)
	var cats := _ai_split_abilities(enemy)

	# — СНАЧАЛА спец-умения: если условия выполняются — выполняем сразу —
	var special_pick = _ai_try_special(enemy)
	if special_pick != null:
		return special_pick

	# — БАЗОВЫЕ ВЕСА —
	var W := _ai_base_weights(style)

	# ситуативные поправки
	var ally_pool: Array[Node2D] = enemies
	var low_ally := _ally_lowest_hp(ally_pool)
	if low_ally != null:
		var ratio = float(low_ally.health) / max(1, low_ally.max_health)
		if ratio <= 0.40 and cats["heal"].size() > 0: W["heal"] *= 2.0
		elif ratio <= 0.65 and cats["heal"].size() > 0: W["heal"] *= 1.4

	if _ai_need_self_buff(enemy, cats["self_buff"]):
		W["self_buff"] *= 1.6
	else:
		W["self_buff"] *= 0.35

	var lock := int(enemy.get_meta("ai_after_buff_attacks_left") if enemy.has_meta("ai_after_buff_attacks_left") else 0)
	if lock > 0:
		W["self_buff"] *= 0.1
		enemy.set_meta("ai_after_buff_attacks_left", lock - 1)

	# коварный — фокус на одной цели, больше дебаффов/солото-атак
	if style == "cunning":
		W["attack_single"] *= 1.5
		W["debuff"] *= 1.4

	if style == "support" and cats["ally_buff"].size() > 0:
		W["ally_buff"] *= 1.4

	for key in W.keys():
		if cats.has(key) and cats[key].size() == 0:
			W[key] = 0.0

	var cat := _weighted_choice(W)
	if cat == "":
		if cats["attack_single"].size() > 0: cat = "attack_single"
		elif cats["attack_aoe"].size() > 0: cat = "attack_aoe"
		elif cats["debuff"].size() > 0: cat = "debuff"
		elif cats["self_buff"].size() > 0: cat = "self_buff"
		elif cats["ally_buff"].size() > 0: cat = "ally_buff"
		elif cats["heal"].size() > 0: cat = "heal"
		else:
			return null

	var choice: Dictionary = (cats[cat][randi() % cats[cat].size()]).duplicate(true)

	# таргетинг без гипноза/частностей
	match cat:
		"heal":
			if String(choice.get("target","")) == "single_ally":
				choice["target_instance"] = low_ally if low_ally != null else _random_alive(ally_pool)

		"ally_buff":
			if String(choice.get("target","")) == "single_ally":
				var tgt := _ally_lowest_hp(ally_pool)
				choice["target_instance"] = tgt if tgt != null else _random_alive(ally_pool)

		"self_buff":
			enemy.set_meta("ai_after_buff_attacks_left", 2)

		"debuff":
			var tgt_d: Node2D = null
			if style == "cunning":
				tgt_d = _ai_get_focus(enemy)
			else:
				tgt_d = _random_alive(heroes)
			if String(choice.get("target","")) == "single_enemy":
				choice["target_instance"] = (tgt_d if tgt_d != null else _random_alive(heroes))

		"attack_single":
			var tgt_a: Node2D = null
			if style == "cunning":
				tgt_a = _ai_get_focus(enemy)
			if tgt_a == null:
				tgt_a = _ally_lowest_hp(heroes)
			if tgt_a == null:
				tgt_a = _random_alive(heroes)
			choice["target_instance"] = tgt_a

		"attack_aoe":
			pass

	var tgt_dbg = choice.get("target_instance", null)
	print("[AI] ", enemy.nick, " style=", style, " picked=", String(choice.get("name","<unnamed>")),
		" cat=", cat, " tgt=", (tgt_dbg.nick if tgt_dbg and is_instance_valid(tgt_dbg) else "(group/none)"))
	return choice


func _enemy_perform_with_qte(user: Node2D, targets: Array[Node2D], ability: Dictionary) -> void:
	if user == null or not is_instance_valid(user): return
	if targets.is_empty(): return

	var s_target := String(ability.get("target",""))
	var is_aoe := s_target == "all_enemies"
	var typ := String(ability.get("type",""))
	var dmg_base := int(ability.get("damage", user.attack))
	var effs: Array = ability.get("effects_to_targets", [])
	var crit_ch := float(ability.get("crit", 0.0))

	# — камера/вступление —
	_enter_cinematic(user, targets)
	_update_enemy_bars_positions()
	if is_aoe:
		var focus := _aoe_focus_point()
		var side := AOE_CAM_SHIFT_PX
		if typ == "magic":
			side = MAGIC_CAM_SHIFT_PX
		if user != null and user.team == "enemy":
			side = -side
		if user.team == "enemy": side = -abs(side)
		var tag := "ENEMY_AOE"
		if typ == "magic":
			tag = "ENEMY_AOE_MAGIC"
		await _push_focus_with_screen_shift(focus, AOE_CAM_ZOOM, side, tag)
	else:
		var tgt: Node2D = targets[0]
		if typ == "magic":
			var mid := (user.global_position + tgt.global_position) * 0.5
			var side2 := MAGIC_CAM_SHIFT_PX
			if user != null and user.team == "enemy":
				side2 = -side2
			await _push_focus_with_screen_shift(mid, MAGIC_SINGLE_ZOOM, side2, "ENEMY_SINGLE_MAGIC")
		else:
			await _cam_push_focus(tgt.global_position, CINE_ZOOM)

	# — подход / позиционирование —
	var mover: Node2D = user.get_node_or_null("MotionRoot") as Node2D
	if mover == null:
		mover = user
	var start_pos := mover.global_position
	var move_mode := "none"
	if typ == "physical":
		if is_aoe:
			move_mode = "aoe"
		elif targets.size() == 1:
			move_mode = "single"

	if move_mode == "single":
		var hit_pos := _approach_point_for(user, targets[0])
		_play_if_has(user.anim, "run")
		var tw1 := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw1.tween_property(mover, "global_position", hit_pos, 0.18)
		await tw1.finished
	elif move_mode == "aoe":
		var aoe_focus := _aoe_focus_point()
		_play_if_has(user.anim, "run")
		var tw2 := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw2.tween_property(mover, "global_position", aoe_focus, 0.22)
		await tw2.finished

	# — QTE —
	var qte = ability.get("qte", {})
	var steps: Array = qte.get("steps", [])
	if steps.is_empty():
		# без QTE — однократный хит по целям
		if is_aoe:
			for t in targets:
				if is_instance_valid(t) and t.health > 0:
					var dmgi := dmg_base
					var is_crit := false
					if dmgi > 0 and crit_ch > 0.0 and randf() < crit_ch:
						is_crit = true
						dmgi = int(round(dmgi * 1.5))
					if dmgi <= 0:
						print("[REFLECT][AoE/noQTE] skip: dmgi<=0 tgt=", t.name)
						continue
					if _has_reflect_equal_damage(t):
						print("[REFLECT][AoE/noQTE] tgt=", t.name, " has reflect. Reflect ", dmgi, " to attacker=", user.name)
						_apply_melee_hit(user, dmgi, {"done": false}, [], user, is_crit)
					else:
						print("[REFLECT][AoE/noQTE] tgt=", t.name, " no reflect. Hit ", dmgi)
						if _turret_absorb_if_any(t, user, dmgi):
							print("[TURRET][AoE/noQTE] absorbed -> skip hit for tgt=%s" % String(t.name))
							continue
						_apply_melee_hit(t, dmgi, {"done": false}, effs, user, is_crit)
		else:
			var tgt2: Node2D = targets[0]
			if is_instance_valid(tgt2) and tgt2.health > 0:
				var dmgi2 := dmg_base
				# >>> БЛОКИРОВКА QTE-УКЛОНА ДЛЯ ОДИНОЧНОЙ ЦЕЛИ <<<
				var qte_allowed_single := not _is_qte_dodge_blocked(tgt2)
				if qte_allowed_single:
					var defres2 := await _defense_single(0.6, [[0.45,0.55]], tgt2)
					await _play_defense_reaction(tgt2, defres2)
					dmgi2 = _apply_damage_with_defense(dmgi2, defres2)
				# иначе QTE не даём и урон идёт напрямую
				if dmgi2 > 0:
					var is_crit2 := crit_ch > 0.0 and randf() < crit_ch
					if is_crit2: dmgi2 = int(round(dmgi2 * 1.5))
					if _has_reflect_equal_damage(tgt2):
						print("[REFLECT][Single/noQTE] tgt=", tgt2.name, " has reflect. Reflect ", dmgi2, " to attacker=", user.name)
						_apply_melee_hit(user, dmgi2, {"done": false}, [], user, is_crit2)
					else:
						print("[REFLECT][Single/noQTE] tgt=", tgt2.name, " no reflect. Hit ", dmgi2)
						if _turret_absorb_if_any(tgt2, user, dmgi2):
							print("[TURRET][Single/noQTE] absorbed -> skip hit for tgt=%s" % String(tgt2.name))
						else:
							_apply_melee_hit(tgt2, dmgi2, {"done": false}, effs, user, is_crit2)
				else:
					print("[REFLECT][Single/noQTE] dmg blocked to 0 for tgt=", tgt2.name)
	else:
		# пошаговый QTE
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

			var dur := float(step.get("duration", 1.0))
			var segs := _segments_to_pairs(step.get("segments", []))
			if segs.is_empty(): segs = [[0.45,0.55]]

			if is_aoe:
				# >>> QTE ДОЛЖЕН ПОКАЗЫВАТЬСЯ ТОЛЬКО ТЕМ, У КОГО НЕТ ЗАПРЕТА <<<
				var qte_targets: Array[Node2D] = []
				for u in targets:
					if is_instance_valid(u) and u.health > 0 and not _is_qte_dodge_blocked(u):
						qte_targets.append(u)

				var mult := 1.0
				var defres := {}    # общий результат защиты группы (для разрешённых)
				if qte_targets.size() > 0:
					defres = await _defense_aoe(dur, segs)
					await _play_defense_reaction_parallel(qte_targets, defres)
					mult = 1.0
					if String(defres.get("type","none")) == "dodge":
						var grade := String(defres.get("grade","fail"))
						if grade == "good" or grade == "perfect":
							mult = 0.0
							# ЕСЛИ В ПАРТИИ ЕСТЬ ДАНТЕ — бонус за удачный уклон
							_dante_add_charge(5, "dodge")

				# Накладываем урон: заблокированным QTE — всегда без уклонения (mult=1.0),
				# разрешённым — по результату группового QTE.
				for t in targets:
					if is_instance_valid(t) and t.health > 0:
						var t_mult := mult
						if _is_qte_dodge_blocked(t):
							t_mult = 1.0
						var dmgi := int(round(dmg_base * t_mult))
						if dmgi > 0:
							var is_crit := crit_ch > 0.0 and randf() < crit_ch
							if is_crit: dmgi = int(round(dmgi * 1.5))
							if _has_reflect_equal_damage(t):
								print("[REFLECT][AoE/QTE] tgt=", t.name, " mult=", t_mult, " has reflect. Reflect ", dmgi, " to attacker=", user.name)
								_apply_melee_hit(user, dmgi, {"done": false}, [], user, is_crit)
							else:
								print("[REFLECT][AoE/QTE] tgt=", t.name, " mult=", t_mult, " no reflect. Hit ", dmgi)
								if _turret_absorb_if_any(t, user, dmgi):
									print("[TURRET][AoE/QTE] absorbed -> skip hit for tgt=%s" % String(t.name))
								else:
									_apply_melee_hit(t, dmgi, {"done": false}, effs, user, is_crit)
						else:
							print("[REFLECT][AoE/QTE] tgt=", t.name, " mult=", t_mult, " -> dmgi=0")
			else:
				var tgt3: Node2D = targets[0]
				if is_instance_valid(tgt3) and tgt3.health > 0:
					# >>> ДЛЯ ОДИНОЧНОЙ ЦЕЛИ QTE ТОЛЬКО ЕСЛИ НЕ ЗАПРЕЩЁН <<<
					var qte_allowed_single2 := not _is_qte_dodge_blocked(tgt3)
					var dmgi3 := dmg_base
					if qte_allowed_single2:
						var defres3 := await _defense_single(dur, segs, tgt3)
						await _play_defense_reaction(tgt3, defres3)
						dmgi3 = _apply_damage_with_defense(dmgi3, defres3)
					# иначе QTE не даём — урон напрямую
					if dmgi3 > 0:
						var is_crit3 := crit_ch > 0.0 and randf() < crit_ch
						if is_crit3: dmgi3 = int(round(dmgi3 * 1.5))
						if _has_reflect_equal_damage(tgt3):
							print("[REFLECT][Single/QTE] tgt=", tgt3.name, " has reflect. Reflect ", dmgi3, " to attacker=", user.name)
							_apply_melee_hit(user, dmgi3, {"done": false}, [], user, is_crit3)
						else:
							print("[REFLECT][Single/QTE] tgt=", tgt3.name, " no reflect. Hit ", dmgi3)
							if _turret_absorb_if_any(tgt3, user, dmgi3):
								print("[TURRET][Single/QTE] absorbed -> skip hit for tgt=%s" % String(tgt3.name))
							else:
								_apply_melee_hit(tgt3, dmgi3, {"done": false}, effs, user, is_crit3)
					else:
						print("[REFLECT][Single/QTE] tgt=", tgt3.name, " -> dmgi=0")

			await _wait_anim_end(user.anim, clip, 0.8)

	# — откат/выход из «кино» —
	if move_mode != "none":
		await create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT).tween_property(mover, "global_position", start_pos, 0.22).finished
	_play_if_has(user.anim, "idle")
	_update_enemy_bars_positions()
	await _cam_pop()
	_exit_cinematic()


func _devour_take(eater: Node2D, victim: Node2D, skill: Dictionary) -> void:
	if eater == null or victim == null: return
	if _devour_map.has(eater): return
	if _is_devoured(victim): return

	victim.set_meta("devoured", true)
	_devour_map[eater] = victim

	# спрячем и «заморозим»
	victim.visible = false
	victim.process_mode = Node.PROCESS_MODE_DISABLED

	# бафф сытости (если задан)
	var self_effs: Array = skill.get("effects_to_self", [])
	if self_effs.size() > 0:
		_apply_effects(self_effs, eater)

	print("[DEVOUR] ", eater.nick, " проглотил ", victim.nick)

func _devour_release_by(eater: Node2D) -> void:
	if not _devour_map.has(eater): return
	var v: Node2D = _devour_map[eater]
	_devour_map.erase(eater)
	if v != null and is_instance_valid(v):
		v.set_meta("devoured", false)
		v.visible = true
		v.process_mode = Node.PROCESS_MODE_INHERIT
		print("[DEVOUR] ", v.nick, " освобождён (пожиратель пал)")

func perform_action(user: Node2D, action: Dictionary) -> void:
	if action == null or action.size() == 0:
		print("[ACT] пустое действие от ", user.nick)
		return

	var name_dbg := String(action.get("name","<безымянное>"))
	var target_mode := String(action.get("target",""))
	var special := String(action.get("special",""))
	if special == "devour":
		var victim: Node2D = action.get("target_instance", null)
		if victim == null or not is_instance_valid(victim) or _is_devoured(victim):
			victim = _ally_lowest_hp(heroes)
		if victim == null:
			return

		# Условия (старый + новый формат)
		var cond: Dictionary = action.get("conditions", {})
		var thr := float(cond.get("target_hp_ratio_max", action.get("hp_threshold", 0.5)))
		if bool(cond.get("self_not_devouring", true)) and _devour_map.has(user):
			print("[DEVOUR] уже держу жертву — нельзя."); return
		var absent = cond.get("self_effect_absent", null)
		if typeof(absent) == TYPE_STRING and _has_effect(user, String(absent)):
			print("[DEVOUR] на себе запрещающий бафф: ", String(absent)); return
		elif typeof(absent) == TYPE_ARRAY:
			for eid in absent:
				if _has_effect(user, String(eid)): print("[DEVOUR] запрещающий бафф: ", String(eid)); return

		var ratio = float(victim.health)/max(1.0, float(victim.max_health))
		if ratio > thr:
			print("[DEVOUR] цель слишком здорова: ratio=", ratio, " thr=", thr); return

		# Подбег — как в _do_melee_single (без урона)
		var mover: Node2D = user.get_node_or_null("MotionRoot") as Node2D
		if mover == null:
			mover = user
		var start_pos := mover.global_position
		var hit_pos := _approach_point_for(user, victim)
		_play_if_has(user.anim, "run")
		var tw_in := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw_in.tween_property(mover, "global_position", hit_pos, 0.18)
		await tw_in.finished

		# Клип «захвата»
		var clip := "attack"
		if user.anim != null:
			if action.has("qte"):
				var steps = action["qte"].get("steps", [])
				if steps is Array and steps.size() > 0:
					var st0 = steps[0]
					if typeof(st0) == TYPE_DICTIONARY and user.anim.has_animation(String(st0.get("anim","attack"))):
						clip = String(st0.get("anim","attack"))
			elif user.anim.has_animation("skill"):
				clip = "skill"
		_play_if_has(user.anim, clip)

		# Тайминг и защита цели (берём из qte.steps[0], если есть)
		var dur := 0.6
		var segs := [[0.45,0.55]]
		if action.has("qte"):
			var steps = action["qte"].get("steps", [])
			if steps is Array and steps.size() > 0 and typeof(steps[0]) == TYPE_DICTIONARY:
				dur = float(steps[0].get("duration", dur))
				var sraw = steps[0].get("segments", segs)
				segs = _segments_to_pairs(sraw)

		var defres := await _defense_single(dur, segs, victim)
		await _play_defense_reaction(victim, defres)

		# Если защита «сбила» special — откат и конец
		if _defense_cancels_special(defres):
			await _wait_anim_end(user.anim, clip, 0.8)
			var twb := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			twb.tween_property(mover, "global_position", start_pos, 0.18)
			await twb.finished
			_play_if_has(user.anim, "idle")
			return

		# Иначе — пожираем
		await _wait_anim_end(user.anim, clip, 0.8)
		_devour_take(user, victim, action)

		# Возврат на позицию
		var two := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		two.tween_property(mover, "global_position", start_pos, 0.18)
		await two.finished
		_play_if_has(user.anim, "idle")
		return
	# ───────── цели ─────────
	var targets: Array[Node2D] = []

	if target_mode == "all_enemies":
		var pool_all: Array[Node2D] = (heroes if String(user.team) == "enemy" else enemies)
		for n in pool_all:
			if is_instance_valid(n) and n.health > 0:
				targets.append(n)

	elif target_mode == "single_enemy":
		var tgt_inst: Node2D = action.get("target_instance", null)
		if tgt_inst == null or not is_instance_valid(tgt_inst) or tgt_inst.health <= 0:
			tgt_inst = _first_alive(heroes if String(user.team) == "enemy" else enemies)
		if tgt_inst != null and is_instance_valid(tgt_inst):
			targets.append(tgt_inst)

	elif target_mode == "single_ally":
		var ally: Node2D = action.get("target_instance", user)
		if ally != null and is_instance_valid(ally):
			targets.append(ally)

	elif target_mode == "self":
		targets.append(user)

	elif target_mode == "all_allies":
		var pool_ally: Array[Node2D] = (enemies if String(user.team) == "enemy" else heroes)
		for a in pool_ally:
			if is_instance_valid(a) and a.health > 0:
				targets.append(a)

	# лог
	var tnames := []
	for tinst in targets:
		if tinst != null and is_instance_valid(tinst):
			tnames.append(tinst.nick)
	print("[ACT] ", user.nick, " → ", name_dbg, " (", target_mode, "), цели: ", tnames)

	# ───────── ресурс ─────────
	if not _can_pay_cost(user, action):
		print("[ACT] ", user.nick, " не может оплатить действие ", name_dbg)
		return

	var __mana_before_pay = user.mana
	if DEBUG_SALLY and String(user.nick) == "Sally":
		_sally_dbg("before_pay", user, action, {"mana_before": __mana_before_pay})

	_pay_cost(user, action)

	if DEBUG_SALLY and String(user.nick) == "Sally":
		_sally_dbg("after_pay", user, action, {"mana_before": __mana_before_pay, "delta": user.mana - __mana_before_pay})

	# ───────── QTE/тип действия ─────────
	var has_qte := false
	if action.has("qte"):
		var q = action.get("qte", {})
		if typeof(q) == TYPE_DICTIONARY:
			var st = q.get("steps", [])
			if st is Array and st.size() > 0:
				has_qte = true

	var is_damage := action.get("damage") != null
	var is_magic := String(action.get("type","")) == "magic"

	# QTE: урон → с защитным QTE игрока; поддержка → общий QTE-проигрыватель
	if has_qte:
		if is_damage:
			await _enemy_perform_with_qte(user, targets, action)
		else:
			var tlist: Array[Node2D] = (targets if targets.size() > 0 else [user])
			await _perform_with_qte(user, tlist, action)
		return

	# ───────── без QTE ─────────
	if is_damage:
		if targets.size() == 0:
			print("[ACT] Нет валидных целей для урона, конец действия.")
			return

		var dmg = max(1, int(action.get("damage", user.attack)))
		var effs: Array = action.get("effects_to_targets", [])

		_is_acting = true
		match target_mode:
			"single_enemy":
				if is_magic:
					await _do_magic_single(user, targets[0], dmg, effs)
				else:
					await _do_melee_single(user, targets[0], dmg, effs)
			"all_enemies":
				if is_magic:
					await _do_magic_aoe(user, dmg, effs)
				else:
					await _do_melee_aoe(user, dmg, effs)
			_:
				# на всякий фолбэк — просто применим по всем собранным "targets"
				for t in targets:
					if is_instance_valid(t):
						t.health = max(0, t.health - dmg)
						if t.health <= 0:
							_on_enemy_died(t)
		_is_acting = false
		return

	# поддержка/баффы/хил без урона
	_is_acting = true
	if target_mode == "all_allies":
		# одна анимация — применяем и heal, и эффекты на всех союзников
		var ap = user.anim
		var clip := "cast"
		if ap != null:
			if ap.has_animation("cast"):
				clip = "cast"
			elif ap.has_animation("skill"):
				clip = "skill"
		_play_if_has(ap, clip)

		var clip_len := 0.5
		if ap != null and ap.has_animation(clip):
			clip_len = ap.get_animation(clip).length
		var apply_delay = clamp(0.30 * clip_len, 0.06, 0.60)
		await get_tree().create_timer(apply_delay).timeout

		var heal_amt := int(action.get("heal", 0))
		if heal_amt > 0:
			for ally in targets:
				if is_instance_valid(ally):
					ally.health = min(ally.max_health, max(0, ally.health + heal_amt))

		var effs_targets: Array = action.get("effects_to_targets", [])
		if effs_targets.size() > 0:
			for ally in targets:
				if is_instance_valid(ally) and ally.health > 0:
					_apply_effects(effs_targets, ally)
					_dante_add_charge(2, "buff")

		var effs_self: Array = action.get("effects_to_self", [])
		if effs_self.size() > 0:
			_apply_effects(effs_self, user)
			_dante_add_charge(2, "self_buff")

		await _wait_anim_end(ap, clip, 1.2)
		_play_if_has(ap, "idle")
	else:
		var tgt_for_support: Node2D = (targets[0] if not targets.is_empty() and is_instance_valid(targets[0]) else user)
		await _do_support(user, tgt_for_support, action)
	_is_acting = false
		
func _query_incoming_mods(target: Node2D) -> Dictionary:
	# стягиваем из системы эффектов персонажа, если она умеет вернуть
	var evade := 0.0
	var crit_mult := 1.0
	if target != null and is_instance_valid(target):
		if target.has_method("list_effects"):
			for ex in target.call("list_effects"):
				if typeof(ex) == TYPE_DICTIONARY:
					evade     += float(ex.get("evade_chance", 0.0))
					crit_mult *= float(ex.get("crit_taken_mult", 1.0))
		elif target.has_method("get_effect"):
			# минимальная совместимость по id
			var ex = target.call("get_effect", "squirrel_dodge")
			if typeof(ex) == TYPE_DICTIONARY:
				evade     += float(ex.get("evade_chance", 0.0))
				crit_mult *= float(ex.get("crit_taken_mult", 1.0))
	return {"evade": clamp(evade, 0.0, 0.9), "crit_mult": max(1.0, crit_mult)}

func _show_popup_number(target: Node2D, amount: int, kind: String = "dmg", is_crit := false) -> void:
	if world_ui == null or not is_instance_valid(target): return
	var lab := Label.new()
	lab.z_as_relative = false
	lab.z_index = 999
	var txt := str(amount)
	if kind == "miss": txt = "MISS"
	lab.text = txt
	var fs := 24
	if is_crit: fs = 34
	lab.add_theme_font_size_override("font_size", fs)

	match kind:
		"dmg":
			lab.modulate = Color(1, 0.2, 0.2, 1)
		"heal":
			lab.modulate = Color(0.2, 1, 0.2, 1)
		"crit":
			lab.modulate = Color(1, 0.9, 0.2, 1)
		"miss":
			lab.modulate = Color(0.8, 0.8, 0.8, 1)

	world_ui.add_child(lab)
	var sp := _world_to_screen(target.global_position) + Vector2(0, -HB_OFFSET_Y - 12)
	lab.global_position = sp

	var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(lab, "global_position", sp + Vector2(0, -36), 0.45)
	tw.parallel().tween_property(lab, "modulate:a", 0.0, 0.45)
	await tw.finished
	if is_instance_valid(lab): lab.queue_free()

func _ai_conditions_met(user: Node2D, target: Node2D, cond: Dictionary) -> bool:
	if cond.is_empty():
		return true

	# 1) таргет под порогом HP
	if cond.has("target_hp_ratio_max") and target != null and is_instance_valid(target):
		var thr := float(cond.get("target_hp_ratio_max", 1.0))
		var ratio = float(target.health) / max(1.0, float(target.max_health))
		if ratio > thr:
			return false

	# 2) у «самого» нет конкретного баффа (id) — можно строку или массив строк
	if cond.has("self_effect_absent") and user != null and is_instance_valid(user):
		var need_absent = cond["self_effect_absent"]
		if typeof(need_absent) == TYPE_STRING:
			if _has_effect(user, String(need_absent)):
				return false
		elif typeof(need_absent) == TYPE_ARRAY:
			for eid in need_absent:
				if _has_effect(user, String(eid)):
					return false

	# 3) запрет, если уже держим «жертву» (универсально для пожирания)
	if bool(cond.get("self_not_devouring", false)) and _devour_map.has(user):
		return false

	# 4) цель не «съедена»
	if bool(cond.get("target_not_devoured", false)) and _is_devoured(target):
		return false

	return true


func _ai_pick_target_for_special(user: Node2D, ability: Dictionary) -> Node2D:
	var tmode := String(ability.get("target", ""))
	var cond: Dictionary = ability.get("conditions", {})
	if tmode == "self":
		return user

	if tmode == "single_ally":
		var pool: Array = (enemies if String(user.team) == "enemy" else heroes)
		return _ally_lowest_hp(pool)

	if tmode == "single_enemy":
		var pool: Array = (heroes if String(user.team) == "enemy" else enemies)
		# если задан порог HP — выберем самого «битого» под порогом
		if cond.has("target_hp_ratio_max"):
			var thr := float(cond.get("target_hp_ratio_max", 1.0))
			var best: Node2D = null
			var best_ratio := 999.0
			for h in pool:
				if not is_instance_valid(h) or h.health <= 0 or _is_devoured(h): continue
				var r = float(h.health) / max(1.0, float(h.max_health))
				if r <= thr and r < best_ratio:
					best_ratio = r; best = h
			if best != null:
				return best
		# иначе — эвристика стиля: коварный держит фокус
		var style := _ai_style_of(user)
		if style == "cunning":
			var f := _ai_get_focus(user)
			if f != null and is_instance_valid(f) and f.health > 0 and not _is_devoured(f):
				return f
		# фолбэк — любой живой
		return _random_alive(pool)


	# групповые special обычно не нужны, но поддержим
	if tmode == "all_enemies" or tmode == "all_allies":
		return null  # целеуказание не требуется

	return null

func _defense_cancels_special(defres: Dictionary) -> bool:
	var t := String(defres.get("type","none"))
	var g := String(defres.get("grade","fail"))
	if t == "dodge":
		return g == "good" or g == "perfect"   # уклон отменяет
	if t == "block":
		return g == "perfect"                  # perfect-block отменяет
	return false

func _ai_try_special(enemy: Node2D) -> Variant:
	if enemy == null or not is_instance_valid(enemy):
		return null

	var picked: Dictionary = {}
	var best_priority := -9999

	for a in enemy.abilities:
		if typeof(a) != TYPE_DICTIONARY: continue
		if not a.has("special"): continue

		var special := String(a.get("special", ""))
		var cond: Dictionary = a.get("conditions", {})

		# devour: базовое правило — нельзя, если уже «держим»; цель под порогом
		if special == "devour":
			# совместимость со старым полем hp_threshold
			if not cond.has("target_hp_ratio_max") and a.has("hp_threshold"):
				cond["target_hp_ratio_max"] = float(a.get("hp_threshold", 0.5))
			# если в JSON не указали явно — запретим пожирать, когда уже «живёт» жертва
			if not cond.has("self_not_devouring"):
				cond["self_not_devouring"] = true

		var tgt := _ai_pick_target_for_special(enemy, a)
		# если таргет не нужен (all_*), считаем, что проверка идёт по self
		var ok := _ai_conditions_met(enemy, (tgt if tgt != null else enemy), cond)
		if not ok:
			continue

		# можно ввести «priority» в JSON, чтобы управлять очередностью special
		var prio := int(a.get("priority", 100))
		if prio > best_priority:
			best_priority = prio
			picked = a.duplicate(true)
			if tgt != null: picked["target_instance"] = tgt

	return picked if picked.size() > 0 else null

func _aoe_focus_point() -> Vector2:
	var focus := _screen_center_world() + Vector2(AOE_CENTER_X_OFFSET, AOE_CENTER_Y_OFFSET)
	var sumy := 0.0
	var cnt := 0
	for e in enemies:
		if is_instance_valid(e) and e.health > 0:
			sumy += e.global_position.y
			cnt += 1
	if cnt > 0:
		focus.y = sumy / cnt + APPROACH_Y
	return focus

func _aoe_cam_shift_world(attacker: Node2D) -> float:
	var zoom := _get_view_zoom()
	if zoom <= 0.001:
		zoom = 1.0
	var sx := AOE_CAM_SHIFT_PX / zoom
	# враги — влево, герои — вправо
	if attacker != null and attacker.team == "enemy":
		sx = -sx
	return sx

func _on_enemy_died(enemy: Node2D):
	if not is_instance_valid(enemy):
		return
	_devour_release_by(enemy)
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
		check_battle_end()
				
			
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
	if _battle_over:
		return

	var heroes_alive := 0
	for h in heroes:
		if is_instance_valid(h) and h.health > 0:
			heroes_alive += 1

	var enemies_alive := 0
	for e in enemies:
		if is_instance_valid(e) and e.health > 0:
			enemies_alive += 1

	if enemies_alive == 0:
		battle_victory()
	elif heroes_alive == 0:
		battle_defeat()

func battle_victory() -> void:
	_finish_battle("victory")

func battle_defeat() -> void:
	_finish_battle("defeat")

func _finish_battle(result: String) -> void:
	_battle_over = true
	if action_panel:
		action_panel.hide()
	if top_ui:
		top_ui.visible = false
	if party_hud:
		party_hud.visible = false
	_show_battle_result(result)

func _show_battle_result(result: String) -> void:
	var root_ui := $UI
	if root_ui == null:
		# запасной путь — создадим локальный UI, но правильной полноэкранной раскладки не будет
		root_ui = Control.new()
		add_child(root_ui)
		root_ui.anchor_left = 0; root_ui.anchor_top = 0; root_ui.anchor_right = 1; root_ui.anchor_bottom = 1
		root_ui.offset_left = 0; root_ui.offset_top = 0; root_ui.offset_right = 0; root_ui.offset_bottom = 0

	var ov := Control.new()
	ov.name = "BattleResult"
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	ov.z_as_relative = false
	ov.z_index = 1000
	ov.anchor_left = 0; ov.anchor_top = 0; ov.anchor_right = 1; ov.anchor_bottom = 1
	ov.offset_left = 0; ov.offset_top = 0; ov.offset_right = 0; ov.offset_bottom = 0
	root_ui.add_child(ov)

	var bg := ColorRect.new()
	bg.color = Color(0,0,0,0.75)
	bg.anchor_left = 0; bg.anchor_top = 0; bg.anchor_right = 1; bg.anchor_bottom = 1
	ov.add_child(bg)

	var center := CenterContainer.new()
	center.anchor_left = 0; center.anchor_top = 0; center.anchor_right = 1; center.anchor_bottom = 1
	center.offset_left = 0; center.offset_top = 0; center.offset_right = 0; center.offset_bottom = 0
	ov.add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(460, 240)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 16)
	center.add_child(box)

	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 48)
	lbl.text = "ПОБЕДА!" if result == "victory" else "ПОРАЖЕНИЕ"
	box.add_child(lbl)

	var btn := Button.new()
	btn.text = "Выход"
	btn.custom_minimum_size = Vector2(200, 48)
	box.add_child(btn)

	btn.pressed.connect(func():
		# уведомим (если где-то подписывались)
		emit_signal("battle_finished", result)

		# возврат в таймлайн через GM, без прямого change_scene_to_file
		var victory := (result == "victory")
		var participants := _collect_participants()
		GameManager.end_battle(victory, participants)
	)
	
