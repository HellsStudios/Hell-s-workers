extends Node

var all_heroes: Dictionary = {}          # name -> dict статов
var party_names: Array = ["Berit","Sally","Dante"]      # ["Berit","Sally","Dante"]
var inventory: Dictionary = {}           # можно позже заполнить
# Глобальные игровые данные
var day: int = 1
var resources: int = 0
var current_phase: int = 0
var phase_names = ["Утро", "День", "Вечер", "Ночь"]
var items_db: Dictionary = {}        # id -> def (из items.json)
var base_inventory: Dictionary = {}  # id -> количество (на базе)

var supplies_db: Dictionary = {}        # id -> def (из supplies.json)
var supplies_inventory: Dictionary = {} # id -> count (на базе)
const SUPPLIES_JSON := "res://Data/supplies.json"
const SUPPLIES_ICON_DIR := "res://Assets/supplies/"  # необязательно

signal supplies_changed

var enemies_db: Dictionary = {}  # id -> деф

var _berit_mech_loaded := false
var _berit_recipes := {}

# ─── ДОБАВИТЬ В ВЕРХУШКУ GM ───
# ── ДОБАВИТЬ: путь и кэш ─────────────────────────────────────────────
const SALLY_ENH_JSON := "res://Data/sally_enhance.json"
var _sally_enh_cache: Dictionary = {}

const EFFECTS_FILE := "res://data/effects.json"

var EFFECTS_DB: Dictionary = {}   # id -> прототип эффекта

static var _sally_words_pool: Array = []

const DANTE_ENHANCE_PATH := "res://data/dante_enhance.json"

# GameManager.gd (добавь к полям одно из верхних мест)
var dante_enhance: Dictionary = {}
var _dante_loaded := false

# ─── СУМКИ ГЕРОЕВ ДЛЯ БОЁВ ──────────────────────────────────────────────
var hero_bags: Dictionary = {}   # имя -> { item_id: count }

# --- Журнал/квесты ---
var codex: Dictionary = {}           # "ключ" -> текст записи
var active_quests: Array = []        # массив словарей: {id,name,desc,completed:bool}

# ===== Quests/Archive JSON =====
const QUESTS_FILE  := "res://Data/quests.json"
const ARCHIVE_FILE := "res://Data/archive.json"
const ARCHIVE_IMG_DIR := "res://Assets/ArchiveImages/"

# ===== AUGMENTS (пиктосы) =====
const AUGMENTS_JSON := "res://Data/augments.json"

var augments_db: Dictionary = {}          # id -> def
var unlocked_augments: Array = []         # глобально открытые id
var hero_augs: Dictionary = {}            # имя героя -> Array[id] (активные)
var hero_ether_cap: Dictionary = {}       # имя героя -> лимит очков (по умолчанию 10)
var etheria: int = 0                      # общий ресурс «Эфирия»

signal augments_changed


# Валюта
var krestli: int = 0

# Квесты: id -> dict
var quests_all: Dictionary = {}   # {"q_id": {id,name,desc,available,completed,rewards{...}}}

# Архив: category -> Array[entry]
# entry: {id,title,text,image?,available?}
var archive_db: Dictionary = {}
signal archive_changed

# --- Ограничение по навыкам, взятым с собой ---
const EQUIP_SKILL_LIMIT := 6

# ============ CODEx / ARCHIVE ============
signal codex_changed

# --- Контейнер/холодильник (обёртки под старые имена) ---
signal container_changed
const CONTAINER_TTL_PHASES := 2

# --- TASK SYSTEM ---
var task_defs: Dictionary = {}        # id -> деф задачи (из quests.json)
var daily_pools: Dictionary = {}      # name -> Array[{id,chance,min,max}]
var active_task_pool: Array = []      # [{inst_id, def_id, source:"quest"/"daily"/..., quest_id?}]
var scheduled: Dictionary = {}        # hero -> Array[{inst_id, def_id, start:int, duration:int, progress:int}]
var _task_inst_seq: int = 1
var timeline_clock := { "slot": 0, "running": false, "slot_sec": 0.7 }

signal task_pool_changed
signal schedule_changed
signal task_event(hero: String, inst_id: int, event_def: Dictionary)
signal task_started(hero: String, inst_id: int)
signal task_completed(hero: String, inst_id: int, outcome: Dictionary)

func spawn_quest_tasks(quest_id: String) -> void:
	var q: Dictionary = quests_all.get(quest_id, {})
	var arr: Array = q.get("tasks", [])
	for t in arr:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var def_id := String(t.get("def",""))
		var count := int(t.get("count", 1))
		if def_id == "" or count <= 0:
			continue
		for _i in count:
			_add_task_instance(def_id, "quest", quest_id)
	emit_signal("task_pool_changed")


func spawn_daily_tasks(pool_name: String = "default") -> void:
	var spawned := 0
	var arr: Array = daily_pools.get(pool_name, [])
	for e in arr:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var def_id := String(e.get("id",""))
		if def_id == "":
			continue
		var chance := float(e.get("chance", 1.0))
		var mn := int(e.get("min", 0))
		var mx := int(e.get("max", 0))

		var n := mn
		while n < mx and randf() < chance:
			n += 1
		for _i in n:
			_add_task_instance(def_id, "daily", "")
			spawned += 1
	if spawned > 0:
		emit_signal("task_pool_changed")

func has_condition(hero: String, id: String) -> bool:
	var arr: Array = hero_conditions.get(hero, [])
	for e in arr:
		if String(e.get("id","")) == id:
			return true
	return false

func get_qual_level(hero: String, q: String) -> int:
	var store: Dictionary = hero_quals.get(hero, {})
	var entry: Dictionary = store.get(q, {})
	if entry.has("lvl"):
		return int(entry["lvl"])
	return 0


func _add_task_instance(def_id: String, source: String, quest_id: String) -> void:
	if not task_defs.has(def_id): return
	var inst_id := _task_inst_seq; _task_inst_seq += 1
	active_task_pool.append({
		"inst_id": inst_id,
		"def_id": def_id,
		"source": source,
		"quest_id": quest_id
	})

func can_schedule(hero: String, inst_id: int, start_slot: int) -> bool:
	var def_id := _inst_def(inst_id)
	if def_id == "": return false
	var dur := int(task_defs[def_id].get("duration_slots", 4))
	# проверка занятости героя
	for s in scheduled.get(hero, []):
		var a := int(s["start"])
		var b := a + int(s["duration"])
		var c := start_slot
		var d := c + dur
		if c < b and d > a:
			return false
	return true

func schedule_task(hero: String, inst_id: int, start_slot: int) -> bool:
	if not can_schedule(hero, inst_id, start_slot): return false
	var def_id := _inst_def(inst_id)
	if def_id == "": return false
	var dur := int(task_defs[def_id].get("duration_slots", 4))

	# убрать из пула
	for i in range(active_task_pool.size()):
		if int(active_task_pool[i]["inst_id"]) == inst_id:
			active_task_pool.remove_at(i)
			break
	var arr = scheduled.get(hero, [])
	arr.append({ "inst_id":inst_id, "def_id":def_id, "start":start_slot, "duration":dur, "progress":0 })
	scheduled[hero] = arr
	emit_signal("task_pool_changed")
	emit_signal("schedule_changed")
	return true

func unschedule_task(hero: String, inst_id: int) -> void:
	var arr = scheduled.get(hero, [])
	for i in range(arr.size()):
		if int(arr[i]["inst_id"]) == inst_id:
			# вернуть в пул
			active_task_pool.append({ "inst_id":inst_id, "def_id":arr[i]["def_id"], "source":"unscheduled", "quest_id":"" })
			arr.remove_at(i)
			break
	scheduled[hero] = arr
	emit_signal("task_pool_changed")
	emit_signal("schedule_changed")

func _inst_def(inst_id: int) -> String:
	for it in active_task_pool:
		if int(it["inst_id"]) == inst_id: return String(it["def_id"])
	for hero in scheduled.keys():
		for s in scheduled[hero]:
			if int(s["inst_id"]) == inst_id: return String(s["def_id"])
	return ""

func tick_timeline(slot: int) -> void:
	timeline_clock["slot"] = slot
	# старт / прогресс / завершение
	for hero in party_names:
		var arr = scheduled.get(hero, [])
		for s in arr:
			var st := int(s["start"])
			var en := st + int(s["duration"])
			if slot == st:
				emit_signal("task_started", hero, int(s["inst_id"]))
			# события по таймлайну
			var def: Dictionary = task_defs.get(String(s["def_id"]), {})
			for ev in Array(def.get("events", [])):
				var at := st + int(ev.get("at_rel_slot", -999))
				if slot == at:
					emit_signal("task_event", hero, int(s["inst_id"]), ev)
			# завершение
			if slot == en:
				_complete_task(hero, s)   # награды/штрафы
				# снимаем расписание
	# очистка завершённых
	for hero in party_names:
		var keep := []
		for s in scheduled.get(hero, []):
			if int(s["start"]) + int(s["duration"]) > slot:
				keep.append(s)
		scheduled[hero] = keep

func _complete_task(hero: String, s: Dictionary) -> void:
	var def: Dictionary = task_defs.get(String(s["def_id"]), {})
	var outcome := _evaluate_outcome(hero, def) # успех/провал, модификаторы
	_apply_costs_and_rewards(hero, def, outcome)
	emit_signal("task_completed", hero, int(s["inst_id"]), outcome)

func _apply_costs_and_rewards(hero: String, def: Dictionary, outcome: Dictionary) -> void:
	# 1) Базовые расходы (сытость / стамина / мана / хп)
	var bc: Dictionary = def.get("base_cost", {})

	# сытость (лейер уже есть)
	var take_sat := int(bc.get("satiety", 0))
	if take_sat > 0:
		var cur_sat := int(hero_satiety.get(hero, 50))
		cur_sat -= take_sat
		if cur_sat < 0:
			cur_sat = 0
		if cur_sat > 100:
			cur_sat = 100
		hero_satiety[hero] = cur_sat

	# стамина
	var take_sta := int(bc.get("stamina", 0))
	if take_sta > 0:
		var cur_sta := res_cur(hero, "stamina")
		cur_sta -= take_sta
		if cur_sta < 0:
			cur_sta = 0
		set_res_cur(hero, "stamina", cur_sta)

	# мана
	var take_mana := int(bc.get("mana", 0))
	if take_mana > 0:
		var cur_mana := res_cur(hero, "mana")
		cur_mana -= take_mana
		if cur_mana < 0:
			cur_mana = 0
		set_res_cur(hero, "mana", cur_mana)

	# здоровье
	var take_hp := int(bc.get("hp", 0))
	if take_hp > 0:
		var cur_hp := res_cur(hero, "hp")
		cur_hp -= take_hp
		if cur_hp < 0:
			cur_hp = 0
		set_res_cur(hero, "hp", cur_hp)

	# 2) Награды (если успех — можно оставить как есть; если хочешь,
	#    можешь смотреть на outcome["success"] и уменьшать выхлоп)
	var rw: Dictionary = def.get("rewards", {})

	var k := int(rw.get("krestli", 0))
	if k > 0:
		krestli += k

	var eth := int(rw.get("etheria", 0))
	if eth > 0:
		add_etheria(eth)

	var items: Array = rw.get("items", [])
	for e in items:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var iid := String(e.get("id",""))
		var cnt := int(e.get("count", 0))
		if iid != "" and cnt > 0:
			add_to_base(iid, cnt)

	var sups: Array = rw.get("supplies", [])
	for e in sups:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var sid := String(e.get("id",""))
		var cnt := int(e.get("count", 0))
		if sid != "" and cnt > 0:
			supplies_add(sid, cnt)

	var qxp: Dictionary = rw.get("qual_xp", {})
	for qname in qxp.keys():
		add_qual_xp(hero, String(qname), int(qxp[qname]))

	# при желании: позитивные/негативные кондинции в зависимости от outcome
	# if bool(outcome.get("success", true)) == false:
	#     add_condition(hero, "fatigue", 0, 2)


func _evaluate_outcome(hero: String, def: Dictionary) -> Dictionary:
	var base := 60

	# настроение
	var mv := mood_value(hero)
	var aff_mood: Dictionary = {}
	var aff_root: Dictionary = def.get("affinity", {})
	if aff_root.has("mood"):
		aff_mood = aff_root["mood"]
	var per10 := int(aff_mood.get("per10", 0))
	base += per10 * int(mv / 10)

	# квалификация
	var req: Dictionary = {}
	if def.has("require"):
		var r: Dictionary = def["require"]
		if r.has("qual"):
			req = r["qual"]
	for q in req.keys():
		var need := int(req[q])
		var have := get_qual_level(hero, String(q))
		base += (have - need) * 8

	# кондинции
	var aff_conds: Dictionary = {}
	if aff_root.has("conds"):
		aff_conds = aff_root["conds"]
	for c in aff_conds.keys():
		if has_condition(hero, String(c)):
			base += int(aff_conds[c])

	# рандом и кламп
	var roll := randi_range(-10, 10)
	var chance := base + roll
	if chance < 5:
		chance = 5
	if chance > 95:
		chance = 95

	var ok := chance >= 50
	return {"success": ok, "chance": chance}



func advance_phase_after_meal() -> void:
	current_phase += 1
	if current_phase >= phase_names.size():
		current_phase = 0
		day += 1
	culling_spoiled_food()
	_tick_conditions_and_phase_effects()
	
func apply_battle_start_augments(actor: Node, hero_name: String) -> void:
	for eff_id in get_aug_start_effects(hero_name):
		var proto := get_effect_proto(eff_id)
		if not proto.is_empty():
			if "add_effect" in actor: actor.add_effect(proto)
			elif "apply_effect" in actor: actor.apply_effect(proto)
	for eff_id in get_cond_start_effects(hero_name):
		var proto := get_effect_proto(eff_id)
		if not proto.is_empty():
			if "add_effect" in actor: actor.add_effect(proto)
			elif "apply_effect" in actor: actor.apply_effect(proto)

func _fridge_add(meal_id: String, count: int, ttl_phases: int = CONTAINER_TTL_PHASES) -> int:
	if meal_id == "" or count <= 0:
		return 0
	var exp_day := day
	var exp_phase := current_phase + ttl_phases
	while exp_phase >= phase_names.size():
		exp_phase -= phase_names.size()
		exp_day += 1
	fridge.append({
		"meal": meal_id,
		"portions": count,
		"expires_day": exp_day,
		"expires_phase": exp_phase
	})
	emit_signal("container_changed")
	return count

func _fridge_take(meal_id: String, count: int) -> int:
	if count <= 0:
		return 0
	var need := count
	var taken := 0
	var keep: Array = []
	for e in fridge:
		var mid := str(e.get("meal",""))
		var c := int(e.get("portions",0))
		var d := int(e.get("expires_day",0))
		var p := int(e.get("expires_phase",0))
		if mid == meal_id and need > 0 and c > 0:
			var take = min(c, need)
			c -= take
			need -= take
			taken += take
		if c > 0:
			keep.append({"meal": mid, "portions": c, "expires_day": d, "expires_phase": p})
	fridge = keep
	if taken > 0:
		emit_signal("container_changed")
	return taken

func fridge_count(meal_id: String) -> int:
	var s := 0
	for e in fridge:
		if str(e.get("meal","")) == meal_id:
			s += int(e.get("portions",0))
	return s

func activate_from_fridge(meal_id: String, count: int) -> bool:
	if meal_id == "" or count <= 0:
		return false
	if not pending_meal.is_empty() and int(pending_meal.get("portions",0)) > 0:
		return false
	var took := _fridge_take(meal_id, count)
	if took <= 0:
		return false
	pending_meal = {"meal": meal_id, "portions": took, "total": took, "from_container": true}
	emit_signal("cooking_changed")
	return true

# --- Совместимость со старыми именами:
func container_add(meal_id: String, count: int, _ttl_days: int = 2) -> int:
	return _fridge_add(meal_id, count, CONTAINER_TTL_PHASES)

func container_take(meal_id: String, count: int) -> int:
	return _fridge_take(meal_id, count)

func container_count(meal_id: String) -> int:
	return fridge_count(meal_id)

func container_all() -> Dictionary:
	var m: Dictionary = {}
	for e in fridge:
		var mid := str(e.get("meal",""))
		var c := int(e.get("portions",0))
		m[mid] = int(m.get(mid, 0)) + c
	return m

func container_decay_end_of_day() -> void:
	culling_spoiled_food()

func activate_from_container(meal_id: String, count: int) -> bool:
	return activate_from_fridge(meal_id, count)


# ─────────────────────────────────────────────────────────────────────
# AUGMENT EFFECTS — RUNTIME HOOKS
# Ожидаемый формат в JSON:
#  { "effects": {
#      "stat_mod": { "attack": +5, "max_health": +15, ... },
#      "on_battle_start": ["barrier_2", ...],
#      "basic_attack_mult": 1.25,
#      "cond": "has_negative",
#      "damage_mult": 1.2
#  } }
# ─────────────────────────────────────────────────────────────────────

# ─── КУХНЯ / ЕДА ─────────────────────────────────────────────────────
const RECIPES_PATH := "res://data/recipes.json"
const MEALS_PATH   := "res://data/meals.json"

var recipes_db: Dictionary = {}    # id -> def из recipes.json
var meals_db:   Dictionary = {}    # id -> {satiety:int, tags:Array}

# сытость 0..100
var hero_satiety: Dictionary = {}  # name -> int
# контейнеры/холодильник (ограниченный срок годности)
# [{meal:String, portions:int, expires_day:int, expires_phase:int}]
var fridge: Array = []

# партия, только что приготовленная, ожидание распределения
# {meal:String, portions:int}
var pending_meal: Dictionary = {}

# предпочтения/ограничения героев
var food_prefs := {
	"Berit": {"like":["chicken"], "dislike":["cheap","plain"], "forbid":[]},
	"Sally": {"like":[], "dislike":[], "forbid":["meat"]}, # вегетарианец
	"Dante": {"like":["cheese","weird"], "dislike":["soup"], "forbid":[]}
}

# общий ресурс «Эфирия» тут не нужен; готовка к нему не привязана.

signal cooking_changed   # что-то в кулинарии поменялось (партия/холодильник/сытость)

const CONDITIONS_JSON := "res://Data/conditions.json"
const QUALS_JSON      := "res://Data/qualifications.json"

var conditions_db: Dictionary = {}          # id -> прототип
var hero_conditions: Dictionary = {}        # name -> Array[{id, expire_day?, expire_phase?}]
signal conditions_changed

var quals_db: Dictionary = {}               # id -> {name,icon?}
var qual_rates: Dictionary = {}             # hero -> {qual:mult}
var hero_quals: Dictionary = {}             # hero -> {qual:{lvl:int, xp:int}}

var hero_mood: Dictionary = {}              # 0..100
var hero_current: Dictionary = {}           # name -> {"hp":int,"mana":int,"stamina":int}

# Собирает эффекты всех активных аугментов героя в агрегат
func _aug_collect(hero_name: String) -> Dictionary:
	var out := {
		"stat_mod": {},                 # additively merge
		"start_effects": [],            # array of effect ids
		"basic_mult": 1.0,              # product
		"cond_rules": []                # [{cond:String, mult:float}]
	}
	var active: Array = get_hero_active_augments(hero_name)
	for id in active:
		var def := get_augment_def(String(id))
		if typeof(def) != TYPE_DICTIONARY: continue
		var eff = def.get("effects", {})
		if typeof(eff) != TYPE_DICTIONARY: continue

		# stat_mod
		var sm = eff.get("stat_mod", {})
		if typeof(sm) == TYPE_DICTIONARY:
			for k in sm.keys():
				var add := float(sm[k])
				out["stat_mod"][k] = float(out["stat_mod"].get(k, 0.0)) + add

		# on_battle_start
		var start_arr = eff.get("on_battle_start", [])
		if typeof(start_arr) == TYPE_ARRAY:
			for e in start_arr:
				out["start_effects"].append(String(e))

		# basic_attack_mult
		if eff.has("basic_attack_mult"):
			out["basic_mult"] = float(out["basic_mult"]) * float(eff["basic_attack_mult"])

		# условные мультипликаторы урона
		if eff.has("damage_mult"):
			out["cond_rules"].append({
				"cond": String(eff.get("cond","")), 
				"mult": float(eff.get("damage_mult", 1.0))
			})
	return out

# Применяет stat_mod к словарю статов бойца и возвращает НОВУЮ копию
func aug_apply_to_stats(hero_name: String, base_stats: Dictionary) -> Dictionary:
	var agg := _aug_collect(hero_name)
	var sm: Dictionary = agg["stat_mod"]
	var out := base_stats.duplicate(true)

	for k in sm.keys():
		var add := int(round(float(sm[k])))
		# поддерживаем обе схемы ключей
		if k == "max_hp" and not out.has("max_hp") and out.has("max_health"):
			out["max_health"] = int(out.get("max_health", 0)) + add
		else:
			out[k] = int(out.get(k, 0)) + add

	# если увеличили максимум — можно, при желании, синхронно поднять текущее значение
	if out.has("max_health") and out.has("health"):
		out["health"] = min(int(out["health"]), int(out["max_health"]))
	if out.has("max_hp") and out.has("hp"):
		out["hp"] = min(int(out["hp"]), int(out["max_hp"]))

	return out

# Эффекты, которые нужно навесить в начале боя (id-шники из effects.json)
func get_aug_start_effects(hero_name: String) -> Array:
	return Array(_aug_collect(hero_name)["start_effects"]).duplicate()

# Множитель урона с учётом basic_attack_mult и условных правил
# ctx:
#   { "is_basic": bool,
#     "self_has_negative": bool,    # на атакующем есть негатив
#     "target_has_negative": bool } # (на всякий) на цели есть негатив
func aug_damage_mult(hero_name: String, ctx: Dictionary) -> float:
	var agg := _aug_collect(hero_name)
	var m := float(agg["basic_mult"])
	if not bool(ctx.get("is_basic", false)):
		# basic_mult действует только на базовую атаку
		m = 1.0
	# условные множители
	for rule in Array(agg["cond_rules"]):
		var cond := String(rule.get("cond",""))
		var ok := _aug_check_cond(cond, ctx)
		if ok:
			m *= float(rule.get("mult", 1.0))
	return max(m, 0.0)

func _aug_check_cond(cond: String, ctx: Dictionary) -> bool:
	match cond:
		"has_negative":
			return bool(ctx.get("self_has_negative", false))
		"target_has_negative":
			return bool(ctx.get("target_has_negative", false))
		"":
			return true # без условия — всегда
		_:
			# неизвестные условия считаем ложью
			return false

# Удобный предпросмотр для UI (меню/карточка героя)
func get_augmented_stats_preview(hero_name: String) -> Dictionary:
	var d = all_heroes.get(hero_name, {})
	if typeof(d) != TYPE_DICTIONARY:
		return {}
	return aug_apply_to_stats(hero_name, d)

# Помощник для старта боя: накинуть стартовые эффекты на узел бойца
# Подставь внутрь вызов твоего метода добавления эффектов.



# ------------- Quests -------------
func _load_quests_from_json(path: String) -> void:
	quests_all = {}
	task_defs = {}
	daily_pools = {}

	if not FileAccess.file_exists(path):
		push_warning("[Quests] file not found: " + path)
		emit_signal("quests_changed")
		return

	var txt := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(txt)

	var root: Dictionary = {}
	if typeof(parsed) == TYPE_DICTIONARY:
		root = parsed

	# defs задач и ежедневные пулы (если есть в файле)
	var td: Dictionary = root.get("task_defs", {})
	if typeof(td) == TYPE_DICTIONARY:
		task_defs = td.duplicate(true)

	var dp: Dictionary = root.get("daily_pools", {})
	if typeof(dp) == TYPE_DICTIONARY:
		daily_pools = dp.duplicate(true)

	# собственно квесты
	var arr: Array = root.get("quests", [])
	var map: Dictionary = {}
	for q in arr:
		if typeof(q) != TYPE_DICTIONARY:
			continue
		var id := String(q.get("id",""))
		if id == "":
			continue
		map[id] = q

	quests_all = map
	task_defs   = root.get("task_defs", {}).duplicate(true)
	daily_pools = root.get("daily_pools", {}).duplicate(true)
	emit_signal("quests_changed")


func get_sorted_quests() -> Array:
	# только доступные, незавершённые сверху
	var out: Array = []
	for id in quests_all.keys():
		var q: Dictionary = quests_all[id]
		if bool(q.get("available", false)):
			out.append(q)
	out.sort_custom(func(a, b):
		var ac := bool((a as Dictionary).get("completed", false))
		var bc := bool((b as Dictionary).get("completed", false))
		if ac != bc:
			return ac < bc
		return String(a.get("name","")) < String(b.get("name",""))
	)
	return out

func set_quest_available(id: String, avail: bool) -> void:
	if not quests_all.has(id): return
	quests_all[id]["available"] = avail
	emit_signal("quests_changed")

func set_quest_completed(id: String, done: bool) -> void:
	if not quests_all.has(id): return
	quests_all[id]["completed"] = done
	emit_signal("quests_changed")

func get_quest_rewards(id: String) -> Dictionary:
	if not quests_all.has(id):
		return {}
	var q: Dictionary = quests_all[id]
	if q.has("rewards"):
		return q["rewards"]
	return {}


func award_rewards(rew: Dictionary) -> void:
	if typeof(rew) != TYPE_DICTIONARY: 
		return
	# деньги
	var kc := int(rew.get("krestli", 0))
	if kc > 0:
		krestli += kc
	# предметы в базу
	var items: Array = rew.get("items", [])
	if typeof(items) == TYPE_ARRAY:
		for e in items:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var id := String(e.get("id",""))
			var cnt := int(e.get("count", 0))
			if id != "" and cnt > 0:
				add_to_base(id, cnt)

# ------------- Archive -------------
func _load_archive_from_json(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("[Archive] file not found: " + path)
		archive_db = {}
		emit_signal("archive_changed")
		return
	var txt := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(txt)
	var root = (parsed if typeof(parsed) == TYPE_DICTIONARY else {})
	var cats: Dictionary = root.get("categories", {})
	# фильтруем только категории с минимум одной доступной записью
	var cleaned: Dictionary = {}
	for cat in cats.keys():
		var src_arr: Array = cats[cat]
		if typeof(src_arr) != TYPE_ARRAY:
			continue
		var dst: Array = []
		for e in src_arr:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var av := true
			if e.has("available"):
				av = bool(e["available"])
			if av:
				dst.append(e)
		if dst.size() > 0:
			cleaned[String(cat)] = dst
	archive_db = cleaned
	emit_signal("archive_changed")

func get_archive_categories() -> Array:
	var keys := archive_db.keys()
	keys.sort()
	return keys

func get_archive_entries(cat: String) -> Array:
	if not archive_db.has(cat): return []
	return (archive_db[cat] as Array).duplicate(true)

func get_archive_image_path(file_name: String) -> String:
	if file_name == "": 
		return ""
	return ARCHIVE_IMG_DIR + file_name


func add_codex_entry(key: String, text: String) -> void:
	codex[key] = text
	emit_signal("codex_changed")

# ============ QUESTS ============
signal quests_changed

func add_or_update_quest(id: String, name: String, desc: String, completed: bool=false) -> void:
	var found := false
	for q in active_quests:
		if String(q.get("id","")) == id:
			q["name"] = name
			q["desc"] = desc
			q["completed"] = completed
			found = true
			emit_signal("quests_changed")
			break
	if not found:
		active_quests.append({"id": id, "name": name, "desc": desc, "completed": completed})
		spawn_quest_tasks(id)
		emit_signal("quests_changed")



# ============ SKILLS (экип скиллов) ============
func get_hero_skills(hero_name: String) -> Array:
	if not all_heroes.has(hero_name): return []
	return (all_heroes[hero_name] as Dictionary).get("skills", [])

func _ensure_equipped_skills(hero_name: String) -> void:
	if not all_heroes.has(hero_name): return
	var d: Dictionary = all_heroes[hero_name]
	var eq = d.get("equipped_skills", [])
	if typeof(eq) != TYPE_ARRAY: eq = []
	# допустимые скиллы по именам
	var allowed: Array = []
	for s in d.get("skills", []):
		if typeof(s) == TYPE_DICTIONARY:
			allowed.append(String(s.get("name","")))
	var filtered: Array = []
	for sid in eq:
		if allowed.has(String(sid)):
			filtered.append(String(sid))
	while filtered.size() > EQUIP_SKILL_LIMIT:
		filtered.pop_back()
	d["equipped_skills"] = filtered
	all_heroes[hero_name] = d

func get_equipped_skill_ids(hero_name: String) -> Array:
	_ensure_equipped_skills(hero_name)
	return (all_heroes[hero_name] as Dictionary).get("equipped_skills", []).duplicate()

func equip_skill(hero_name: String, skill_id: String) -> bool:
	_ensure_equipped_skills(hero_name)
	var d: Dictionary = all_heroes[hero_name]
	var eq: Array = d.get("equipped_skills", [])
	if eq.has(skill_id): return true
	if eq.size() >= EQUIP_SKILL_LIMIT: return false
	# проверка, что скилл существует у героя
	var ok := false
	for s in d.get("skills", []):
		if typeof(s)==TYPE_DICTIONARY and String(s.get("name","")) == skill_id:
			ok = true; break
	if not ok: return false
	eq.append(skill_id)
	d["equipped_skills"] = eq
	all_heroes[hero_name] = d
	return true

func unequip_skill(hero_name: String, skill_id: String) -> void:
	_ensure_equipped_skills(hero_name)
	var d: Dictionary = all_heroes[hero_name]
	var eq: Array = d.get("equipped_skills", [])
	eq.erase(skill_id)
	d["equipped_skills"] = eq
	all_heroes[hero_name] = d

func get_skill_def(hero_name: String, skill_id: String) -> Dictionary:
	for s in get_hero_skills(hero_name):
		if typeof(s)==TYPE_DICTIONARY and String(s.get("name","")) == skill_id:
			return s
	return {}


func _bag_from_pack(pack: Array) -> Dictionary:
	var bag: Dictionary = {}
	for e in pack:
		if typeof(e) != TYPE_DICTIONARY: continue
		var id := String(e.get("id",""))
		var c  := int(e.get("count",0))
		if id != "" and c > 0:
			bag[id] = int(bag.get(id, 0)) + c
	return bag

func _pack_from_bag(bag: Dictionary) -> Array:
	var arr: Array = []
	for id in bag.keys():
		var cnt := int(bag[id])
		if cnt > 0:
			arr.append({"id": id, "count": cnt})
	return arr
	
func ensure_bag(hero_name: String) -> void:
	if hero_name == "": return
	if hero_bags.has(hero_name): return
	var h = all_heroes.get(hero_name, null)
	if typeof(h) != TYPE_DICTIONARY:
		hero_bags[hero_name] = {}
		return
	var pack = h.get("pack", [])
	if typeof(pack) != TYPE_ARRAY:
		pack = []
	hero_bags[hero_name] = _bag_from_pack(pack)
	
func move_base_to_bag(hero_name: String, id: String, count: int) -> int:
	if count <= 0: return 0
	ensure_bag(hero_name)

	var have := int(base_inventory.get(id, 0))
	var take = min(count, have)
	if take <= 0: return 0

	var bag: Dictionary = hero_bags.get(hero_name, {})
	# лимит ячеек (разных предметов)
	var slots_max := int(all_heroes.get(hero_name, {}).get("carry_slots_max", 5))
	var slots_used := 0
	for k in bag.keys():
		if int(bag[k]) > 0:
			slots_used += 1
	if not bag.has(id) and slots_used >= slots_max:
		return 0

	base_inventory[id] = have - take
	bag[id] = int(bag.get(id, 0)) + take
	hero_bags[hero_name] = bag
	_sync_pack(hero_name)
	return take

func move_bag_to_base(hero_name: String, id: String, count: int) -> int:
	if count <= 0: return 0
	ensure_bag(hero_name)

	var bag: Dictionary = hero_bags.get(hero_name, {})
	var have := int(bag.get(id, 0))
	var give = min(count, have)
	if give <= 0: return 0

	bag[id] = have - give
	if int(bag[id]) <= 0:
		bag.erase(id)
	base_inventory[id] = int(base_inventory.get(id, 0)) + give
	hero_bags[hero_name] = bag
	_sync_pack(hero_name)
	return give

func item_title(id: String) -> String:
	var def := get_item_def(id)
	return String(def.get("name", id))

func _sync_pack(hero_name: String) -> void:
	if not all_heroes.has(hero_name): return
	var h: Dictionary = all_heroes[hero_name]
	var bag: Dictionary = hero_bags.get(hero_name, {})
	h["pack"] = _pack_from_bag(bag)
	all_heroes[hero_name] = h


func bag_get(hero_name: String, id: String) -> int:
	var bag: Dictionary = hero_bags.get(hero_name, {})
	return int(bag.get(id, 0))

func bag_add(hero_name: String, id: String, count: int) -> void:
	if count <= 0 or id == "": return
	ensure_bag(hero_name)
	var bag: Dictionary = hero_bags[hero_name]
	bag[id] = int(bag.get(id, 0)) + count
	hero_bags[hero_name] = bag

func bag_take(hero_name: String, id: String, count: int) -> int:
	if count <= 0 or id == "": return 0
	ensure_bag(hero_name)
	var bag: Dictionary = hero_bags[hero_name]
	var have := int(bag.get(id, 0))
	var take = min(have, count)
	if take > 0:
		var left = have - take
		if left > 0: bag[id] = left
		else: bag.erase(id)
		hero_bags[hero_name] = bag
	return take

func get_party_hero_defs() -> Array:  # удобно для статусов
	var out: Array = []
	for name in party_names:
		if all_heroes.has(name):
			out.append(all_heroes[name])
	return out

func load_dante_enhance(json_path: String = "res://data/dante_enhance.json") -> void:
	if _dante_loaded:
		return
	_dante_loaded = true

	var data_str := ""
	if FileAccess.file_exists(json_path):
		data_str = FileAccess.get_file_as_string(json_path)
	else:
		var alt_path := "user://dante_enhance.json"
		if FileAccess.file_exists(alt_path):
			data_str = FileAccess.get_file_as_string(alt_path)

	if data_str == "":
		print("[DANTE] dante_enhance.json не найден")
		dante_enhance = {}
		return

	var parsed = JSON.parse_string(data_str)
	if typeof(parsed) == TYPE_DICTIONARY:
		dante_enhance = parsed
	else:
		print("[DANTE] Ошибка парсинга dante_enhance.json")
		dante_enhance = {}

# Геттер порога заряда для усиленного варианта; на вход — словарь навыка
func get_dante_charge_cost(skill: Dictionary) -> int:
	load_dante_enhance()
	var name := String(skill.get("name",""))
	if name == "" or dante_enhance.is_empty() or not dante_enhance.has(name):
		return -1
	var entry = dante_enhance[name]
	var consume = entry.get("consume", {})
	if typeof(consume) != TYPE_DICTIONARY:
		return -1
	return int(consume.get("charge", -1))

static func get_sally_words_pool() -> Array:
	if _sally_words_pool.size() > 0:
		return _sally_words_pool

	# подставь свой путь, тот же файл, что и для enhance
	var path := "res://data/sally_enhance.json"
	var f := FileAccess.open(path, FileAccess.READ)
	if f:
		var txt := f.get_as_text()
		f.close()
		var j = JSON.new()
		if j.parse(txt) == OK:
			var root = j.get_data()
			if typeof(root) == TYPE_DICTIONARY and root.has("words"):
				var arr: Array = root["words"]
				for x in arr:
					_sally_words_pool.append(String(x))
	if _sally_words_pool.is_empty():
		# страховка, если JSON не найден/пуст
		_sally_words_pool = ["кровь","любовь","ветер","тишина","гнев","пепел","шёпот","золото","снег","вино"]

	return _sally_words_pool
	
func get_dante_enhance_block(skill_name: String) -> Dictionary:
	load_dante_enhance()
	if skill_name == "" or dante_enhance.is_empty():
		return {}
	if not dante_enhance.has(skill_name):
		return {}
	var entry = dante_enhance[skill_name]
	return entry.get("enhance", {})


func load_effects_db() -> void:
	EFFECTS_DB.clear()
	var path := EFFECTS_FILE
	if not FileAccess.file_exists(path):
		print("[EFFECTS] file not found: ", path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("[EFFECTS] open failed: ", path)
		return
	var raw := f.get_as_text()
	f.close()

	var parsed = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		print("[EFFECTS] invalid JSON root")
		return

	var root: Dictionary = parsed
	var src: Dictionary = root.get("effects", {})
	for k in src.keys():
		var v = src[k]
		if typeof(v) == TYPE_DICTIONARY:
			# храним глубокую копию, чтобы в рантайме никто не замутировал прототип
			EFFECTS_DB[String(k)] = (v as Dictionary).duplicate(true)

	print("[EFFECTS] loaded: ", EFFECTS_DB.size())

func get_effect_proto(id: String) -> Dictionary:
	if EFFECTS_DB.has(id):
		return (EFFECTS_DB[id] as Dictionary).duplicate(true)
	return {}

# ── ДОБАВИТЬ: ленивый лоад ───────────────────────────────────────────
func _ensure_sally_enh_loaded() -> void:
	if not _sally_enh_cache.is_empty():
		return
	if ResourceLoader.exists(SALLY_ENH_JSON):
		var f := FileAccess.open(SALLY_ENH_JSON, FileAccess.READ)
		if f:
			var txt := f.get_as_text()
			var parsed = JSON.parse_string(txt)
			if typeof(parsed) == TYPE_DICTIONARY:
				_sally_enh_cache = parsed
			else:
				_sally_enh_cache = {}
	else:
		_sally_enh_cache = {}
		
func get_dante_charge(h: Node) -> int:
	if h == null:
		return 0
	var v := int(h.get_meta("dante_charge", 50))
	return clampi(v, 0, 100)

func set_dante_charge(h: Node, v: int) -> void:
	if h == null:
		return
	h.set_meta("dante_charge", clampi(int(v), 0, 100))

# ── ДОБАВИТЬ: публичный геттер «как у Берита» ────────────────────────
func get_sally_enhance(skill_name: String, mode: String) -> Dictionary:
	# mode ожидается "blue" или "gold"
	_ensure_sally_enh_loaded()
	var enh_root: Dictionary = _sally_enh_cache.get("enhance", {})
	var by_skill: Dictionary = enh_root.get(skill_name, {})
	return by_skill.get(mode, {})
	
func load_supplies_db(path: String = SUPPLIES_JSON) -> void:
	supplies_db.clear()
	if not FileAccess.file_exists(path):
		push_warning("[Supplies] file not found: " + path)
		return
	var txt := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[Supplies] JSON parse error")
		return
	var root: Dictionary = parsed
	var dict: Dictionary = root.get("supplies", {})
	if typeof(dict) == TYPE_DICTIONARY:
		supplies_db = dict.duplicate(true)
	# категории можно хранить просто внутри БД, чтобы красиво подписывать
	if not root.get("categories", null) == null:
		supplies_db["_categories"] = root.get("categories", {}).duplicate(true)

func get_supply_def(id: String) -> Dictionary:
	return supplies_db.get(id, {})

func supply_title(id: String) -> String:
	var d := get_supply_def(id)
	return String(d.get("name", id))

func supply_desc(id: String) -> String:
	var d := get_supply_def(id)
	return String(d.get("desc", ""))

func get_supply_icon_path(id: String) -> String:
	var d := get_supply_def(id)
	var icon := String(d.get("icon", ""))
	if icon == "": return ""
	# если в icon указан полный путь — используем его
	if icon.begins_with("res://") or icon.begins_with("user://"):
		return icon
	return SUPPLIES_ICON_DIR + icon + ".png"

func supplies_add(id: String, count: int) -> void:
	if count <= 0: return
	if not supplies_db.has(id):
		push_warning("[Supplies] add: unknown id: " + id)
		return
	supplies_inventory[id] = int(supplies_inventory.get(id, 0)) + count
	emit_signal("supplies_changed")

func supplies_take(id: String, count: int) -> int:
	if count <= 0: return 0
	var have := int(supplies_inventory.get(id, 0))
	var take = min(have, count)
	if take > 0:
		supplies_inventory[id] = have - take
	emit_signal("supplies_changed")
	return take

# категории, у которых есть хотя бы один предмет с count>0 (или все, если want_all=true)
func get_supply_categories(want_all := false) -> Array:
	var present: Dictionary = {}
	# сначала соберём из инвентаря
	for id in supplies_inventory.keys():
		var cnt := int(supplies_inventory[id])
		if cnt <= 0 and not want_all: continue
		var cat := String(get_supply_def(id).get("category", "misc"))
		present[cat] = true
	# если нужно все категории — добавим из БД
	if want_all and supplies_db.has("_categories"):
		for c in (supplies_db["_categories"] as Dictionary).keys():
			present[String(c)] = true
	var out: Array = present.keys()
	out.sort()
	return out

# записи по категории: [{id,title,count,desc,icon}]
func get_supply_entries(cat: String) -> Array:
	var rows: Array = []
	for id in supplies_db.keys():
		if id == "_categories": continue
		var def: Dictionary = supplies_db[id]
		var def_cat := String(def.get("category","misc"))
		if def_cat != cat: continue
		var cnt := int(supplies_inventory.get(id, 0))
		if cnt <= 0: continue
		rows.append({
			"id": id,
			"title": supply_title(id),
			"count": cnt,
			"desc": supply_desc(id),
			"icon": get_supply_icon_path(id)
		})
	rows.sort_custom(func(a, b): return String(a["title"]) < String(b["title"]))
	return rows

# удобные проверка/расход для будущих рецептов
func supplies_has(requirements: Dictionary) -> bool:
	for id in requirements.keys():
		if int(supplies_inventory.get(String(id), 0)) < int(requirements[id]):
			return false
	return true

func supplies_consume(requirements: Dictionary) -> bool:
	if not supplies_has(requirements): return false
	for id in requirements.keys():
		var s := String(id)
		var need := int(requirements[id])
		supplies_inventory[s] = int(supplies_inventory.get(s, 0)) - need
	emit_signal("supplies_changed")
	return true

# локализованная подпись категории
func supply_category_title(cat: String) -> String:
	var dict = supplies_db.get("_categories", {})
	if typeof(dict) == TYPE_DICTIONARY and dict.has(cat):
		return String(dict[cat])
	return cat



func _load_berit_mechanics() -> void:
	if _berit_mech_loaded:
		return
	_berit_mech_loaded = true
	var path := "res://Data/berit_mechanics.json"
	if not ResourceLoader.exists(path):
		push_warning("Не найден berit_mechanics.json по пути: " + path)
		_berit_recipes = {}
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f:
		var text := f.get_as_text()
		f.close()
		var data = JSON.parse_string(text)
		if typeof(data) == TYPE_DICTIONARY:
			_berit_recipes = data
		else:
			_berit_recipes = {}
	else:
		_berit_recipes = {}

func get_berit_recipe(skill_name: String) -> Dictionary:
	_load_berit_mechanics()
	if _berit_recipes.has(skill_name):
		var d = _berit_recipes[skill_name]
		if typeof(d) == TYPE_DICTIONARY:
			return d
	return {}

func load_enemies_db(path: String = "res://Data/enemies.json") -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[Enemies] DB not found: " + path)
		return
	var txt := f.get_as_text()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[Enemies] JSON parse error")
		return
	enemies_db = parsed.get("enemies", {})

func get_enemy_def(id: String) -> Dictionary:
	return enemies_db.get(id, {})
	
func _load_recipes() -> void:
	recipes_db = {}
	if FileAccess.file_exists(RECIPES_PATH):
		var s := FileAccess.get_file_as_string(RECIPES_PATH)
		var j = JSON.parse_string(s)
		if typeof(j) == TYPE_DICTIONARY:
			recipes_db = j.get("recipes", {})

func _load_meals() -> void:
	meals_db = {}
	if FileAccess.file_exists(MEALS_PATH):
		var s := FileAccess.get_file_as_string(MEALS_PATH)
		var j = JSON.parse_string(s)
		if typeof(j) == TYPE_DICTIONARY:
			meals_db = j.get("meals", {})

func _init_satiety_defaults() -> void:
	for n in party_names:
		if not hero_satiety.has(n):
			hero_satiety[n] = 50

# Хранилище припасов: id -> int. Если у тебя уже есть – используй его.
var supplies: Dictionary = {
	"cereal_pack": 4,
	"milk_pack": 2,
	"nuggets_pack": 1,
	"carrot": 1,
	# половинки (для примера пусто)
	"cereal_half": 0,
	"milk_half": 0
}

func supply_get(id: String) -> float:
	return float(supplies.get(id, 0))

func supply_add(id: String, qty: float) -> void:
	if qty <= 0: return
	supplies[id] = float(supplies.get(id, 0)) + qty
	emit_signal("supplies_changed")

func supply_can_take(req: Dictionary) -> bool:
	for id in req.keys():
		var need := float(req[id])
		if float(supplies.get(id, 0)) < need:
			return false
	return true

func supply_take(req: Dictionary) -> bool:
	if not supply_can_take(req): return false
	for id in req.keys():
		var need := float(req[id])
		supplies[id] = float(supplies.get(id, 0)) - need
		if supplies[id] <= 0.0001:
			supplies.erase(id)
	emit_signal("supplies_changed")
	return true

func recipe_defs() -> Array:
	return recipes_db.keys()

func get_recipe_def(id: String) -> Dictionary:
	return recipes_db.get(id, {})

func get_meal_def(id: String) -> Dictionary:
	return meals_db.get(id, {})

# можно ли приготовить N порций (скалируем inputs)
func can_cook(recipe_id: String, portions: int) -> bool:
	var r := get_recipe_def(recipe_id)
	if r.is_empty(): return false
	var base_port := int(r.get("portions", 1))
	if base_port <= 0: return false
	var scale := float(portions) / float(base_port)
	var need := {}
	for e in r.get("inputs", []):
		if typeof(e) != TYPE_DICTIONARY: continue
		var sid := str(e.get("id",""))
		var qty := float(e.get("qty", 0.0)) * scale
		need[sid] = float(need.get(sid, 0.0)) + qty
	return supply_can_take(need)

# вернёт {need:Dictionary, leftovers:Array<{id,qty}>}
func preview_cook(recipe_id: String, portions: int) -> Dictionary:
	var r := get_recipe_def(recipe_id)
	if r.is_empty(): return {}
	var base_port := int(r.get("portions", 1))
	if base_port <= 0: base_port = 1
	var scale := float(portions) / float(base_port)
	var need := {}
	for e in r.get("inputs", []):
		var sid := str(e.get("id",""))
		var qty := float(e.get("qty", 0.0)) * scale
		need[sid] = float(need.get(sid, 0.0)) + qty
	var lo: Array = []
	for e in r.get("leftovers", []):
		lo.append({"id": str(e.get("id","")), "qty": float(e.get("qty", 0.0)) * scale})
	return {"need": need, "leftovers": lo}

# собственно готовим
func cook(recipe_id: String, portions: int) -> bool:
	if portions <= 0:
		return false
	if not can_cook(recipe_id, portions):
		return false

	# 1) Если уже есть «живая» партия — целиком отправляем её в контейнер (TTL 2 фазы)
	if not pending_meal.is_empty():
		var prev_id := str(pending_meal.get("meal",""))
		var prev_left := int(pending_meal.get("portions",0))
		if prev_id != "" and prev_left > 0:
			_fridge_add(prev_id, prev_left, CONTAINER_TTL_PHASES)
		pending_meal.clear()

	# 2) Спишем ресурсы и создадим новую партию
	var pr := preview_cook(recipe_id, portions)
	var need: Dictionary = pr.get("need", {})
	if not supply_take(need):   # твоя сигнатура: принимает словарь id->qty
		return false

	for e in pr.get("leftovers", []):
		var sid := str(e.get("id",""))
		var qty := float(e.get("qty", 0.0))
		if sid != "" and qty > 0.0:
			supply_add(sid, qty)

	pending_meal = {"meal": recipe_id, "portions": portions, "total": portions}
	emit_signal("cooking_changed")
	return true


func _meal_tags(meal_id: String) -> Array:
	var d := get_meal_def(meal_id)
	if typeof(d) == TYPE_DICTIONARY:
		return Array(d.get("tags", []))
	return []

func _likes(name: String) -> Array:
	return Array(food_prefs.get(name, {}).get("like", []))
func _dislikes(name: String) -> Array:
	return Array(food_prefs.get(name, {}).get("dislike", []))
func _forbid(name: String) -> Array:
	return Array(food_prefs.get(name, {}).get("forbid", []))

func can_hero_eat(name: String, meal_id: String) -> bool:
	var tags := _meal_tags(meal_id)
	for t in _forbid(name):
		if tags.has(t): return false
	# спец-кейс для Данте — может «weird/nonfood» в будущем
	return true

# модификатор «нравится/не нравится»
func meal_satiety_mod(name: String, meal_id: String) -> float:
	var tags := _meal_tags(meal_id)
	var mod := 1.0
	for t in _likes(name):
		if tags.has(t): mod *= 1.25
	for t in _dislikes(name):
		if tags.has(t): mod *= 0.8
	return mod

func meal_satiety_value(meal_id: String) -> int:
	var d := get_meal_def(meal_id)
	return int(d.get("satiety", 15))

# Раздать приготовленные порции: assign = {hero:String -> int}, to_container:int
# Контейнеры кладём с «сроком годности» на 2 фазы.
func distribute_pending(assign: Dictionary, to_container: int) -> Dictionary:
	var res := {"served": {}, "rejected": [], "left": 0, "stored": 0}
	if pending_meal.is_empty():
		return res
	var meal := str(pending_meal.get("meal",""))
	var left := int(pending_meal.get("portions", 0))
	if left <= 0:
		return res

	# Кормим
	for hero in assign.keys():
		var want := int(assign[hero])
		if want <= 0: continue
		if not can_hero_eat(hero, meal):
			res["rejected"].append(hero)
			continue
		var give = min(want, left)
		if give <= 0: break

		var base := meal_satiety_value(meal)
		var mod  := meal_satiety_mod(hero, meal)
		var add  = int(round(float(base) * mod)) * give

		hero_satiety[hero] = clampi(int(hero_satiety.get(hero, 50)) + add, 0, 100)
		res["served"][hero] = give
		left -= give

	# В контейнер (если остались)
	var store = min(int(to_container), left)
	if store > 0:
		var exp_day := day
		var exp_phase := current_phase + 2
		while exp_phase >= phase_names.size():
			exp_phase -= phase_names.size()
			exp_day += 1
		fridge.append({"meal": meal, "portions": store, "expires_day": exp_day, "expires_phase": exp_phase})
		left -= store
		res["stored"] = store

	res["left"] = left
	pending_meal = {"meal": meal, "portions": left}
	emit_signal("cooking_changed")
	return res

func culling_spoiled_food() -> void:
	var keep: Array = []
	for e in fridge:
		var d := int(e.get("expires_day", 0))
		var p := int(e.get("expires_phase", 0))
		var spoil := (day > d) or (day == d and current_phase > p)
		if not spoil:
			keep.append(e)
	fridge = keep
	emit_signal("cooking_changed")




func _ready() -> void:
	load_heroes("res://Data/characters.json")
	load_items_db("res://Data/items.json") 
	load_enemies_db("res://Data/enemies.json")
	load_effects_db()
	load_dante_enhance()
	load_supplies_db()
	add_to_base("sandwich", 10)
	_build_hero_bags_from_pack()
	_load_quests_from_json(QUESTS_FILE)
	_load_archive_from_json(ARCHIVE_FILE)
	supplies_add("cereal_box",   4)
	supplies_add("milk_pack",    2)
	supplies_add("nuggets_pack", 1)
	supplies_add("carrot",       1)
	emit_signal("supplies_changed")
		# --- АУГМЕНТЫ ---
	load_augments_db()
	_init_ether_caps()    # у всех 10 по умолчанию
	# демо: откроем несколько аугментов и дадим немного эфирии
	unlock_augment("atk_up_s")
	unlock_augment("hp_up_s")
	unlock_augment("start_barrier")
	etheria = 2
	emit_signal("augments_changed")
		# кухня
	_load_recipes()
	_load_meals()
	_init_satiety_defaults()
	load_conditions_db()
	load_quals_db()
	_init_satiety_defaults()
	_init_mood_defaults()
	_init_current_resources()
	
func _init_mood_defaults() -> void:
	for n in party_names:
		if not hero_mood.has(n):
			hero_mood[n] = 50

func _init_current_resources() -> void:
	for n in party_names:
		var d: Dictionary = all_heroes.get(n, {})
		var cur := {
			"hp": int(d.get("max_hp", d.get("max_health", 100))),
			"mana": int(d.get("max_mana", 0)),
			"stamina": int(d.get("max_stamina", 0))
		}
		hero_current[n] = cur

func load_conditions_db(path: String = CONDITIONS_JSON) -> void:
	conditions_db = {}
	if FileAccess.file_exists(path):
		var s := FileAccess.get_file_as_string(path)
		var j = JSON.parse_string(s)
		if typeof(j) == TYPE_DICTIONARY:
			conditions_db = j.get("conditions", {})
	emit_signal("conditions_changed")

func get_condition_def(id: String) -> Dictionary:
	return conditions_db.get(id, {})

func condition_title(id: String) -> String:
	var d := get_condition_def(id)
	return String(d.get("name", id))

func add_condition(hero: String, id: String, days := 0, phases := 0) -> void:
	if hero == "" or id == "" or not conditions_db.has(id):
		return
	var arr: Array = hero_conditions.get(hero, [])
	var exp_day := day + int(days)
	var exp_phase := current_phase + int(phases)
	while exp_phase >= phase_names.size():
		exp_phase -= phase_names.size()
		exp_day += 1
	arr.append({"id": id, "expire_day": exp_day, "expire_phase": exp_phase})
	hero_conditions[hero] = arr
	emit_signal("conditions_changed")

func remove_condition(hero: String, id: String) -> void:
	var arr: Array = hero_conditions.get(hero, [])
	var out: Array = []
	for e in arr:
		if String(e.get("id","")) != id:
			out.append(e)
	hero_conditions[hero] = out
	emit_signal("conditions_changed")

func get_active_conditions(hero: String) -> Array:
	return (hero_conditions.get(hero, []) as Array).duplicate(true)

func cond_apply_to_stats(hero_name: String, base_stats: Dictionary) -> Dictionary:
	var out := base_stats.duplicate(true)
	for e in get_active_conditions(hero_name):
		var id := String(e.get("id",""))
		var def := get_condition_def(id)
		if typeof(def) != TYPE_DICTIONARY: continue
		var sm: Dictionary = def.get("stat_mod", {})
		for k in sm.keys():
			if k.ends_with("_pct"):
				# процентные модификаторы, например max_health_pct
				var stat_key = k.substr(0, k.length() - 4)
				var mult := 1.0 + float(sm[k])
				out[stat_key] = int(round(float(out.get(stat_key, 0)) * mult))
			else:
				out[k] = int(out.get(k, 0)) + int(sm[k])
	return out

func get_cond_start_effects(hero_name: String) -> Array:
	var arr: Array = []
	for e in get_active_conditions(hero_name):
		var id := String(e.get("id",""))
		var def := get_condition_def(id)
		for fx in Array(def.get("on_battle_start", [])):
			arr.append(String(fx))
	return arr

func _tick_conditions_and_phase_effects() -> void:
	var changed := false
	for hero in party_names:
		var src: Array = hero_conditions.get(hero, [])
		var keep: Array = []
		for e in src:
			var ed := int(e.get("expire_day", 99999))
			var ep := int(e.get("expire_phase", 99999))
			var expired := (day > ed) or (day == ed and current_phase > ep)
			if not expired:
				# on_phase эффекты
				var def := get_condition_def(String(e.get("id","")))
				var onp: Dictionary = def.get("on_phase", {})
				if not onp.is_empty():
					var cur: Dictionary = hero_current.get(hero, {})
					if onp.has("mana") and String(onp["mana"]) == "zero":
						cur["mana"] = 0
						hero_current[hero] = cur
						changed = true
				keep.append(e)
			else:
				changed = true
		hero_conditions[hero] = keep
	if changed:
		emit_signal("conditions_changed")


func mood_value(hero: String) -> int:
	return clampi(int(hero_mood.get(hero, 50)), 0, 100)

func mood_title(v: int) -> String:
	if v >= 80: return "Отличное"
	if v >= 60: return "Хорошее"
	if v >= 40: return "Нормальное"
	if v >= 20: return "Плохое"
	return "Ужасное"

func res_max(hero: String, key: String) -> int:
	var d: Dictionary = all_heroes.get(hero, {})
	match key:
		"hp":      return int(d.get("max_hp", d.get("max_health", 100)))
		"mana":    return int(d.get("max_mana", 0))
		"stamina": return int(d.get("max_stamina", 0))
		_:         return 0

func res_cur(hero: String, key: String) -> int:
	return int((hero_current.get(hero, {}) as Dictionary).get(key, res_max(hero, key)))

func set_res_cur(hero: String, key: String, v: int) -> void:
	var cur: Dictionary = hero_current.get(hero, {})
	cur[key] = clampi(v, 0, res_max(hero, key))
	hero_current[hero] = cur

func load_quals_db(path: String = QUALS_JSON) -> void:
	quals_db = {}
	qual_rates = {}
	if FileAccess.file_exists(path):
		var s := FileAccess.get_file_as_string(path)
		var j = JSON.parse_string(s)
		if typeof(j) == TYPE_DICTIONARY:
			quals_db = j.get("quals", {})
			qual_rates = j.get("rates", {})
	# инициализируем хранилище прогресса
	for n in party_names:
		if not hero_quals.has(n):
			hero_quals[n] = {}

func qual_title(id: String) -> String:
	return String(quals_db.get(id, {}).get("name", id))

func qual_rate(hero: String, q: String) -> float:
	var r: Dictionary = qual_rates.get(hero, {})
	return float(r.get(q, 1.0))

func qual_xp_needed(lvl: int) -> int:
	lvl = max(1, lvl)
	return 100 * int(pow(2.0, float(lvl - 1)))

func add_qual_xp(hero: String, q: String, raw_xp: int) -> void:
	if not quals_db.has(q): return
	var store: Dictionary = hero_quals.get(hero, {})
	var cur: Dictionary = store.get(q, {"lvl": 0, "xp": 0})
	var gain := int(round(float(raw_xp) * qual_rate(hero, q)))
	cur["xp"] = int(cur.get("xp", 0)) + gain
	# апаем уровни
	while true:
		var need := qual_xp_needed(int(cur.get("lvl", 0)) + 1)
		if int(cur["xp"]) >= need:
			cur["xp"] -= need
			cur["lvl"] = int(cur.get("lvl", 0)) + 1
		else:
			break
	store[q] = cur
	hero_quals[hero] = store

func get_hero_quals_nonzero(hero: String) -> Array:
	var out: Array = []
	var store: Dictionary = hero_quals.get(hero, {})
	for q in store.keys():
		var st: Dictionary = store[q]
		var lvl := int(st.get("lvl", 0))
		if lvl > 0:
			out.append({"id": String(q), "title": qual_title(String(q)), "lvl": lvl, "xp": int(st.get("xp",0)), "need": qual_xp_needed(lvl+1)})
	out.sort_custom(func(a,b): return String(a["title"]) < String(b["title"]))
	return out

# ====== HERO PACKS ============================================================
func _build_hero_bags_from_pack() -> void:
	hero_bags.clear()
	for name in all_heroes.keys():
		var d: Dictionary = all_heroes[name]
		var bag: Dictionary = {}
		var arr: Array = d.get("pack", [])
		if typeof(arr) == TYPE_ARRAY:
			for e in arr:
				if typeof(e) != TYPE_DICTIONARY: 
					continue
				var id := String(e.get("id",""))
				var cnt := int(e.get("count",1))
				if id == "" or cnt <= 0:
					continue
				bag[id] = int(bag.get(id,0)) + cnt
		hero_bags[name] = bag

func get_hero_pack(name: String) -> Array:
	var h = all_heroes.get(name, null)
	if h == null: return []
	var p = h.get("pack", [])
	return (p if typeof(p) == TYPE_ARRAY else [])

func set_hero_pack(name: String, pack: Array) -> void:
	if not all_heroes.has(name): return
	var h: Dictionary = all_heroes[name]
	h["pack"] = pack
	all_heroes[name] = h

static func _pack_slots_used(pack: Array) -> int:
	var s := 0
	for st in pack:
		if typeof(st) == TYPE_DICTIONARY and int(st.get("count", 0)) > 0:
			s += 1
	return s

static func _pack_find_index(pack: Array, id: String) -> int:
	for i in range(pack.size()):
		if String(pack[i].get("id","")) == id:
			return i
	return -1

# база -> герою (ограничение по carry_slots_max)
func give_to_hero(hero_name: String, id: String, count: int) -> int:
	if count <= 0 or not all_heroes.has(hero_name): return 0

	var have := int(base_inventory.get(id, 0))
	var take = min(count, have)
	if take <= 0: return 0

	var h: Dictionary = all_heroes[hero_name]
	var pack: Array = get_hero_pack(hero_name)
	var idx := _pack_find_index(pack, id)
	var slots_max := int(h.get("carry_slots_max", 5))
	var slots_used := _pack_slots_used(pack)

	if idx == -1 and slots_used >= slots_max:
		return 0

	base_inventory[id] = have - take

	if idx == -1:
		pack.append({"id": id, "count": take})
	else:
		pack[idx]["count"] = int(pack[idx].get("count", 0)) + take

	set_hero_pack(hero_name, pack)
	return take

# герой -> база
func take_from_hero(hero_name: String, id: String, count: int) -> int:
	if count <= 0 or not all_heroes.has(hero_name): return 0

	var pack: Array = get_hero_pack(hero_name)
	var idx := _pack_find_index(pack, id)
	if idx == -1: return 0

	var have := int(pack[idx].get("count", 0))
	var give = min(count, have)
	if give <= 0: return 0

	pack[idx]["count"] = have - give
	if int(pack[idx]["count"]) <= 0:
		pack.remove_at(idx)
	set_hero_pack(hero_name, pack)

	base_inventory[id] = int(base_inventory.get(id, 0)) + give
	return give

func load_items_db(path: String = "res://Data/items.json") -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: 
		push_error("[Items] DB not found: " + path); return
	var txt := f.get_as_text()
	items_db = JSON.parse_string(txt)
	if typeof(items_db) != TYPE_DICTIONARY:
		items_db = {}
		push_error("[Items] JSON parse error")

func get_item_def(id: String) -> Dictionary:
	return items_db.get(id, {})

func add_to_base(id: String, count: int) -> void:
	if count <= 0: return
	var cur := int(base_inventory.get(id, 0))
	base_inventory[id] = cur + count

func take_from_base(id: String, count: int) -> int:
	var have := int(base_inventory.get(id, 0))
	var take = min(count, have)
	if take <= 0: return 0
	base_inventory[id] = have - take
	return take

func load_heroes(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_error("Нет файла: %s" % path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var txt := f.get_as_text()
	f.close()
	var data = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("JSON неверного формата")
		return

	party_names = data.get("party", [])
	var heroes_dict: Dictionary = data.get("heroes", {})

	all_heroes.clear()
	for name in heroes_dict.keys():
		all_heroes[name] = heroes_dict[name]

func make_party_dicts() -> Array:
	var out: Array = []
	for name in party_names:
		if all_heroes.has(name):
			var d: Dictionary = all_heroes[name].duplicate(true)
			# ← добавляем моды статов от аугментов
			d = aug_apply_to_stats(name, d)

			d["nick"] = d.get("nick", name)
			d["team"] = "hero"
			d["hp"] = d.get("max_hp", d.get("max_health", 100))
			d["mana"] = d.get("max_mana", 0)
			d["stamina"] = d.get("max_stamina", 0)
			out.append(d)
	return out
	
func load_augments_db(path: String = AUGMENTS_JSON) -> void:
	augments_db.clear()
	var txt := ""
	if FileAccess.file_exists(path):
		txt = FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var root: Dictionary = parsed
	var d: Dictionary = root.get("augments", {})
	if typeof(d) == TYPE_DICTIONARY:
		augments_db = d.duplicate(true)

func _init_ether_caps() -> void:
	for n in party_names:
		if not hero_ether_cap.has(n):
			hero_ether_cap[n] = 10
		if not hero_augs.has(n):
			hero_augs[n] = []

func get_augment_def(id: String) -> Dictionary:
	return augments_db.get(id, {})

func augment_title(id: String) -> String:
	var d := get_augment_def(id)
	return String(d.get("name", id))

func augment_cost(id: String) -> int:
	var d := get_augment_def(id)
	return int(d.get("cost", 0))

func unlock_augment(id: String) -> void:
	if not augments_db.has(id):
		return
	if not unlocked_augments.has(id):
		unlocked_augments.append(id)
	emit_signal("augments_changed")

func get_unlocked_augments() -> Array:
	var arr := unlocked_augments.duplicate()
	arr.sort_custom(func(a, b): return augment_title(String(a)) < augment_title(String(b)))
	return arr

func get_hero_ether_cap(hero: String) -> int:
	return int(hero_ether_cap.get(hero, 10))

func set_hero_ether_cap(hero: String, v: int) -> void:
	hero_ether_cap[hero] = max(0, int(v))
	emit_signal("augments_changed")

func get_hero_active_augments(hero: String) -> Array:
	if not hero_augs.has(hero): return []
	return (hero_augs[hero] as Array).duplicate()

func hero_augment_is_active(hero: String, id: String) -> bool:
	return get_hero_active_augments(hero).has(id)

func hero_ether_used(hero: String) -> int:
	var used := 0
	for id in get_hero_active_augments(hero):
		used += augment_cost(String(id))
	return used

func hero_ether_left(hero: String) -> int:
	return max(0, get_hero_ether_cap(hero) - hero_ether_used(hero))

# попытка включить/выключить аугмент
func set_hero_augment(hero: String, id: String, on: bool) -> bool:
	if hero == "" or id == "": return false
	if not unlocked_augments.has(id): return false
	var list: Array = get_hero_active_augments(hero)
	if on:
		if list.has(id): return true
		var cost := augment_cost(id)
		if hero_ether_used(hero) + cost > get_hero_ether_cap(hero):
			return false
		list.append(id)
	else:
		list.erase(id)
	hero_augs[hero] = list
	emit_signal("augments_changed")
	return true

# Эфирия
func get_etheria() -> int:
	return etheria

func add_etheria(n: int) -> void:
	if n <= 0: return
	etheria += n
	emit_signal("augments_changed")

func spend_etheria_to_increase_cap(hero: String) -> bool:
	if etheria <= 0: return false
	etheria -= 1
	var cap := get_hero_ether_cap(hero)
	set_hero_ether_cap(hero, cap + 1)  # сам эмитит сигнал
	return true
