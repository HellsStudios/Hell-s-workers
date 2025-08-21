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

# ------------- Quests -------------
func _load_quests_from_json(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("[Quests] file not found: " + path)
		quests_all = {}
		emit_signal("quests_changed")
		return
	var txt := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(txt)
	var root = (parsed if typeof(parsed) == TYPE_DICTIONARY else {})
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
	if not quests_all.has(id): return {}
	var q: Dictionary = quests_all[id]
	return (q.get("rewards", {}) if q.has("rewards") else {})

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
			d["nick"] = d.get("nick", name)
			d["team"] = "hero"
			d["hp"] = d.get("max_hp", 100)
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
