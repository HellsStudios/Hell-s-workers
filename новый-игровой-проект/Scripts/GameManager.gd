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
var next_inst_id: int = 1
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
const DIALOGS_JSON := "res://Data/dialogs.json"

var dialogs_db: Dictionary = {}
var _dialog_scene := preload("res://Scenes/DialogPlayer.tscn")
var _dialog_open := false

signal dialog_started(id: String)
signal dialog_finished(id: String, result: Dictionary)

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

var timeline_clock := { "slot": 0, "running": false, "slot_sec": 0.7 }

signal task_pool_changed
signal schedule_changed
signal task_event(hero: String, inst_id: int, event_def: Dictionary)
signal task_started(hero: String, inst_id: int)
signal task_completed(hero: String, inst_id: int, outcome: Dictionary)

signal task_finished(hero: String, inst_id: int, success: bool, rewards: Dictionary)

var day_summary := {"krestli":0, "etheria":0, "items":[], "supplies":[]}

var DEBUG_TASKS: bool = true

# --- Scene routing / stack ---
var timeline_ref: Node = null
var battle_ref: Node = null
var _return_scene_path := ""                  # куда вернуться после боя
const TIMELINE_SCENE := "res://scenes/timeline.tscn"  # свой путь
const BATTLE_SCENE   := "res://scenes/battle.tscn"    # свой путь

var _battle_payload: Dictionary = {}          # {party:Array, enemies:Array}

# --- DIALOGS ----

# что уже проигрывали (чтобы «впервые в особняке» не повторялось)
var seen_dialogs: Dictionary = {}   # id -> true
var story_flags: Dictionary = {}    # любые флажки сюжета здесь


# В шапку:
const DIALOG_SCENE := "res://scenes/DialogPlayer.tscn"

var _seen_dialogs := {}

func dialog_seen(id: String) -> bool:
	return bool(_seen_dialogs.get(id, false))

func _mark_dialog_seen(id: String) -> void:
	_seen_dialogs[id] = true

func play_dialog(dlg_id: String, parent: Node = null) -> void:
	var scene := load("res://scenes/DialogPlayer.tscn")  # твой путь
	if scene == null:
		push_warning("[Dialog] scene not found"); return

	var layer := CanvasLayer.new()
	layer.layer = 100   # поверх всего UI
	var dlg = scene.instantiate()
	layer.add_child(dlg)

	# в корень вьюпорта — чтобы никакие контейнеры мэншина не ломали якоря
	get_tree().root.add_child.call_deferred(layer)

	# пауза игры (сохраняем предыдущее состояние)
	var was_paused := get_tree().paused
	get_tree().paused = true

	# диалог должен работать в паузе
	dlg.process_mode = Node.PROCESS_MODE_ALWAYS

	# старт после входа в дерево
	dlg.call_deferred("play_by_id", dlg_id)

	# завершение
	dlg.dialog_finished.connect(func(result: Dictionary):
		get_tree().paused = was_paused
		layer.queue_free()
		if has_signal("dialog_finished"):
			emit_signal("dialog_finished", dlg_id, result)
	)



func load_dialogs_db(path: String = DIALOGS_JSON) -> void:
	if dialogs_db.is_empty() and FileAccess.file_exists(path):
		var txt := FileAccess.get_file_as_string(path)
		var parsed = JSON.parse_string(txt)
		if typeof(parsed) == TYPE_DICTIONARY:
			dialogs_db = parsed

func mark_dialog_seen(id: String) -> void:
	seen_dialogs[id] = true


# единая точка применения «последствий» из result
func _apply_dialog_result(id: String, result: Dictionary) -> void:
	# 1) флаги
	for f in Array(result.get("set_flags", [])):
		story_flags[String(f)] = true

	# 2) выдать/обновить квест
	if result.has("give_quest"):
		var qid := String(result["give_quest"])
		# если квест есть в БД — включим его и создадим карточку в журнале
		set_quest_available(qid, true)
		add_or_update_quest(qid, String(quests_all.get(qid, {}).get("name", qid)), String(quests_all.get(qid, {}).get("desc","")))

	# 3) заспавнить задачу в пул
	if result.has("spawn_task_def"):
		var def_id := String(result["spawn_task_def"])
		spawn_task_instance(def_id, {"kind":"quest"})

	# 4) старт боя (если диалог так решил)
	if result.has("battle"):
		var b: Dictionary = result["battle"]
		var eids: Array = b.get("enemies", [])
		var exit_scene := String(b.get("exit_scene", "res://scenes/timeline.tscn"))
		push_battle(eids)  # используй свою реализацию

	# 5) переход сцены (опционально)
	if result.has("goto_scene"):
		var path := String(result["goto_scene"])
		if path != "":
			get_tree().change_scene_to_file(path)



func _on_dialog_finished(id: String, result: Dictionary) -> void:
	if id == "mansion_intro":
		# пример: открыть меню, показать туториал и т.п.
		if bool(result.get("open_board", false)):
			$QuestBoard.open()

func make_party_hero_defs() -> Array:
	return make_party_dicts()

func register_timeline(node: Node) -> void:
	timeline_ref = node

func goto_mansion() -> void:
	timeline_ref = null
	get_tree().change_scene_to_file("res://scenes/mansion.tscn")

func goto_timeline() -> void:
	get_tree().change_scene_to_file("res://scenes/timeline.tscn")

func _suspend_timeline() -> void:
	if timeline_ref != null:
		if timeline_ref.has_method("_pause"):
			timeline_ref.call("_pause")
		timeline_ref.set_process(false)
		if "visible" in timeline_ref:
			timeline_ref.visible = false

func _resume_timeline() -> void:
	if timeline_ref != null:
		if "visible" in timeline_ref:
			timeline_ref.visible = true
		timeline_ref.set_process(true)
		if timeline_ref.has_method("_start"):
			timeline_ref.call("_start")

# enemies: ["id","id2"], heroes: ["Berit","Sally"] (необязательно)
func push_battle(enemies: Array) -> void:
	# сохраняем «куда возвращаться» и состояние таймлайна
	var cs = get_tree().current_scene
	_return_scene_path = cs.scene_file_path if cs and cs.scene_file_path != "" else TIMELINE_SCENE

	# стопаем бег таймлайна, но НЕ сбрасываем slot
	timeline_clock["running"] = false

	_battle_payload = {
		"party": make_party_dicts(),  # твой уже готовый хелпер
		"enemies": enemies.duplicate()
	}
	get_tree().change_scene_to_file(BATTLE_SCENE)

func get_battle_payload() -> Dictionary:
	return _battle_payload.duplicate(true)

func end_battle(victory: bool, participants: Array = []) -> void:
	# если поражение — участникам: hp=1, stamina=0
	if not victory:
		var who: Array = participants.duplicate()
		if who.is_empty():
			# на крайний случай — вся пати
			who = party_names.duplicate()
		for name in who:
			set_res_cur(String(name), "hp", 1)
			set_res_cur(String(name), "stamina", 0)

	_battle_payload.clear()
	var back := _return_scene_path if _return_scene_path != "" else TIMELINE_SCENE
	_return_scene_path = ""
	get_tree().change_scene_to_file(back)

func _tlog(msg: String, ctx: Dictionary = {}) -> void:
	if DEBUG_TASKS:
		print("[TASK] ", msg, " | ", ctx)


func _recalc_next_inst_id() -> void:
	var mx := 0
	# из пула
	for inst in active_task_pool:
		if typeof(inst) == TYPE_DICTIONARY and inst.has("inst_id"):
			mx = maxi(mx, int(inst["inst_id"]))
	# из расписания
	for hero in scheduled.keys():
		for rec in scheduled.get(hero, []):
			if typeof(rec) == TYPE_DICTIONARY and rec.has("inst_id"):
				mx = maxi(mx, int(rec["inst_id"]))
	next_inst_id = mx + 1

func _alloc_inst_id() -> int:
	var id := next_inst_id
	next_inst_id += 1
	return id

func finish_task(hero: String, inst_id: int, success: bool) -> Dictionary:
	
	# найдём запись в расписании (чтобы вытащить def_id/kind/quest_id/overrides)
	var arr: Array = scheduled.get(hero, [])
	var rec: Dictionary = {}
	var rec_idx := -1
	for i in range(arr.size()):
		var r = arr[i]
		if int(r.get("inst_id", 0)) == inst_id:
			rec = r
			rec_idx = i
			break
	if rec.is_empty():
		return {}

	var def_id := String(rec.get("def_id",""))
	var def: Dictionary = task_defs.get(def_id, {})
	var rewards: Dictionary = {}
	if success:
		rewards = def.get("rewards", {})

	# дневной итог
	day_summary.krestli += int(rewards.get("krestli",0))
	day_summary.etheria += int(rewards.get("etheria",0))
	if rewards.has("items"):
		day_summary.items += rewards.items
	if rewards.has("supplies"):
		day_summary.supplies += rewards.supplies

	# 1) УБИРАЕМ со строки БЕЗ возврата в пул по умолчанию
	unschedule_task(hero, inst_id, false)  # <— ВАЖНО: return_to_pool = false
	_toast_task_result(hero, def_id, success, rewards)
	# 2) Если это квестовая и провалена — возвращаем в пул НОВЫЙ инстанс
	var kind := String(rec.get("kind","daily"))
	if not success and kind == "quest":
		var new_inst_id := _alloc_inst_id()
		var qid := String(rec.get("quest_id",""))
		var inst := {
			"def_id": def_id,
			"inst_id": new_inst_id,
			"kind": "quest",
			"quest_id": qid
		}
		# если хочешь тащить кастомный title/color/events_override из rec — раскомментируй:
		# if rec.has("title"):           inst["title"] = rec["title"]
		# if rec.has("color"):           inst["color"] = rec["color"]
		# if rec.has("events_override"): inst["events_override"] = rec["events_override"]
		
		active_task_pool.append(inst)
		emit_signal("task_pool_changed")

	emit_signal("task_finished", hero, inst_id, success, rewards)
	emit_signal("schedule_changed")

	# чейнинг followup (как было у тебя)
	var next_def := String(def.get("next_def",""))
	if next_def != "":
		spawn_task_instance(next_def, {"kind":"quest"})
		emit_signal("task_pool_changed")
	_tlog("finish_task ENTER", {"hero": hero, "inst": inst_id, "success": success})

	# после подсчёта rewards:
	_tlog("finish_task rewards", {"hero": hero, "inst": inst_id, "rewards": rewards})

	# сразу после unschedule_task(...)
	_tlog("finish_task unscheduled", {"hero": hero, "inst": inst_id})

	# перед followup (если есть):
	if next_def != "":
		_tlog("finish_task followup spawn", {"inst": inst_id, "next_def": next_def})
	var mark_q := String(def.get("quest_complete",""))
	if mark_q != "":
		set_quest_completed(mark_q, true)
	return rewards

func claim_completed_quest_rewards() -> Array:
	var claimed: Array = []
	for id in quests_all.keys():
		var q: Dictionary = quests_all[id]
		if bool(q.get("completed", false)) and not bool(q.get("_reward_claimed", false)):
			award_rewards(q.get("rewards", {}))
			quests_all[id]["_reward_claimed"] = true
			claimed.append(String(id))
	return claimed
	
var spawned_quests_today := {}  # { quest_id: true/false }

func reset_day_flags() -> void:
	spawned_quests_today.clear()

func get_day_summary() -> Dictionary:
	return day_summary

func reset_day_summary() -> void:
	day_summary = {"krestli":0, "etheria":0, "items":[], "supplies":[]}

# Упрощённый хелпер, если нет — сделай тонкую обёртку над твоим спавном
func spawn_task_instance(def_id: String, extra: Dictionary = {}) -> void:
	var inst := {
		"def_id": def_id,
		"inst_id": _alloc_inst_id(),
		"kind": String(extra.get("kind","daily")),
		"quest_id": String(extra.get("quest_id",""))
	}
	active_task_pool.append(inst)
	emit_signal("task_pool_changed")

# GameManager.gd
func _find_quest(quest_id: String) -> Dictionary:
	# основное хранилище
	if typeof(quests_all) == TYPE_DICTIONARY and quests_all.has(quest_id):
		return (quests_all[quest_id] as Dictionary).duplicate(true)

	# запасной вариант: вдруг где-то остался Array "quests"
	var arr = get("quests")
	if typeof(arr) == TYPE_ARRAY:
		for it in arr:
			if typeof(it) == TYPE_DICTIONARY and String(it.get("id","")) == quest_id:
				return (it as Dictionary).duplicate(true)
	return {}

func _resolve_event_option(hero: String, inst_id: int, ev_def: Dictionary, opt: Dictionary) -> void:
	var ok := true
	
	# проверка квалификации
	var need: Dictionary = opt.get("qual_need", {})
	if typeof(need) == TYPE_DICTIONARY:
		for q in need.keys():
			if get_qual_level(hero, String(q)) < int(need[q]):
				ok = false
				break

	# риск (чем выше risk, тем больше шанс провала)
	var risk := int(opt.get("risk", 0))
	if risk > 0 and randi_range(1, 100) <= risk:
		ok = false

	var pack: Dictionary = {}
	if ok:
		pack = opt.get("on_success", {})
	else:
		pack = opt.get("on_fail", {})
		
	
	if pack.has("dialog"):
		# стопим таймеры/анимации только фактом паузы дерева — остальную логику не трогаем
		play_dialog(String(pack["dialog"]))
		# дальше продолжаем обычную обработку (награды/эффекты) — диалог идёт параллельно в паузе
		
	if pack.has("battle"):
		var bdef: Dictionary = pack["battle"]
		var eids: Array = bdef.get("enemies", [])
		push_battle(eids)
		return

	# применяем выхлоп (деньги/эфирия/опыт/итемы/припасы/кондинции)
	if pack.has("krestli"):  krestli += int(pack["krestli"])
	if pack.has("etheria"):  add_etheria(int(pack["etheria"]))

	if pack.has("qual_xp"):
		var qxp: Dictionary = pack["qual_xp"]
		for q in qxp.keys():
			add_qual_xp(hero, String(q), int(qxp[q]))

	if pack.has("items"):
		for e in (pack["items"] as Array):
			if typeof(e) == TYPE_DICTIONARY:
				add_to_base(String(e.get("id","")), int(e.get("count", 0)))

	if pack.has("supplies"):
		for e in (pack["supplies"] as Array):
			if typeof(e) == TYPE_DICTIONARY:
				supplies_add(String(e.get("id","")), int(e.get("count", 0)))

	if pack.has("cond_add"):
		for cid in (pack["cond_add"] as Array):
			add_condition(hero, String(cid), 0, 2)

	# опционально тост
	var txt := "Провал"
	if ok:
		txt = "Успех"
	Toasts.warn("Событие: %s — %s." % [String(ev_def.get("id","")), txt])


func spawn_quest_tasks(quest_id: String) -> void:
	var q := _find_quest(quest_id)
	if q.is_empty():
		print_debug("[QUEST] not found: ", quest_id)
		return

	if spawned_quests_today.get(quest_id, false):
		return
	spawned_quests_today[quest_id] = true

	for t in q.get("tasks", []):
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var def_id := String(t.get("def", ""))
		var count := int(t.get("count", 1))
		var unique := bool(t.get("unique", true))

		# не дублируем уже существующий в пуле квестовый инстанс того же def_id
		if unique:
			var already := false
			for inst in active_task_pool:
				if typeof(inst) == TYPE_DICTIONARY \
				and String(inst.get("def_id","")) == def_id \
				and String(inst.get("kind","")) == "quest":
					already = true; break
			if already:
				continue

		# оверрайды из tasks[]:
		var override := {}
		if t.has("title"):  override["title"]  = String(t["title"])
		if t.has("color"):  override["color"]  = String(t["color"])
		if t.has("events"): override["events_override"] = t["events"]

		# если title не задан — используем имя квеста, чтобы отличался от daily
		if not override.has("title"):
			override["title"] = String(q.get("name", def_id))
		# если цвет не задан — сделаем квестовую карточку синей
		if not override.has("color"):
			override["color"] = "#3b82f6"

		for i in range(count):
			_add_task_instance(def_id, "quest", quest_id, override)

	if has_signal("task_pool_changed"):
		task_pool_changed.emit()


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
			_add_task_instance(def_id, "daily", "", {})  # ← ВАЖНО: kind="daily"
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


func _add_task_instance(def_id: String, kind: String, quest_id: String, override: Dictionary = {}) -> void:
	if not task_defs.has(def_id):
		return
	var inst := {
		"inst_id": _alloc_inst_id(),
		"def_id": def_id,
		"kind":   kind,     # ← канонично
		"source": kind,     # ← для совместимости со старым кодом
		"quest_id": quest_id
	}
	for k in override.keys():
		inst[k] = override[k]  # title, color, events_override ...
	active_task_pool.append(inst)


func can_schedule(hero: String, inst_id: int, start_slot: int) -> bool:
	var def_id := _inst_def(inst_id)
	if def_id == "":
		return false

	var now := int(timeline_clock.get("slot", 0))
	if start_slot < now:
		return false

	var dur := int(task_defs[def_id].get("duration_slots", 4))
	for s in scheduled.get(hero, []):
		var a := int(s["start"])
		var b := a + int(s["duration"])
		var c := start_slot
		var d := c + dur
		if c < b and d > a:
			return false
	return true

func _toast_task_result(hero: String, def_id: String, success: bool, rewards: Dictionary) -> void:
	var title := def_id
	if task_defs.has(def_id):
		title = String(task_defs[def_id].get("title", def_id))

	var res_txt := "провал"
	if success:
		res_txt = "успех"

	var parts: Array = []

	var k := int(rewards.get("krestli", 0))
	if k > 0:
		parts.append("+%d кр." % k)

	var eth := int(rewards.get("etheria", 0))
	if eth > 0:
		parts.append("+%d эф." % eth)

	if rewards.has("items"):
		for e in rewards["items"]:
			if typeof(e) == TYPE_DICTIONARY:
				var iid := String(e.get("id",""))
				var cnt := int(e.get("count",0))
				if iid != "" and cnt > 0:
					parts.append("%s×%d" % [item_title(iid), cnt])

	if rewards.has("supplies"):
		for e in rewards["supplies"]:
			if typeof(e) == TYPE_DICTIONARY:
				var sid := String(e.get("id",""))
				var cnt := int(e.get("count",0))
				if sid != "" and cnt > 0:
					parts.append("%s×%d" % [supply_title(sid), cnt])

	var suffix := ""
	if parts.size() > 0:
		suffix = " (" + ", ".join(parts) + ")"

	var msg := "%s: %s%s" % [title, res_txt, suffix]

	# Автозагрузка Toasts (как узел /root/Toasts)
	var t := get_node_or_null("/root/Toasts")
	if t == null:
		print(msg)
		return

	if success:
		if t.has_method("ok"):
			t.call("ok", msg)
		elif t.has_method("info"):
			t.call("info", msg)
		elif t.has_method("show_text"):
			t.call("show_text", msg)
		else:
			print(msg)
	else:
		if t.has_method("warn"):
			t.call("warn", msg)
		elif t.has_method("info"):
			t.call("info", msg)
		elif t.has_method("show_text"):
			t.call("show_text", msg)
		else:
			print(msg)

func _on_task_finished(hero: String, inst_id: int, success: bool, rewards: Dictionary) -> void:
	var state := "неудачно"
	if success:
		state = "успешно"
	var msg := "%s: задача завершена %s." % [hero, state]

	var k := int(rewards.get("krestli", 0))
	if k > 0:
		msg += " +%d кр." % k
	var eth := int(rewards.get("etheria", 0))
	if eth > 0:
		msg += " +%d эф." % eth
	if rewards.has("items"):
		var parts: Array = []
		for e in rewards["items"]:
			if typeof(e) == TYPE_DICTIONARY:
				var id := String(e.get("id",""))
				var cnt := int(e.get("count",0))
				if id != "" and cnt > 0:
					parts.append("%s×%d" % [GameManager.item_title(id), cnt])
		if parts.size() > 0:
			msg += " (" + ", ".join(parts) + ")"

	Toasts.warn(msg)

func schedule_task(hero: String, inst_id: int, start_slot: int) -> bool:
	# запрет задним числом — если уже добавлял, оставь
	var now := int(timeline_clock.get("slot", 0))
	if start_slot < now:
		return false

	if not can_schedule(hero, inst_id, start_slot):
		return false

	var def_id := _inst_def(inst_id)
	if def_id == "":
		return false
	var dur := int(task_defs[def_id].get("duration_slots", 4))

	# достаём инстанс из пула
	var inst_data := {}
	for i in range(active_task_pool.size()):
		var it = active_task_pool[i]
		if int(it.get("inst_id", -1)) == inst_id:
			inst_data = it
			active_task_pool.remove_at(i)
			break

	var rec := {"inst_id":inst_id, "def_id":def_id, "start":start_slot, "duration":dur, "progress":0}

	# тянем ВСЕ важные поля в расписание
	if inst_data.has("title"):           rec["title"] = inst_data["title"]
	if inst_data.has("color"):           rec["color"] = inst_data["color"]
	if inst_data.has("events_override"): rec["events_override"] = inst_data["events_override"]
	if inst_data.has("kind"):            rec["kind"] = String(inst_data["kind"])          # <— НОВОЕ
	if inst_data.has("quest_id"):        rec["quest_id"] = String(inst_data["quest_id"])  # <— НОВОЕ

	var arr = scheduled.get(hero, [])
	arr.append(rec)
	scheduled[hero] = arr

	emit_signal("task_pool_changed")
	emit_signal("schedule_changed")
	_tlog("schedule_task OK", {"hero": hero, "inst": inst_id, "start": start_slot, "dur": dur})
	return true


func unschedule_task(hero: String, inst_id: int, return_to_pool: bool = true) -> void:
	var arr = scheduled.get(hero, [])
	for i in range(arr.size()):
		var rec = arr[i]
		if int(rec["inst_id"]) == inst_id:
			if return_to_pool:
				var back_kind := String(rec.get("kind","daily"))
				var back_qid  := String(rec.get("quest_id",""))
				active_task_pool.append({
					"inst_id": inst_id,
					"def_id": String(rec["def_id"]),
					"kind": back_kind,
					"quest_id": back_qid
				})
				_tlog("unschedule_task", {
					"hero": hero,
					"inst": inst_id,
					"def_id": String(rec.get("def_id","")),
					"kind": String(rec.get("kind","")),
					"quest_id": String(rec.get("quest_id",""))
				})
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
	_tlog("tick", {"slot": slot})

	for hero in party_names:
		var arr: Array = scheduled.get(hero, [])
		_tlog("scan hero", {"hero": hero, "count": arr.size()})

		for s in arr:
			if typeof(s) != TYPE_DICTIONARY:
				continue

			var inst_id := int(s.get("inst_id", 0))
			var def_id  := String(s.get("def_id", ""))
			var st      := int(s.get("start", 0))
			var dur     := int(s.get("duration", 1))
			var en      := st + dur

			_tlog("row", {"hero": hero, "inst": inst_id, "def": def_id, "st": st, "en": en, "now": slot})

			# Уже завершали — пропускаем.
			if bool(s.get("_done", false)):
				_tlog("skip already done", {"inst": inst_id})
				continue

			# Старт
			if slot == st:
				_tlog("EMIT task_started", {"hero": hero, "inst": inst_id})
				emit_signal("task_started", hero, inst_id)

			# Эвенты: ТОЛЬКО ДО окончания (строго slot < en)
			var def: Dictionary = task_defs.get(def_id, {})
			var evs: Array = s.get("events_override", def.get("events", []))

			if slot < en:
				for ev in evs:
					if typeof(ev) != TYPE_DICTIONARY:
						continue
					var rel := int(ev.get("at_rel_slot", -999))
					var at_abs := st + rel
					if slot == at_abs:
						var fired_abs: Dictionary = s.get("_fired_abs", {})
						var key := str(at_abs)
						if not bool(fired_abs.get(key, false)):
							fired_abs[key] = true
							s["_fired_abs"] = fired_abs
							_tlog("EMIT task_event", {
								"hero": hero, "inst": inst_id, "at_abs": at_abs, "rel": rel,
								"text": String(ev.get("text",""))
							})
							emit_signal("task_event", hero, inst_id, ev)

			# Завершение (и только один раз)
			if slot >= en and not bool(s.get("_completed_emitted", false)):
				s["_completed_emitted"] = true
				s["_done"] = true
				_tlog("COMPLETE -> _complete_task", {"hero": hero, "inst": inst_id})
				_complete_task(hero, s)

	# (если у тебя внизу была очистка – оставь как было)


func _complete_task(hero: String, s: Dictionary) -> void:
	if s.is_empty():
		return

	s["_done"] = true  # больше ни стартов, ни евентов

	var def_id := String(s.get("def_id",""))
	var def: Dictionary = task_defs.get(def_id, {})
	var outcome := _evaluate_outcome(hero, def)

	_apply_costs_and_rewards(hero, def, outcome)
	emit_signal("task_completed", hero, int(s.get("inst_id", 0)), outcome)

	# финалим и убираем с линии (квесты/дейлики — по твоей логике в finish_task)
	finish_task(hero, int(s.get("inst_id", 0)), bool(outcome.get("success", true)))

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
	load_dialogs_db(DIALOGS_JSON)
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
	_recalc_next_inst_id()
	spawn_quest_tasks("q_intro")
	spawn_daily_tasks("default")
	print("[QTEST] quests_all keys: ", quests_all.keys())
	
func _init_mood_defaults() -> void:
	for n in party_names:
		if not hero_mood.has(n):
			hero_mood[n] = 50

func unschedule_any(inst_id: int) -> bool:
	if inst_id <= 0:
		return false
	for h in party_names:
		var arr: Array = scheduled.get(h, [])
		for s in arr:
			if typeof(s) == TYPE_DICTIONARY and int(s.get("inst_id", 0)) == inst_id:
				unschedule_task(h, inst_id)  # уже эмитит schedule_changed / task_pool_changed
				return true
	return false


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
