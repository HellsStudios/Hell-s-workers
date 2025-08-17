extends PanelContainer

signal action_selected(action_type: String, actor: Node2D, data)
signal item_chosen(user, item_id)

@export var DEBUG_AP := true

var current_hero: Node2D

@onready var MainMenuContainer  = $MainMenuContainer
@onready var SkillMenuContainer = $SkillMenuContainer
@onready var ItemMenuContainer  = $ItemMenuContainer

@export var PANEL_BASE_MIN_SIZE := Vector2(260, 140) # базовый минимум ActionPanel


@onready var buttons_box: Control = $SkillMenuContainer
@onready var desc_panel: PanelContainer = $SkillMenuContainer/DescPanel
@onready var desc_label: RichTextLabel = $SkillMenuContainer/DescPanel/MarginContainer/Desc

# — только новый способ показа стоимости —
@export var USE_EMOJI_COST := true
@export var COST_GLYPHS := {"stamina":"🟡","mana":"🔵"}
@export var COST_ASCII  := {"stamina":"St:", "mana":"Mp:"}
@export var PANEL_MIN_WIDTH := 220
@export var SAFE_TOP := 20
@export var SAFE_BOTTOM := 120     # высота нижнего HUD (портреты/полоски)
@export var SAFE_SIDE := 24
@export var HERO_X_ANCHOR := 0.34  # доля ширины экрана (где «центр» панели у героев)
@export var ENEMY_X_ANCHOR := 0.66 # для врагов
var _tween: Tween

@export var ENHANCE_TINT := Color(1.0, 0.95, 0.4) # мягкое «золото»

@export var SALLY_RED_TINT  := Color(1.0, 0.45, 0.45)
@export var SALLY_BLUE_TINT := Color(0.55, 0.75, 1.0)
@export var SALLY_GOLD_TINT := Color(1.0, 0.92, 0.35)

func _sally_tint_for_skill(hero: Node2D, skill: Dictionary) -> Color:
	if hero == null or not is_instance_valid(hero): return Color(1,1,1)
	if String(hero.nick) != "Sally": return Color(1,1,1)
	if bool(hero.get_meta("sally_golden", false)):
		return SALLY_GOLD_TINT
	var desc := String(skill.get("desc", skill.get("description", skill.get("text","")))).to_lower()
	var words: Dictionary = hero.get_meta("sally_words", {})
	var blue := String(words.get("blue","")).to_lower()
	var red  := String(words.get("red","")).to_lower()
	if blue != "" and desc.findn(blue) != -1:
		return SALLY_BLUE_TINT
	if red  != "" and desc.findn(red)  != -1:
		return SALLY_RED_TINT
	return Color(1,1,1)

func _can_enhance(hero: Node2D, skill: Dictionary) -> bool:
	var name := String(skill.get("name",""))
	if String(hero.nick) != "Berit" or name == "":
		return false
	var recipe := GameManager.get_berit_recipe(name)
	if recipe.is_empty():
		return false
	var consume: Dictionary = recipe.get("consume", {})
	return hero.has_method("can_pay_coins") and hero.can_pay_coins(consume)

func _apply_enhance_highlight(btn: Button, on: bool) -> void:
	btn.modulate = (ENHANCE_TINT if on else Color(1,1,1))

func _log(msg: String) -> void:
	if DEBUG_AP: print(msg)

func _ready() -> void:
	# оформление и параметры описания
	if desc_panel:
		desc_panel.visible = false
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0,0,0,0.55)
		sb.corner_radius_top_left = 8
		sb.corner_radius_top_right = 8
		sb.corner_radius_bottom_left = 8
		sb.corner_radius_bottom_right = 8
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		desc_panel.add_theme_stylebox_override("panel", sb)
		desc_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	if desc_label:
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_label.bbcode_enabled = false

	# зафиксировать базовые размеры самой панели
	custom_minimum_size = PANEL_BASE_MIN_SIZE
	custom_minimum_size.x = max(custom_minimum_size.x, PANEL_MIN_WIDTH)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	# при ресайзе окна — перепозиционируем
	get_viewport().connect("size_changed", Callable(self, "_reposition_now"))
	connect("visibility_changed", Callable(self, "_on_visibility_changed"))
	_log("[AP] READY: buttons_box=%s desc_panel=%s desc_label=%s" % [buttons_box, desc_panel, desc_label])
	
func _reposition_now() -> void:
	if !visible:
		return
	await get_tree().process_frame # дождаться лэйаута
	var vp := get_viewport_rect().size
	var s  := get_combined_minimum_size()
	s.x = max(s.x, PANEL_MIN_WIDTH)

	# выбор стороны
	var is_enemy := current_hero != null and String(current_hero.team) == "enemy"
	var ax := ENEMY_X_ANCHOR if is_enemy else HERO_X_ANCHOR

	# целевая позиция (центр панели на оси X)
	var x := vp.x * ax - s.x * 0.5
	var y := vp.y * 0.55 - s.y * 0.5  # чуть ниже центра экрана

	# клампы в безопасный прямоугольник
	x = clamp(x, SAFE_SIDE, vp.x - SAFE_SIDE - s.x)
	y = clamp(y, SAFE_TOP, vp.y - SAFE_BOTTOM - s.y)

	position = Vector2(round(x), round(y))

func _on_visibility_changed() -> void:
	# при скрытии панели схлопываем описание и сбрасываем размер
	if not visible:
		_collapse_desc_immediately()

# ---------- utils ----------
func _extract_costs(skill: Dictionary) -> Dictionary:
	var out := {}
	var cost = skill.get("costs", skill.get("cost", {}))
	var mana := int(cost.get("mana", skill.get("mana_cost", 0)))
	var sta  := int(cost.get("stamina", skill.get("stamina_cost", 0)))
	if mana > 0: out["mana"] = mana
	if sta  > 0: out["stamina"] = sta
	return out

func _compose_btn_caption(skill: Dictionary) -> String:
	var name := String(skill.get("name","Skill"))
	var costs := _extract_costs(skill)
	if costs.is_empty():
		return name

	var parts: Array[String] = []
	for key in ["stamina", "mana"]:
		if costs.has(key):
			var tag := ""
			if USE_EMOJI_COST:
				tag = String(COST_GLYPHS.get(key, ""))
			else:
				tag = String(COST_ASCII.get(key, ""))
			if tag == "":
				tag = key.left(1).to_upper()
			parts.append("%s%d" % [tag, int(costs[key])])

	return "%s   %s" % [name, " ".join(parts)]

func _get_skill_desc(skill: Dictionary) -> String:
	var txt := String(skill.get("desc", ""))
	if txt == "":
		txt = String(skill.get("description", skill.get("text", "")))
	return txt

func _any_button_hot_or_focused() -> bool:
	var mouse := get_viewport().get_mouse_position()
	for i in range(1, 7):
		var path := "SkillMenuContainer/SkillButton%d" % i
		if not has_node(path): continue
		var b: Button = get_node(path)
		if not b.visible: continue
		if b.has_focus(): return true
		if b.get_global_rect().has_point(mouse): return true
	return false

# ---------- description (всплывашка) ----------
func _hook_hover_for_desc(b: Button) -> void:
	if not b.is_connected("mouse_entered", Callable(self, "_on_btn_mouse_entered")):
		b.connect("mouse_entered", Callable(self, "_on_btn_mouse_entered").bind(b))
	if not b.is_connected("mouse_exited", Callable(self, "_on_btn_mouse_exited")):
		b.connect("mouse_exited", Callable(self, "_on_btn_mouse_exited").bind(b))
	if not b.is_connected("focus_entered", Callable(self, "_on_btn_focus_entered")):
		b.connect("focus_entered", Callable(self, "_on_btn_focus_entered").bind(b))
	if not b.is_connected("focus_exited", Callable(self, "_on_btn_focus_exited")):
		b.connect("focus_exited", Callable(self, "_on_btn_focus_exited").bind(b))
	_log("[AP] SIGNALS HOOKED for %s" % b.name)

func _on_btn_mouse_entered(b: Button) -> void:
	_log("[AP] HOVER ENTER btn=%s" % b.name)
	_show_desc_for_button(b)

func _on_btn_mouse_exited(_b: Button) -> void:
	await get_tree().process_frame
	_log("[AP] HOVER EXIT")
	if not _any_button_hot_or_focused():
		_hide_desc()

func _on_btn_focus_entered(b: Button) -> void:
	_log("[AP] FOCUS ENTER btn=%s" % b.name)
	_show_desc_for_button(b)

func _on_btn_focus_exited(_b: Button) -> void:
	await get_tree().process_frame
	_log("[AP] FOCUS EXIT")
	if not _any_button_hot_or_focused():
		_hide_desc()

func _show_desc_for_button(b: Button) -> void:
	if desc_panel == null or desc_label == null:
		_log("[AP][WARN] desc_panel or desc_label is null"); return
	var skill: Dictionary = b.get_meta("skill", {})
	var text := _get_skill_desc(skill)
	var len := text.length()
	if len == 0:
		_log("[AP] DESC EMPTY for %s (no desc)" % b.name)
		_hide_desc(); return

	if desc_label.bbcode_enabled:
		desc_label.text = ""; desc_label.bbcode_text = text
	else:
		desc_label.text = text

	await get_tree().process_frame
	var want_h = max(36.0, float(desc_label.get_content_height()) + 12.0)
	_log("[AP] DESC SHOW btn=%s desc_len=%d want_h=%.1f" % [b.name, len, want_h])
	_animate_desc_open_with(want_h)

func _animate_desc_open_with(want_h: float) -> void:
	desc_panel.visible = true
	desc_panel.modulate.a = 0.0
	if _tween and _tween.is_running(): _tween.kill()
	_tween = create_tween()
	_tween.tween_property(desc_panel, "modulate:a", 1.0, 0.12)
	var cur := desc_panel.custom_minimum_size
	desc_panel.custom_minimum_size = Vector2(cur.x, cur.y)
	_tween.parallel().tween_property(
		desc_panel, "custom_minimum_size", Vector2(cur.x, want_h), 0.12
	)

func _hide_desc() -> void:
	if desc_panel == null or not desc_panel.visible: return
	_log("[AP] DESC HIDE")
	if _tween and _tween.is_running(): _tween.kill()
	_tween = create_tween()
	_tween.tween_property(desc_panel, "modulate:a", 0.0, 0.12)
	_tween.tween_callback(Callable(self, "_collapse_desc_immediately"))

func _collapse_desc_immediately() -> void:
	if _tween and _tween.is_running():
		_tween.kill()
	if desc_panel == null:
		return
	desc_label.text = ""
	desc_panel.visible = false
	desc_panel.modulate.a = 1.0
	desc_panel.custom_minimum_size = Vector2(0, 0)
	desc_panel.queue_redraw()
	# обновим лейаут контейнеров и сбросим размер самой панели до минимума
	if SkillMenuContainer:
		SkillMenuContainer.queue_redraw()
	reset_size()  # вернёт Control к минимальным размерам
	
	
func _on_berit_coins_changed() -> void:
	if current_hero and String(current_hero.nick) == "Berit":
		update_skill_buttons_for(current_hero)
# ---------- show menus ----------
func show_main_menu(hero: Node2D):
	_collapse_desc_immediately()
	current_hero = hero
	visible = true
	MainMenuContainer.visible = true
	SkillMenuContainer.visible = false
	ItemMenuContainer.visible = false
		# следим за монетами Берита
	if hero and String(hero.nick) == "Berit" and hero.has_signal("coins_changed"):
		if not hero.is_connected("coins_changed", Callable(self, "_on_berit_coins_changed")):
			hero.connect("coins_changed", Callable(self, "_on_berit_coins_changed"))
	update_skill_buttons_for(hero)
	update_item_buttons()
	_reposition_now()

# ---------- main buttons ----------
func _on_AttackButton_pressed(): emit_signal("action_selected", "attack", current_hero, null)

func _on_SkillButton_pressed():
	_collapse_desc_immediately()
	MainMenuContainer.visible = false
	SkillMenuContainer.visible = true
	_reposition_now()

func _on_ItemButton_pressed():
	_collapse_desc_immediately()
	MainMenuContainer.visible = false
	ItemMenuContainer.visible = true
	_reposition_now()

func _on_SkipButton_pressed(): emit_signal("action_selected", "skip", current_hero, null)

func _on_BackButton_pressed():
	_collapse_desc_immediately()
	MainMenuContainer.visible = true
	SkillMenuContainer.visible = false
	ItemMenuContainer.visible = false
	_reposition_now()

func _on_BackButton2_pressed():
	_collapse_desc_immediately()
	MainMenuContainer.visible = true
	ItemMenuContainer.visible = false
	_reposition_now()

# ---------- skills ----------
func update_skill_buttons_for(hero: Node2D):
	_collapse_desc_immediately()
	if hero == null or not is_instance_valid(hero):
		return

	var skills: Array = hero.abilities
	_log("[AP] POPULATE hero=%s abilities=%d" % [String(hero.nick), skills.size()])

	for i in range(6):
		var path := "SkillMenuContainer/SkillButton%d" % (i+1)
		if not has_node(path):
			_log("[AP][WARN] no node at %s" % path)
			continue
		var btn: Button = get_node(path)

		# сброс в дефолт, чтобы «пустые» не торчали
		for c in btn.get_signal_connection_list("pressed"):
			btn.disconnect("pressed", c.callable)
		btn.text = ""
		btn.disabled = true
		btn.visible = false
		btn.modulate = Color(1,1,1)
		btn.set_meta("skill", null)

		# включаем только если есть соответствующий скилл
		if i >= skills.size() or typeof(skills[i]) != TYPE_DICTIONARY:
			continue

		var skill: Dictionary = skills[i]
		btn.text = _compose_btn_caption(skill)
		btn.visible = true
		btn.set_meta("skill", skill)

		# доступность по стоимости
		var can_use := true
		var battle := get_tree().current_scene
		if battle and battle.has_method("_can_pay_cost"):
			can_use = bool(battle.call("_can_pay_cost", hero, skill))
		btn.disabled = not can_use

		# подсветки
		if String(hero.nick) == "Berit":
			_apply_enhance_highlight(btn, _can_enhance(hero, skill))
		elif String(hero.nick) == "Sally":
			btn.modulate = _sally_tint_for_skill(hero, skill)

		# описание и клик
		_hook_hover_for_desc(btn)
		btn.connect("pressed", Callable(self, "_on_skill_pressed").bind(skill))

func _on_skill_index(i: int) -> void:
	if current_hero == null: return
	var skills: Array = current_hero.abilities
	if i >= 0 and i < skills.size():
		var skill: Dictionary = skills[i]
		emit_signal("action_selected", "skill", current_hero, skill)

func _on_skill_pressed(skill_data: Dictionary):
	emit_signal("action_selected", "skill", current_hero, skill_data)

# ---------- items ----------
func update_item_buttons():
	var max_buttons := 0
	for child in ItemMenuContainer.get_children():
		if child is Button and String(child.name).begins_with("ItemButton"):
			var b: Button = child
			max_buttons += 1
			b.visible = false
			b.disabled = true
			for c in b.get_signal_connection_list("pressed"):
				b.disconnect("pressed", c.callable)

	if current_hero == null: return

	var ids = current_hero.pack.keys()
	var index := 1
	for id in ids:
		if index > max_buttons: break
		var cnt := int(current_hero.pack[id]); if cnt <= 0: continue
		var def := GameManager.get_item_def(id); if def.is_empty(): continue
		var cat := String(def.get("category",""))
		if current_hero.forbidden_categories.has(cat): continue

		var button_path = "ItemMenuContainer/ItemButton%d" % index
		if has_node(button_path):
			var btn: Button = get_node(button_path)
			var nm := String(def.get("name", id))
			btn.text = "%s x%d" % [nm, cnt]
			btn.visible = true
			btn.disabled = false
			btn.connect("pressed", Callable(self, "_on_item_pressed").bind(id))
			index += 1

func _on_item_pressed(item_key: String):
	emit_signal("action_selected", "item", current_hero, item_key)
