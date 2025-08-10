extends Node

var all_heroes: Dictionary = {}          # name -> dict статов
var party_names: Array = ["Berit","Sally","Dante"]      # ["Berit","Sally","Dante"]
var inventory: Dictionary = {}           # можно позже заполнить
# Глобальные игровые данные
var day: int = 1
var resources: int = 0
var current_phase: int = 0
var phase_names = ["Утро", "День", "Вечер", "Ночь"]

func _ready() -> void:
	load_heroes("res://Data/characters.json")

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
