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

# Список способностей (будет заполнен позже)
var abilities: Array = []

# Команда (сторона) персонажа: "hero" или "enemy"
var team: String = ""

func _ready():
	_init_abilities()
	play_idle()

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

	health = d.get("hp", max_health)
	mana = d.get("mana", max_mana)
	stamina = d.get("stamina", max_stamina)

	abilities = d.get("skills", [])

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
