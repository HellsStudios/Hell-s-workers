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

# Семь смертных грехов – значения от 0 до 100, например
@export var sin_pride: int = 0
@export var sin_greed: int = 0
@export var sin_lust: int = 0
@export var sin_envy: int = 0
@export var sin_gluttony: int = 0
@export var sin_wrath: int = 0
@export var sin_sloth: int = 0

var dodge_window: float = 0.12
var block_window: float = 0.18
var block_reduce: float = 0.5  # 0.5 = блок режет урон наполовину при «успехе»

# Список способностей (будет заполнен позже)
var abilities: Array = []

# Команда (сторона) персонажа: "hero" или "enemy"
var team: String = ""

func _ready():
	_init_abilities()
	play_idle()

@export var carry_slots_max := 3
@export var forbidden_categories: Array[String] = []
var pack: Dictionary = {}  # id -> количество (то, что ВЗЯТО в бой)

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
	
func _anim_hit_event() -> void:
	emit_signal("hit_event")

func init_from_dict(d: Dictionary) -> void:
	nick = d.get("nick", "Hero")
	team = d.get("team", "hero")
	max_health = d.get("max_hp", 100)
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

	abilities = d.get("skills", [])
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
		


func add_effect(e: Dictionary) -> void:
	var id := String(e.get("id",""))
	if id != "":
		# без стака: продлеваем существующий
		for i in range(effects.size()):
			var ex: Dictionary = effects[i]
			if String(ex.get("id","")) == id and not bool(e.get("stack", false)):
				ex["duration"] = int(e.get("duration", ex.get("duration", -1)))
				effects[i] = ex
				return
	effects.append(e)

func get_effects() -> Array:
	return effects

func effective_stat(which: String) -> float:
	var base := 0.0
	match which:
		"attack":  base = float(attack)
		"defense": base = float(defense)
		"speed":   base = float(speed)
		_:         base = 0.0
	for ex in effects:
		base += float(ex.get(which, 0.0))
	return base

func on_turn_start() -> void:
	# DoT
	for ex in effects:
		if ex.has("dot"):
			health = max(0, health - int(ex.get("dot", 0)))

	# реген стамины героя
	if team == "hero" and max_stamina > 0:
		stamina = min(max_stamina, stamina + 10)

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
