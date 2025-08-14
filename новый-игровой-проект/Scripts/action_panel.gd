extends PanelContainer

signal action_selected(action_type: String, actor: Node2D, data)

var current_hero: Node2D

@onready var MainMenuContainer  = $MainMenuContainer
@onready var SkillMenuContainer = $SkillMenuContainer
@onready var ItemMenuContainer  = $ItemMenuContainer

signal item_chosen(user, item_id)

# Подготовка при показе
func show_main_menu(hero: Node2D):
	current_hero = hero
	visible = true
	MainMenuContainer.visible = true
	SkillMenuContainer.visible = false
	ItemMenuContainer.visible = false
	update_skill_buttons_for(hero)
	update_item_buttons()

# ——————— ОСНОВНЫЕ КНОПКИ ———————
func _on_AttackButton_pressed():
	emit_signal("action_selected", "attack", current_hero, null)

func _on_SkillButton_pressed():
	MainMenuContainer.visible = false
	SkillMenuContainer.visible = true

func _on_ItemButton_pressed():
	MainMenuContainer.visible = false
	ItemMenuContainer.visible = true

func _on_SkipButton_pressed():
	emit_signal("action_selected", "skip", current_hero, null)

# ——————— НАЗАД ИЗ ПОДМЕНЮ ———————
func _on_BackButton_pressed():
	MainMenuContainer.visible = true
	SkillMenuContainer.visible = false
	ItemMenuContainer.visible = false

func _on_BackButton2_pressed():
	MainMenuContainer.visible = true
	ItemMenuContainer.visible = false

# ——————— УМЕНИЯ ———————
func update_skill_buttons_for(hero: Node2D):
	var skills = hero.abilities
	for i in range(6):
		var path = "SkillMenuContainer/SkillButton%d" % (i+1)
		if not has_node(path): continue
		var btn: Button = get_node(path)

		# снять старые коннекты
		for c in btn.get_signal_connection_list("pressed"):
			btn.disconnect("pressed", c.callable)

		if i < skills.size():
			var skill = skills[i]
			btn.text = str(skill.get("name","Skill"))
			btn.visible = true
			# спросим у Battle, хватает ли ресурсов
			var can_use := true
			if get_tree():
				var battle := get_tree().current_scene  # или путь до Battle
				if battle and battle.has_method("_can_pay_cost"):
					can_use = bool(battle.call("_can_pay_cost", hero, skill))
			btn.disabled = not can_use
			btn.connect("pressed", Callable(self, "_on_skill_pressed").bind(skill))
		else:
			btn.visible = false

func _on_skill_index(i: int) -> void:
	if current_hero == null:
		return
	var skills: Array = current_hero.abilities
	if i >= 0 and i < skills.size():
		var skill: Dictionary = skills[i]
		emit_signal("action_selected", "skill", current_hero, skill)

func _on_skill_pressed(skill_data: Dictionary):
	emit_signal("action_selected", "skill", current_hero, skill_data)


# ——————— ПРЕДМЕТЫ ———————
func update_item_buttons():
	# Сначала подчистим все кнопки списка предметов
	var max_buttons := 0
	for child in ItemMenuContainer.get_children():
		if child is Button and String(child.name).begins_with("ItemButton"):
			var b: Button = child
			max_buttons += 1
			b.visible = false
			b.disabled = true
			for c in b.get_signal_connection_list("pressed"):
				b.disconnect("pressed", c.callable)

	if current_hero == null:
		return

	# Разложим содержимое рюкзака героя
	var ids = current_hero.pack.keys()
	var index := 1
	for id in ids:
		if index > max_buttons:
			break
		var cnt := int(current_hero.pack[id])
		if cnt <= 0:
			continue
		var def := GameManager.get_item_def(id)
		if def.is_empty():
			continue
		# фильтр по запретным категориям
		var cat := String(def.get("category",""))
		if current_hero.forbidden_categories.has(cat):
			continue

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
