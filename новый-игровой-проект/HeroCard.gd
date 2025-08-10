extends VBoxContainer

var hero: Node2D

@onready var icon := $HBoxContainer/Icon
@onready var hp   := $HBoxContainer/VBoxContainer/HProw/HP
@onready var mp   := $HBoxContainer/VBoxContainer/MProw/MP
@onready var sta  := $HBoxContainer/VBoxContainer/STArow/STA
@onready var tm   := $HBoxContainer/VBoxContainer/TMrow/TM

@onready var hp_val  := $HBoxContainer/VBoxContainer/HProw/HPVal
@onready var mp_val  := $HBoxContainer/VBoxContainer/MProw/MPVal
@onready var sta_val := $HBoxContainer/VBoxContainer/STArow/STAVal
@onready var tm_val  := $HBoxContainer/VBoxContainer/TMrow/TMVal


const TURN_THRESHOLD := 1000.0  # чтобы TM была в 0..1000

func bind(h: Node2D):
	hero = h
	# иконка по нику (как и у очереди)
	var p := "res://Assets/icons/characters/%s.png" % hero.nick
	icon.texture = load(p) if ResourceLoader.exists(p) else load("res://Assets/icons/characters/placeholder.png")

func _process(_dt):
	if hero == null or !is_instance_valid(hero):
		queue_free()
		return

	# безопасные геттеры
	var max_hp = max(1, int(hero.max_health))
	var cur_hp = clamp(int(hero.health), 0, max_hp)
	hp.max_value = max_hp
	hp.value     = cur_hp
	hp_val.text      = str(cur_hp, " / ", max_hp)

	if hero.has_method("get") or true:
		var max_mana := int(hero.get("max_mana"))
		var mana     := int(hero.get("mana"))
		mp.visible = max_mana > 0
		mp.max_value = max(1, max_mana if max_mana > 0 else 1)
		mp.value     = clamp(mana, 0, mp.max_value)
		mp_val.text      = str(mana, " / ", max_mana)
		var max_sta := int(hero.get("max_stamina"))
		var sta_v   := int(hero.get("stamina"))
		sta.visible = max_sta > 0
		sta.max_value = max(1, max_sta if max_sta > 0 else 1)
		sta.value     = clamp(sta_v, 0, sta.max_value)
		sta_val.text      = str(sta_v, " / ", max_sta)
	# шкала очереди (тот же turn_meter, что в боевой логике)
	var meter: float = float(hero.turn_meter)
	tm.max_value = TURN_THRESHOLD
	tm.value     = clampf(meter, 0.0, TURN_THRESHOLD)
	tm_val.text      = str(int(meter), " / ", int(TURN_THRESHOLD))
