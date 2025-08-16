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



var coins_box: HBoxContainer = null
var coin_nodes: Array[Panel] = []
@export var ETHER_ICON := "res://Assets/icons/mechanics/ether.png" # опционально

func _refresh_berit_coins() -> void:
	if hero == null or String(hero.nick) != "Berit":
		return
	if coins_box == null or not is_instance_valid(coins_box) or coin_nodes.size() != 7:
		return

	var palette := {
		"yellow": Color(1.0, 0.92, 0.20),
		"blue":   Color(0.35, 0.55, 1.0),
		"green":  Color(0.30, 0.85, 0.45)
	}
	var empty_border := Color(0.55, 0.55, 0.55)
	var empty_fill   := Color(0,0,0,0)

	var arr: Array = []
	if hero and hero.has_method("coins_count"):
		arr = hero.ether_coins

	for i in range(7):
		var p: Panel = coin_nodes[i]
		var sb: StyleBoxFlat = p.get_theme_stylebox("panel") as StyleBoxFlat
		if sb == null:
			continue

		if i < arr.size():
			var col = palette.get(String(arr[i]), Color(1,1,1))
			sb.bg_color = col
			sb.border_color = col.darkened(0.25)
			sb.set_border_width_all(1)
		else:
			sb.bg_color = empty_fill
			sb.border_color = empty_border
			sb.set_border_width_all(1)

		p.add_theme_stylebox_override("panel", sb)  # на всякий, чтобы обновилось немедленно

const TURN_THRESHOLD := 1000.0  # чтобы TM была в 0..1000

func bind(h: Node2D):
	hero = h
	_refresh_mechanic() # можно оставить, но не обязательно
	# подписка на изменения монет
	if hero and hero.has_signal("coins_changed"):
		if not hero.is_connected("coins_changed", Callable(self, "_refresh_berit_coins")):
			hero.connect("coins_changed", Callable(self, "_refresh_berit_coins"))
	_refresh_mechanic()      # ← важнее, чем прямой _refresh_berit_coins()
	# иконка по нику (как и у очереди)
	var p_icon := "res://Assets/icons/characters/%s.png" % hero.nick
	if ResourceLoader.exists(p_icon):
		icon.texture = load(p_icon)
	else:
		icon.texture = load("res://Assets/icons/characters/placeholder.png")
	if String(hero.nick) == "Berit":
		hero.add_coin("yellow")
		hero.add_coin("blue")
		hero.add_coin("green")


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
		if max_mana <= 0:
			max_mana = 1
		mp.max_value = max(1, max_mana)
		mp.value     = clamp(mana, 0, mp.max_value)
		mp_val.text  = str(mana, " / ", max_mana)

		var max_sta := int(hero.get("max_stamina"))
		var sta_v   := int(hero.get("stamina"))
		sta.visible = max_sta > 0
		if max_sta <= 0:
			max_sta = 1
		sta.max_value = max(1, max_sta)
		sta.value     = clamp(sta_v, 0, sta.max_value)
		sta_val.text  = str(sta_v, " / ", max_sta)
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
		var tex: Texture2D = null
		if ResourceLoader.exists(path):
			tex = load(path)
		elif ResourceLoader.exists(EFFECT_ICON_FALLBACK):
			tex = load(EFFECT_ICON_FALLBACK)
		tr.texture = tex
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

	# ── Берит: вместо текста Value рисуем 7 кружков ──
	if String(hero.nick) == "Berit":
		mech_box.show()
		if mech_val and is_instance_valid(mech_val):
			mech_val.hide()

		# иконка механики (эфир)
		if ETHER_ICON != "" and ResourceLoader.exists(ETHER_ICON) and mech_icon and is_instance_valid(mech_icon):
			mech_icon.texture = load(ETHER_ICON)

		# контейнер с кружками
		if coins_box == null or not is_instance_valid(coins_box):
			coins_box = HBoxContainer.new()
			coins_box.name = "BeritCoins"
			coins_box.add_theme_constant_override("separation", 6)
			mech_box.add_child(coins_box)

			coin_nodes.clear()
			for i in range(7):
				var c := Panel.new()
				c.name = "Coin%d" % (i+1)
				c.custom_minimum_size = Vector2(14, 14)
				c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				c.size_flags_vertical   = Control.SIZE_SHRINK_CENTER

				var sb := StyleBoxFlat.new()
				sb.bg_color = Color(0,0,0,0)              # пустая заливка
				sb.border_color = Color(0.55, 0.55, 0.55) # серый контур для пустых
				sb.corner_detail = 8
				sb.shadow_size = 2
				sb.shadow_color = Color(0,0,0,0.25)

				sb.set_border_width_all(1)     # ← ВАЖНО: метод, не свойство
				sb.set_corner_radius_all(999)  # ← чтобы был идеальный круг

				c.add_theme_stylebox_override("panel", sb)
				coins_box.add_child(c)
				coin_nodes.append(c)
		else:
			coins_box.show()

		_refresh_berit_coins()
		return  # ← не прячем механику ниже

	# ── Остальные герои: обычная механика (как было) ──
	if not hero.has_method("get_mechanic"):
		mech_box.visible = false
		return

	var m: Dictionary = hero.call("get_mechanic")
	if m.size() == 0 or String(m.get("id","")) == "":
		mech_box.visible = false
		return

	mech_box.visible = true
	if coins_box and is_instance_valid(coins_box):
		coins_box.hide()

	var id := String(m.get("id",""))
	var name := String(m.get("name", id))
	var v := int(m.get("value", 0))
	var mx := int(m.get("max", 0))

	var p := "%s/%s.png" % [MECH_ICON_DIR, id]
	if ResourceLoader.exists(p):
		mech_icon.texture = load(p)
	else:
		mech_icon.texture = null
	mech_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	if mx > 0:
		mech_val.text = "%s: %d/%d" % [name, v, mx]
	else:
		mech_val.text = "%s: %d" % [name, v]
	mech_val.show()
