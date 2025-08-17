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

# ── ДОБАВИТЬ: публичный геттер «как у Берита» ────────────────────────
func get_sally_enhance(skill_name: String, mode: String) -> Dictionary:
	# mode ожидается "blue" или "gold"
	_ensure_sally_enh_loaded()
	var enh_root: Dictionary = _sally_enh_cache.get("enhance", {})
	var by_skill: Dictionary = enh_root.get(skill_name, {})
	return by_skill.get(mode, {})


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
