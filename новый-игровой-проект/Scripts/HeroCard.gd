extends VBoxContainer

var hero: Node2D

@export var MECH_ICON_DIR := "res://Assets/icons/mechanics"
@onready var mech_box  := $HBoxContainer/VBoxContainer/Mechanic
@onready var mech_icon := $HBoxContainer/VBoxContainer/Mechanic/Icon
@onready var mech_val  := $HBoxContainer/VBoxContainer/Mechanic/Value

@onready var icon := $HBoxContainer/Icon
@onready var hp   := $HBoxContainer/VBoxContainer/HProw/HP
@onready var mp   := $HBoxContainer/VBoxContainer/MProw/MP
@onready var sta  := $HBoxContainer/VBoxContainer/STArow/STA
@onready var tm   := $HBoxContainer/VBoxContainer/TMrow/TM

@onready var hp_val  := $HBoxContainer/VBoxContainer/HProw/HPVal
@onready var mp_val  := $HBoxContainer/VBoxContainer/MProw/MPVal
@onready var sta_val := $HBoxContainer/VBoxContainer/STArow/STAVal
@onready var tm_val  := $HBoxContainer/VBoxContainer/TMrow/TMVal

@onready var hero_effects := $HBoxContainer/VBoxContainer/Effects
@export var EFFECT_ICON_DIR := "res://Assets/icons/effects"
@export var EFFECT_ICON_FALLBACK := "res://Assets/icons/effects/_default.png"



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
	_refresh_mechanic()
	if hero: _refresh_effect_icons()
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
	
func _refresh_effect_icons():
	for c in hero_effects.get_children(): c.queue_free()
	if hero == null or not hero.has_method("get_effects"): return
	for ex in hero.call("get_effects"):
		var id := String(ex.get("id",""))
		if id == "": continue
		var path := "%s/%s.png" % [EFFECT_ICON_DIR, id]
		var tr := TextureRect.new()
		tr.texture = load(path) if ResourceLoader.exists(path) else (load(EFFECT_ICON_FALLBACK) if ResourceLoader.exists(EFFECT_ICON_FALLBACK) else null)
		tr.custom_minimum_size = Vector2(18,18)
		tr.tooltip_text = String(ex.get("name", id))
		hero_effects.add_child(tr)
	
func set_hero(h: Node2D) -> void:
	hero = h
	_refresh_mechanic()

func _refresh_mechanic() -> void:
	if hero == null or not is_instance_valid(hero):
		mech_box.visible = false
		return
	if not hero.has_method("get_mechanic"):
		mech_box.visible = false
		return

	var m: Dictionary = hero.call("get_mechanic")
	if m.size() == 0 or String(m.get("id","")) == "":
		mech_box.visible = false
		return

	mech_box.visible = true
	var id := String(m.get("id",""))
	var name := String(m.get("name", id))
	var v := int(m.get("value", 0))
	var mx := int(m.get("max", 0))

	# иконка
	var p := "%s/%s.png" % [MECH_ICON_DIR, id]
	mech_icon.texture = load(p) if ResourceLoader.exists(p) else null
	mech_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	# текст
	if mx > 0:
		mech_val.text = "%s: %d/%d" % [name, v, mx]
	else:
		mech_val.text = "%s: %d" % [name, v]
