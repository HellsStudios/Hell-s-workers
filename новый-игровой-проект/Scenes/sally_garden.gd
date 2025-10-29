extends Control

# === Константы геймплея ===
const MAX_POT_ACTIONS_PER_DAY := 2
const MAX_LECTURE_PER_DAY := 1
const MAX_BOOST_PER_DAY := 1

# === Узлы ===
@onready var exit_btn       : Button          = $Root/HBox/Left/TopBar/ExitBtn
@onready var pots_grid      : GridContainer   = $Root/HBox/Left/PotsScroll/PostGrid
@onready var day_log        : RichTextLabel   = $Root/HBox/Left/DayLog

@onready var sel_label      : Label           = $Root/HBox/Right/SelLabel
@onready var plant_btn      : MenuButton      = $Root/HBox/Right/ActionsPanel/VBoxContainer/PlantBtn
@onready var water_btn      : MenuButton      = $Root/HBox/Right/ActionsPanel/VBoxContainer/WaterBtn
@onready var fert_btn       : MenuButton      = $Root/HBox/Right/ActionsPanel/VBoxContainer/FertBtn
@onready var weed_btn       : Button          = $Root/HBox/Right/ActionsPanel/VBoxContainer/WeedBtn
@onready var therapy_btn    : MenuButton      = $Root/HBox/Right/ActionsPanel/VBoxContainer/TherapyBtn
@onready var harvest_btn    : Button          = $Root/HBox/Right/ActionsPanel/VBoxContainer/HarvestBtn
@onready var remove_btn     : Button          = $Root/HBox/Right/ActionsPanel/VBoxContainer/RemoveBtn

@onready var day_limits_lbl : Label           = $Root/HBox/Right/DayLimits
@onready var lecture_btn    : MenuButton      = $Root/HBox/Right/GlobalPanel/VBoxContainer/LectureBtn
@onready var boost_btn      : MenuButton      = $Root/HBox/Right/GlobalPanel/VBoxContainer/BoostBtn
# КНОПКИ ЛОКАЛЬНОЙ СМЕНЫ ДНЯ БОЛЬШЕ НЕТ

# === Дневные лимиты (персистентно через GameManager) ===
var _daily := { "day": -1, "actions": {}, "lecture": 0, "boost": 0 }

func _load_daily() -> void:
	var st := {}
	if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("get_meta"):
		st = GameManager.get_meta("sally_garden_daily", {})
	_daily["day"]     = int(st.get("day", -1))
	_daily["actions"] = st.get("actions", {})
	_daily["lecture"] = int(st.get("lecture", 0))
	_daily["boost"]   = int(st.get("boost", 0))
	# если открыли сцену в новый день — обнуляем лимиты именно на СЕГОДНЯ
	if typeof(GameManager) == TYPE_OBJECT and _daily["day"] != int(GameManager.day):
		_daily["day"] = int(GameManager.day)
		_daily["actions"] = {}
		_daily["lecture"] = 0
		_daily["boost"] = 0

func _save_daily() -> void:
	if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("set_meta"):
		GameManager.set_meta("sally_garden_daily", {
			"day": _daily["day"],
			"actions": _daily["actions"],
			"lecture": _daily["lecture"],
			"boost": _daily["boost"],
		})

# === Данные ===
var DATA := {}
var CROPS := {}
var FERTS := {}
var TOPICS := {}

# Состояние сада (сохраняемо)
var pots : Array = []
var day_actions_used : Dictionary = {}
var lecture_used_today := 0
var boost_used_today := 0

# Выбор
var selected_idx := -1

const PotCard := preload("res://Scripts/PotCard.gd")

func _ready() -> void:
	_load_data()
	_restore_state_or_init()
	_load_daily()
	exit_btn.pressed.connect(_goto_mansion)
	weed_btn.pressed.connect(func(): _act_weed())
	harvest_btn.pressed.connect(func(): _act_harvest())
	remove_btn.pressed.connect(func(): _act_remove())

	_build_pots_ui()
	_build_menus()
	_update_ui()

func _goto_mansion() -> void:
	if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("goto_mansion"):
		GameManager.goto_mansion()
	else:
		get_tree().change_scene_to_file("res://Scenes/mansion.tscn")

# === DATA ===
func _load_data() -> void:
	var path := "res://Data/garden_data.json"
	if not FileAccess.file_exists(path):
		push_warning("[Garden] missing data json: " + path)
		return
	var txt := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[Garden] bad data json")
		return
	DATA = parsed
	for d in DATA.get("crops", []):
		CROPS[d["id"]] = d
	for d in DATA.get("fertilizers", []):
		FERTS[d["id"]] = d
	for d in DATA.get("topics", []):
		TOPICS[d["id"]] = d

# === SAVE/LOAD ===
func _restore_state_or_init() -> void:
	var saved := {}
	if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("get_meta"):
		saved = GameManager.get_meta("sally_garden_state", {})
	if typeof(saved) == TYPE_DICTIONARY and saved.has("pots"):
		pots = saved["pots"]
	else:
		var n := int(DATA.get("pots_default", 6))
		pots.clear()
		for i in n:
			pots.append(_new_empty_pot())
	_save_state()

func _save_state() -> void:
	var state := {"pots": pots}
	if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("set_meta"):
		GameManager.set_meta("sally_garden_state", state)

func _new_empty_pot() -> Dictionary:
	return {
		"crop_id":"", "title":"(пусто)", "day":0,
		"mature_in": 0,
		"water":50, "nutrients":50, "stress":0, "health":100,
		"weeds":0,
		"last_fert_day": -999,
		"last_fert_type": "",
		"tags": [],
		"harvest_ready": false
	}

# === UI BUILD ===
func _build_pots_ui() -> void:
	for c in pots_grid.get_children():
		c.queue_free()
	pots_grid.columns = 3

	for i in range(pots.size()):
		var p = pots[i]
		var sub := "Пусто"
		if p.crop_id != "":
			var cdef = CROPS.get(p.crop_id, {})
			sub = String(cdef.get("title",""))
		var subtitle := ""
		if p.harvest_ready:
			subtitle = "Готов к сбору"
		else:
			if p.crop_id != "":
				subtitle = "Дней: %d/%d" % [p.day, p.mature_in]

		var card := PotCard.new()
		card.setup(i, {
			"title": sub,
			"subtitle": subtitle,
			"health": p.health, "stress": p.stress, "water": p.water, "nutrients": p.nutrients,
			"empty": (p.crop_id == ""), "harvest_ready": p.harvest_ready
		})
		card.clicked.connect(_on_pot_clicked)
		pots_grid.add_child(card)

func _on_pot_clicked(idx:int) -> void:
	selected_idx = idx
	_update_ui()

func _build_menus() -> void:
	# посев
	var pm := plant_btn.get_popup()
	pm.clear()
	for cid in CROPS.keys():
		pm.add_item(CROPS[cid]["title"])
	pm.id_pressed.connect(func(id):
		var keys := CROPS.keys()
		var cid = keys[id]
		_act_plant(cid)
	)

	# полив
	var wm := water_btn.get_popup()
	wm.clear()
	wm.add_item("Норма")
	wm.add_item("Мало")
	wm.add_item("Много")
	wm.id_pressed.connect(func(id):
		var mode := ""
		if id == 0:
			mode = "normal"
		elif id == 1:
			mode = "low"
		else:
			mode = "high"
		_act_water(mode)
	)

	# удобрение
	var fm := fert_btn.get_popup()
	fm.clear()
	for fid in FERTS.keys():
		fm.add_item(FERTS[fid]["title"])
	fm.id_pressed.connect(func(id):
		var keys := FERTS.keys()
		var fid = keys[id]
		_act_fertilize(fid)
	)

	# терапия
	var tm := therapy_btn.get_popup()
	tm.clear()
	for tid in TOPICS.keys():
		tm.add_item(TOPICS[tid]["title"])
	tm.id_pressed.connect(func(id):
		var keys := TOPICS.keys()
		var tid = keys[id]
		_act_therapy(tid)
	)

	# лекция (глобальная)
	var lm := lecture_btn.get_popup()
	lm.clear()
	for tid in TOPICS.keys():
		lm.add_item("Лекция: " + TOPICS[tid]["title"])
	lm.id_pressed.connect(func(id):
		var keys := TOPICS.keys()
		var tid = keys[id]
		_act_lecture(tid)
	)

	# буст дня
	var bm := boost_btn.get_popup()
	bm.clear()
	for fid in FERTS.keys():
		bm.add_item("Бесплатно: " + FERTS[fid]["title"])
	bm.id_pressed.connect(func(id):
		var keys := FERTS.keys()
		var fid = keys[id]
		_act_boost(fid)
	)

# === HELPERS ===
func _sel_pot() -> Dictionary:
	if selected_idx >= 0 and selected_idx < pots.size():
		return pots[selected_idx]
	return {}

func _can_use_action_on_pot() -> bool:
	if selected_idx < 0:
		return false
	var used := int(_daily["actions"].get(selected_idx, 0))
	return used < MAX_POT_ACTIONS_PER_DAY

func _spend_pot_action() -> void:
	var v := int(_daily["actions"].get(selected_idx, 0)) + 1
	_daily["actions"][selected_idx] = v
	_save_daily()

func _roll_mature_days(cdef:Dictionary) -> int:
	var arr = cdef.get("mature_days",[5,5])
	var a := int(arr[0])
	var b := int(arr[1])
	if a > b:
		var t := a; a = b; b = t
	return randi_range(a, b)

func _log(msg:String) -> void:
	day_log.append_text(msg + "\n")

func _update_ui() -> void:
	var name := "-"
	var p := _sel_pot()
	if not p.is_empty():
		if String(p.get("crop_id","")) != "":
			var cdef = CROPS[p.crop_id]
			name = "%s (%d/%d)" % [cdef["title"], p.day, p.mature_in]
		else:
			name = "(пусто)"
	sel_label.text = "Выбрано: %s" % name

	var has_sel := (selected_idx >= 0)
	var empty := false
	if has_sel:
		empty = (String(_sel_pot().get("crop_id","")) == "")
	var can_act := (has_sel and _can_use_action_on_pot())

	plant_btn.disabled = not (has_sel and empty)
	water_btn.disabled = not (has_sel and (not empty) and can_act)
	fert_btn.disabled  = not (has_sel and (not empty) and can_act)
	weed_btn.disabled  = not (has_sel and (not empty) and can_act)
	therapy_btn.disabled = not (has_sel and (not empty) and can_act)

	var can_harvest := false
	if has_sel and (not empty):
		can_harvest = bool(p.get("harvest_ready", false))
	harvest_btn.disabled = not can_harvest

	remove_btn.disabled = not has_sel

	var used := int(_daily["actions"].get(selected_idx, 0))
	day_limits_lbl.text = "Действия на горшок сегодня: %d / %d | Лекция: %d/%d | Буст: %d/%d" % [
		used, MAX_POT_ACTIONS_PER_DAY,
		int(_daily["lecture"]), MAX_LECTURE_PER_DAY,
		int(_daily["boost"]),   MAX_BOOST_PER_DAY
	]

# === ACTIONS ===
func _act_plant(crop_id:String) -> void:
	if selected_idx < 0:
		return
	var p = pots[selected_idx]
	if p.crop_id != "":
		return
	var cdef = CROPS.get(crop_id, {})
	p.crop_id = crop_id
	p.title = CROPS[crop_id]["title"]
	p.day = 0
	p.mature_in = _roll_mature_days(cdef)
	p.water = 50
	p.nutrients = 50
	p.stress = 0
	p.health = 100
	p.weeds = 0
	p.tags = []
	p.harvest_ready = false
	p.last_fert_day = -999
	p.last_fert_type = ""
	pots[selected_idx] = p
	_log("Посажено: %s" % p.title)
	_build_pots_ui()
	_update_ui()
	_save_state()
	_daily["actions"][selected_idx] = 0
	_daily["day"] = int(GameManager.day) if typeof(GameManager) == TYPE_OBJECT else _daily["day"]
	_save_daily()

func _act_water(mode:String) -> void:
	if not _can_use_action_on_pot():
		return
	var p := _sel_pot()
	if p.crop_id == "":
		return
	if mode == "low":
		p.water = clamp(p.water + 10, 0, 100)
	elif mode == "normal":
		p.water = clamp(p.water + 20, 0, 100)
	else:
		p.water = clamp(p.water + 35, 0, 100)
	_spend_pot_action()
	_log("Полив (%s) для %s" % [mode, p.title])
	pots[selected_idx] = p
	_build_pots_ui()
	_update_ui()
	_save_state()

func _act_fertilize(fid:String) -> void:
	if not _can_use_action_on_pot():
		return
	var p := _sel_pot()
	if p.crop_id == "":
		return
	var cday = p.day
	var cdef = CROPS[p.crop_id]
	var cd := int(cdef.get("fert_cooldown",3))
	if cday - int(p.last_fert_day) < cd:
		_log("Рано удобрять %s — откат ещё идёт." % p.title)
		return
	var f = FERTS.get(fid,{})
	var add_n := int(f.get("effects",{}).get("nutrients",15))
	var add_s := int(f.get("effects",{}).get("stress",0))
	p.nutrients = clamp(p.nutrients + add_n, 0, 100)
	p.stress = clamp(p.stress + add_s, 0, 100)
	p.last_fert_day = cday
	p.last_fert_type = fid
	_spend_pot_action()
	_log("Удобрение «%s» для %s" % [f.get("title",fid), p.title])
	pots[selected_idx] = p
	_build_pots_ui()
	_update_ui()
	_save_state()

func _act_weed() -> void:
	if not _can_use_action_on_pot():
		return
	var p := _sel_pot()
	if p.crop_id == "":
		return
	p.weeds = max(0, int(p.weeds) - 40)
	p.stress = clamp(p.stress + 3, 0, 100)
	_spend_pot_action()
	_log("Прополка: %s" % p.title)
	pots[selected_idx] = p
	_build_pots_ui()
	_update_ui()
	_save_state()

func _act_therapy(tid:String) -> void:
	if not _can_use_action_on_pot():
		return
	var p := _sel_pot()
	if p.crop_id == "":
		return
	var t = TOPICS.get(tid, {})
	p.tags.append(t.get("tag_add",""))
	p.stress = clamp(p.stress + int(t.get("stress",0)), 0, 100)
	_spend_pot_action()
	_log("Терапия: %s → %s" % [t.get("title",tid), p.title])
	pots[selected_idx] = p
	_build_pots_ui()
	_update_ui()
	_save_state()

func _act_harvest() -> void:
	if selected_idx < 0:
		return
	var p := _sel_pot()
	if not bool(p.get("harvest_ready",false)):
		return
	var cdef = CROPS[p.crop_id]

	var base_qty := (randi() % 2) + 1
	_give_loot("crop_" + p.crop_id, base_qty)

	var special_applied := _try_special_yield_apply(p, cdef)  # ← применяет немедленно
	if special_applied:
		_log("Сбор: %s (обычный ×%d) + применён особый бонус" % [cdef["title"], base_qty])
	else:
		_log("Сбор: %s (обычный ×%d)" % [cdef["title"], base_qty])

	pots[selected_idx] = _new_empty_pot()
	day_actions_used.erase(selected_idx)
	_build_pots_ui()
	_update_ui()
	_save_state()



func _act_remove() -> void:
	if selected_idx < 0:
		return
	pots[selected_idx] = _new_empty_pot()
	_daily["actions"].erase(selected_idx)
	_save_daily()
	_log("Горшок очищен.")
	_build_pots_ui()
	_update_ui()
	_save_state()

# === GLOBAL ===
func _act_lecture(tid:String) -> void:
	if int(_daily["lecture"]) >= MAX_LECTURE_PER_DAY:
		_log("Лекция сегодня уже была.")
		return
	_daily["lecture"] = int(_daily["lecture"]) + 1
	_save_daily()
	var applied := 0
	for i in range(pots.size()):
		if applied >= 3:
			break
		if pots[i].crop_id != "":
			var t = TOPICS.get(tid,{})
			pots[i].tags.append(t.get("tag_add",""))
			pots[i].stress = clamp(pots[i].stress + int(t.get("stress",0)), 0, 100)
			applied += 1
	_log("Групповая лекция (%s) применена к %d горшкам." % [TOPICS[tid].get("title",tid), applied])
	_build_pots_ui()
	_update_ui()
	_save_state()

func _act_boost(fid:String) -> void:
	if int(_daily["boost"]) >= MAX_BOOST_PER_DAY:
		_log("Буст дня уже использован.")
		return
	_daily["boost"] = int(_daily["boost"]) + 1
	_save_daily()
	if selected_idx >= 0 and pots[selected_idx].crop_id != "":
		var f = FERTS.get(fid,{})
		var add_n := int(f.get("effects",{}).get("nutrients",15))
		var add_s := int(f.get("effects",{}).get("stress",0))
		pots[selected_idx].nutrients = clamp(pots[selected_idx].nutrients + add_n, 0, 100)
		pots[selected_idx].stress = clamp(pots[selected_idx].stress + add_s, 0, 100)
		pots[selected_idx].last_fert_type = fid
		_log("Буст: бесплатное удобрение «%s» в %s" % [f.get("title",fid), pots[selected_idx].title])
	else:
		_log("Буст активирован — выбери горшок, чтобы применить.")
	_build_pots_ui()
	_update_ui()
	_save_state()

# === DAY TICK (ВЫЗЫВАЕТ ТОЛЬКО ГЛОБАЛЬНАЯ СИСТЕМА ДНЯ/НОЧИ) ===
func sally_garden_tick_from_gm() -> void:
	# сад уже «протикан» на стороне GameManager; здесь только сброс дневных лимитов и перерисовка
	_load_daily()          # подхватить новый день (обнулит лимиты)
	_build_pots_ui()
	_update_ui()
	_save_state()

func _tick_day() -> void:
	for i in range(pots.size()):
		var p = pots[i]
		if p.crop_id == "":
			continue
		var cdef = CROPS[p.crop_id]

		p.day += 1
		p.water = clamp(p.water - 15, 0, 100)
		p.nutrients = clamp(p.nutrients - 8, 0, 100)
		p.weeds = clamp(p.weeds + 8, 0, 100)

		var water_ok = (p.water >= 40 and p.water <= 75)
		if not water_ok:
			p.stress = clamp(p.stress + 5, 0, 100)
		if p.weeds > 50:
			p.stress = clamp(p.stress + 4, 0, 100)

		for t in p.tags:
			if t in cdef.get("fav_topics",[]):
				p.stress = clamp(p.stress - 2, 0, 100)

		var hp_delta := 0
		if p.stress >= 60:
			hp_delta -= 6
		if p.weeds >= 70:
			hp_delta -= 4
		if p.water <= 15 or p.water >= 90:
			hp_delta -= 5
		p.health = clamp(p.health + hp_delta, 0, 100)

		if p.day >= p.mature_in and p.health > 0:
			p.harvest_ready = true
		if p.health <= 0:
			_log("Растение погибло: %s" % p.title)
			p = _new_empty_pot()

		pots[i] = p

	day_actions_used.clear()
	lecture_used_today = 0
	boost_used_today = 0

	_log("День завершён (глобальный тик).")
	_build_pots_ui()
	_update_ui()
	_save_state()

# === SPECIAL YIELD CHECK ===
func _try_special_yield(p:Dictionary, cdef:Dictionary) -> String:
	for sp in cdef.get("specials", []):
		var need_ok := true
		if sp.has("need_tags"):
			for t in sp["need_tags"]:
				if not t in p.tags:
					need_ok = false
					break
		if need_ok and sp.has("need_fert_any"):
			var ok := false
			for f in sp["need_fert_any"]:
				if p.get("last_fert_type","") == f:
					ok = true
					break
			if not ok:
				need_ok = false
		if need_ok and sp.has("need_health"):
			if p.health < int(sp["need_health"]):
				need_ok = false
		if need_ok:
			_apply_grants(sp.get("grants", []))
			return String(sp.get("special_item",""))
	return ""

func _apply_grants(gs:Array) -> void:
	for g in gs:
		var t := String(g.get("type",""))
		if t == "qual_xp" or t == "class_xp":  # поддержим оба ключа
			var who := String(g.get("who","Sally"))
			var qual := String(g.get("qual", g.get("class","")))
			var amt := int(g.get("amount",1))
			if typeof(GameManager) == TYPE_OBJECT:
				if GameManager.has_method("add_qual_xp"):
					GameManager.add_qual_xp(who, qual, amt)
				elif GameManager.has_method("add_class_xp"):
					GameManager.add_class_xp(who, qual, amt)
			_log("Награда: +%d к квалификации %s (%s)" % [amt, qual, who])
		elif t == "heal":
			if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("cure_condition"):
				GameManager.cure_condition("Sally", String(g.get("cond","")), int(g.get("days",1)))
			_log("Награда: лечение состояния (%s)" % String(g.get("cond","")))


func _try_special_yield_apply(p:Dictionary, cdef:Dictionary) -> bool:
	for sp in cdef.get("specials", []):
		var need_ok := true
		if sp.has("need_tags"):
			for t in sp["need_tags"]:
				if not t in p.tags:
					need_ok = false
					break
		if need_ok and sp.has("need_fert_any"):
			var ok := false
			for f in sp["need_fert_any"]:
				if p.get("last_fert_type","") == f:
					ok = true; break
			if not ok:
				need_ok = false
		if need_ok and sp.has("need_health"):
			if p.health < int(sp["need_health"]):
				need_ok = false
		if need_ok:
			_apply_grants(sp.get("grants", []))  # ← сразу применяем
			if Engine.has_singleton("Toasts"):
				Toasts.ok("Особый урожай: " + String(sp.get("title","+классификация")))
			return true
	return false


func _give_loot(item_id:String, qty:int) -> void:
	if typeof(GameManager) == TYPE_OBJECT:
		if GameManager.has_method("add_supply"):
			GameManager.add_supply(item_id, qty)   # ← основной путь
		elif GameManager.has_method("add_item"):
			GameManager.add_item(item_id, qty)     # ← запасной
	_log("Получено (склад): %s ×%d" % [item_id, qty])
