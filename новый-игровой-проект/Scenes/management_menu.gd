extends PopupPanel

# ================== DEBUG ==================
const DBG := true
func _dbg(msg: String) -> void:
	if DBG: print("[MGMT][DBG] ", msg)

func _refresh_archive() -> void:
	if archive_cats:
		archive_cats.clear()
	if archive_entries:
		archive_entries.clear()
	if archive_text:
		archive_text.text = ""     # раньше bbcode_text
	if archive_image:
		archive_image.texture = null

	var cats := GameManager.get_archive_categories()
	for c in cats:
		if archive_cats:
			var i := archive_cats.add_item(String(c))
			archive_cats.set_item_metadata(i, String(c))

	# авто-выбор 1-й категории
	if archive_cats and archive_cats.item_count > 0:
		archive_cats.select(0)
		_on_archive_cat_selected(0)

func _on_archive_cat_selected(i: int) -> void:
	if not archive_cats: return
	var cat := String(archive_cats.get_item_metadata(i))
	if archive_entries:
		archive_entries.clear()
	var entries := GameManager.get_archive_entries(cat)
	for e in entries:
		var title := String(e.get("title","Запись"))
		var idx := archive_entries.add_item(title)
		archive_entries.set_item_metadata(idx, e)
	# авто-выбор 1-й записи
	if archive_entries and archive_entries.item_count > 0:
		archive_entries.select(0)
		_on_archive_entry_selected(0)

func _on_archive_entry_selected(i: int) -> void:
	if not archive_entries: return
	var ed: Dictionary = archive_entries.get_item_metadata(i)
	var title := String(ed.get("title","Запись"))
	var text  := String(ed.get("text",""))
	archive_text.text = "[b]%s[/b]\n\n%s" % [title, text]   # раньше bbcode_text

	# картинка
	if archive_image:
		archive_image.texture = null
		var img_name := String(ed.get("image",""))
		if img_name != "":
			var path := GameManager.get_archive_image_path(img_name)
			if ResourceLoader.exists(path):
				var tex := ResourceLoader.load(path)
				if tex and tex is Texture2D:
					archive_image.texture = tex


func _dump_refs() -> void:
	var refs := {
		"tabs": tabs,
		"base_list": base_list,
		"move_count": move_count,
		"to_hero_btn": to_hero_btn,
		"to_base_btn": to_base_btn,
		"heroes_drop": heroes_drop,
		"hero_stats": hero_stats,
		"hero_list": hero_list,
		"item_info": item_info,
		"eq_drop": eq_drop,
		"eq_stats": eq_stats,
		"eq_list": eq_list,
		"quest_list": quest_list,
		"quest_info": quest_info,

		"archive_text": archive_text,
		"close_btn": close_btn
	}
	for k in refs.keys():
		var n: Node = refs[k]
		_dbg("%s -> %s  (valid=%s)" % [k, (n.get_path() if n else "NULL"), str(is_instance_valid(n))])
		
func _refresh_quests() -> void:
	quest_list.clear()
	quest_info.text = ""
	var arr := GameManager.get_sorted_quests()
	if arr.is_empty():
		var i := quest_list.add_item("Активных заданий нет")
		quest_list.set_item_selectable(i, false)
		return

	for q in arr:
		var name := String(q.get("name","Квест"))
		var i := quest_list.add_item(name)
		quest_list.set_item_metadata(i, q)
		if bool(q.get("completed", false)):
			quest_list.set_item_custom_fg_color(i, Color(0.6, 0.6, 0.6))

	if not quest_list.item_selected.is_connected(_on_quest_selected):
		quest_list.item_selected.connect(_on_quest_selected)

func _on_quest_selected(i: int) -> void:
	var qd: Dictionary = quest_list.get_item_metadata(i)
	var title := String(qd.get("name","Квест"))
	var desc  := String(qd.get("desc",""))
	var done  := bool(qd.get("completed", false))
	var status := ""
	if done:
		status = "\n[color=gray](завершено)[/color]"

	# красивые награды
	var r = qd.get("rewards", {})
	var reward_lines := []
	if typeof(r) == TYPE_DICTIONARY:
		var k := int(r.get("krestli", 0))
		if k > 0:
			reward_lines.append("Крестли: %d" % k)
		var items: Array = r.get("items", [])
		if typeof(items) == TYPE_ARRAY and items.size() > 0:
			var parts := []
			for e in items:
				if typeof(e) != TYPE_DICTIONARY:
					continue
				var iid := String(e.get("id",""))
				var cnt := int(e.get("count",0))
				if iid != "" and cnt > 0:
					parts.append("%s ×%d" % [GameManager.item_title(iid), cnt])
			if parts.size() > 0:
				reward_lines.append("Предметы: " + ", ".join(parts))
	var rewards_bb := ""
	if reward_lines.size() > 0:
		rewards_bb = "\n[b]Награда:[/b] " + "\n".join(reward_lines)

	quest_info.text = "[b]%s[/b]%s\n\n%s%s" % [title, status, desc, rewards_bb]  # раньше bbcode_text


func _dump_base(prefix := "BASE") -> void:
	_dbg("%s: %d items total" % [prefix, GameManager.base_inventory.size()])
	for id in GameManager.base_inventory.keys():
		_dbg("  • %s ×%d" % [String(id), int(GameManager.base_inventory[id])])

func _dump_hero(hero: String, prefix := "HERO") -> void:
	var d: Dictionary = GameManager.all_heroes.get(hero, {})
	var pack: Array = d.get("pack", [])
	_dbg("%s %s pack: %d entries" % [prefix, hero, pack.size()])
	for e in pack:
		_dbg("  • %s ×%d" % [String(e.get("id","")), int(e.get("count",0))])

# ================== UI refs ==================
@onready var tabs: TabContainer      = %Tabs

# Inventory tab
@onready var base_list: ItemList     = %BaseList
@onready var move_count: SpinBox     = %MoveCount
@onready var to_hero_btn: Button     = %ToHeroButton
@onready var to_base_btn: Button     = %ToBaseButton
@onready var heroes_drop: OptionButton = %HeroesDrop
@onready var hero_stats: Label       = %HeroStats
@onready var hero_list: ItemList     = %HeroList
@onready var item_info: RichTextLabel= %ItemInfo

# Equipment tab
@onready var eq_drop: OptionButton   = %EqHeroesDrop
@onready var eq_stats: Label         = %EqHeroStats
@onready var eq_list: ItemList       = %EqHeroList

# Quests / Archive
@onready var quest_list: ItemList    = %QuestList
@onready var quest_info: RichTextLabel = %QuestInfo

@onready var archive_text: RichTextLabel = %ArchiveText

@onready var close_btn: Button       = %CloseButton

# --- Equipment / Skills ---
@onready var skills_all: ItemList      = %SkillsAllList
@onready var skills_eq: ItemList       = %SkillsEqList
@onready var skill_info: RichTextLabel = %SkillInfo
@onready var equip_btn: Button         = %EquipSkillButton
@onready var unequip_btn: Button       = %UnequipSkillButton
#@onready var eq_msg: Label             = %EqMsg # может не существовать — ок

# Archive UI (добавь в сцену, см. ниже)
@onready var archive_cats: ItemList   = %ArchiveCategories   # ЛЕВЫЙ список категорий
@onready var archive_entries: ItemList= %ArchiveEntries      # ПРАВЫЙ список записей
@onready var archive_image: TextureRect = %ArchiveImage      # Картинка записи

@onready var sup_cats:  ItemList      = %SupCats
@onready var sup_list:  ItemList      = %SupList
@onready var sup_info:  RichTextLabel = %SupInfo
@onready var sup_image: TextureRect   = %SupImage

# --- Augments tab ---
@onready var aug_drop: OptionButton   = %AugHeroesDrop
@onready var aug_points: Label        = %AugPointsLabel
@onready var aug_etheria: Label       = %AugEtheriaLabel
@onready var aug_add_cap: Button      = %AugAddCapButton
@onready var aug_tree: Tree           = %AugTree
@onready var aug_desc: RichTextLabel  = %AugDesc


# ================== lifecycle ==================
func _ready() -> void:
	_dbg("=== ManagementMenu READY ===")
	_dump_refs()

	_dbg("party_names: %s" % [GameManager.party_names])
	_dump_base("BASE (before UI)")
	for h in GameManager.party_names:
		_dump_hero(h, "HERO (before UI)")

	_fill_heroes(heroes_drop)
	_fill_heroes(eq_drop)

	_refresh_base()
	_on_hero_changed_inventory(0)
	_refresh_eq_tab()

	if not heroes_drop.item_selected.is_connected(_on_hero_changed_inventory):
		heroes_drop.item_selected.connect(_on_hero_changed_inventory); _dbg("connect heroes_drop.item_selected")

	if not to_hero_btn.pressed.is_connected(_on_move_to_hero):
		to_hero_btn.pressed.connect(_on_move_to_hero); _dbg("connect to_hero_btn.pressed")

	if not to_base_btn.pressed.is_connected(_on_move_to_base):
		to_base_btn.pressed.connect(_on_move_to_base); _dbg("connect to_base_btn.pressed")

	if not base_list.item_selected.is_connected(_on_base_item_selected):
		base_list.item_selected.connect(_on_base_item_selected); _dbg("connect base_list.item_selected")

	if not hero_list.item_selected.is_connected(_on_hero_item_selected):
		hero_list.item_selected.connect(_on_hero_item_selected); _dbg("connect hero_list.item_selected")

# сигналы от GM
	if GameManager.has_signal("quests_changed") and not GameManager.quests_changed.is_connected(_refresh_quests):
		GameManager.quests_changed.connect(_refresh_quests)
	if GameManager.has_signal("archive_changed") and not GameManager.archive_changed.is_connected(_refresh_archive):
		GameManager.archive_changed.connect(_refresh_archive)
		
		# Включаем BBCode на тексте
	if quest_info: quest_info.bbcode_enabled = true
	if archive_text: archive_text.bbcode_enabled = true
	if item_info:     item_info.bbcode_enabled = true

	# клики архивных списков
	if archive_cats and not archive_cats.item_selected.is_connected(_on_archive_cat_selected):
		archive_cats.item_selected.connect(_on_archive_cat_selected)
	if archive_entries and not archive_entries.item_selected.is_connected(_on_archive_entry_selected):
		archive_entries.item_selected.connect(_on_archive_entry_selected)


	# первичная отрисовка
	_refresh_quests()
	_refresh_archive()

	if not close_btn.pressed.is_connected(_on_close_pressed):
		close_btn.pressed.connect(_on_close_pressed); _dbg("connect close_btn.pressed")
	if not base_list.item_activated.is_connected(func(_i): _on_move_to_hero()):
		base_list.item_activated.connect(func(_i): _on_move_to_hero())
	if not hero_list.item_activated.is_connected(func(_i): _on_move_to_base()):
		hero_list.item_activated.connect(func(_i): _on_move_to_base())
	
	# --- skills wires ---
	if skills_all:
		skills_all.item_selected.connect(_on_skill_selected_all)
		skills_all.item_activated.connect(func(_i): _equip_selected())
	if skills_eq:
		skills_eq.item_selected.connect(_on_skill_selected_eq)
		skills_eq.item_activated.connect(func(_i): _unequip_selected())
	if equip_btn: equip_btn.pressed.connect(_equip_selected)
	if unequip_btn: unequip_btn.pressed.connect(_unequip_selected)
	
	# Supplies signals
	if GameManager.has_signal("supplies_changed") and not GameManager.supplies_changed.is_connected(_refresh_supplies):
		GameManager.supplies_changed.connect(_refresh_supplies)

	if sup_cats and not sup_cats.item_selected.is_connected(_on_sup_cat_selected):
		sup_cats.item_selected.connect(_on_sup_cat_selected)
	if sup_list and not sup_list.item_selected.is_connected(_on_sup_item_selected):
		sup_list.item_selected.connect(_on_sup_item_selected)

	# первичный вывод
	_refresh_supplies()
	
	# заголовки дерева
	if aug_tree:
		aug_tree.hide_root = true
		aug_tree.columns = 3
		aug_tree.set_column_titles_visible(true)
		aug_tree.set_column_title(0, "Вкл")
		aug_tree.set_column_title(1, "Аугмент")
		aug_tree.set_column_title(2, "СТ")

	# заполнить героев
	if aug_drop:
		aug_drop.clear()
		for n in GameManager.party_names:
			aug_drop.add_item(n)
		if aug_drop.item_count > 0:
			aug_drop.select(0)

	# сигналы
	if aug_drop and not aug_drop.item_selected.is_connected(_on_aug_hero_changed):
		aug_drop.item_selected.connect(_on_aug_hero_changed)
	if aug_tree:
		if not aug_tree.item_selected.is_connected(_on_aug_item_selected):
			aug_tree.item_selected.connect(_on_aug_item_selected)
		if not aug_tree.item_edited.is_connected(_on_aug_item_edited):
			aug_tree.item_edited.connect(_on_aug_item_edited)
	if aug_add_cap and not aug_add_cap.pressed.is_connected(_on_aug_add_cap):
		aug_add_cap.pressed.connect(_on_aug_add_cap)

	# реакция на глобальные изменения
	if GameManager.has_signal("augments_changed") \
	and not GameManager.augments_changed.is_connected(_refresh_aug_tab):
		GameManager.augments_changed.connect(_refresh_aug_tab, Object.CONNECT_DEFERRED)

	# первичная отрисовка
	_refresh_aug_tab()



func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		_dbg("ESC -> hide()")
		hide()

func open_centered() -> void:
	show()
	await get_tree().process_frame
	var vr := Vector2i(1600, 900)
	position = Vector2i((vr.x - size.x) / 2, (vr.y - size.y) / 2)
	grab_focus()

func _on_close_pressed() -> void:
	_dbg("Close button -> hide()")
	hide()

# ================== helpers ==================
func _item_title(id: String) -> String:
	var def := GameManager.get_item_def(id)
	var title := String(def.get("name", id))
	if def.is_empty():
		_dbg("[WARN] item def not found for id='%s'" % id)
	return title

func _fill_heroes(drop: OptionButton) -> void:
	drop.clear()
	for n in GameManager.party_names:
		drop.add_item(n)
	if drop.item_count > 0:
		drop.select(0)
	_dbg("fill_heroes(%s): count=%d, selected=%d ('%s')" %
		[drop.get_path(), drop.item_count, drop.get_selected(), _cur_hero_name(drop)])

func _cur_hero_name(drop: OptionButton) -> String:
	if drop.item_count == 0: return ""
	var idx := drop.get_selected()
	if idx < 0: idx = 0
	return drop.get_item_text(idx)

func _hero_pack(hero: String) -> Array:
	var d: Dictionary = GameManager.all_heroes.get(hero, {})
	return (d.get("pack", []) if d.has("pack") else [])

func _set_hero_pack(hero: String, pack: Array) -> void:
	var d: Dictionary = GameManager.all_heroes.get(hero, {})
	d["pack"] = pack
	GameManager.all_heroes[hero] = d

func _pack_add(hero: String, id: String, cnt: int) -> void:
	var p := _hero_pack(hero)
	var found := false
	for e in p:
		if String(e.get("id","")) == id:
			e["count"] = int(e.get("count",0)) + cnt
			found = true
			break
	if not found:
		p.append({"id": id, "count": cnt})
	_set_hero_pack(hero, p)

func _pack_take(hero: String, id: String, cnt: int) -> int:
	var p := _hero_pack(hero)
	var left := cnt
	for e in p:
		if String(e.get("id","")) == id:
			var have := int(e.get("count",0))
			var take = min(left, have)
			e["count"] = have - take
			left -= take
	var cleaned: Array = []
	for e in p:
		if int(e.get("count",0)) > 0:
			cleaned.append(e)
	_set_hero_pack(hero, cleaned)
	return cnt - left

# ================== draw lists ==================
func _refresh_base() -> void:
	base_list.clear()
	var keys := GameManager.base_inventory.keys()
	keys.sort()
	var added := 0
	for id in keys:
		var cnt := int(GameManager.base_inventory[id])
		if cnt <= 0: continue
		var txt := "%s ×%d" % [_item_title(String(id)), cnt]
		var i := base_list.add_item(txt)
		base_list.set_item_metadata(i, String(id))
		added += 1
	_dbg("refresh_base: added=%d (from %d keys)" % [added, keys.size()])
	item_info.text = ""
	# NEW: авто-выбор первой строки, если есть
	if base_list.item_count > 0:
		base_list.select(0)

func _refresh_hero_bag(drop: OptionButton, list: ItemList) -> void:
	list.clear()
	var h := _cur_hero_name(drop)
	if h == "":
		_dbg("refresh_hero_bag: hero not selected")
		return
	var bag := _hero_pack(h)
	var rows: Array = []
	for e in bag:
		var id := String(e.get("id",""))
		var cnt := int(e.get("count",0))
		if cnt <= 0: continue
		rows.append({"id": id, "cnt": cnt, "title": _item_title(id)})
	rows.sort_custom(func(a, b): return String(a["title"]) < String(b["title"]))
	for r in rows:
		var txt := "%s ×%d" % [r["title"], r["cnt"]]
		var i := list.add_item(txt)
		list.set_item_metadata(i, String(r["id"]))
	_dbg("refresh_hero_bag('%s'): rows=%d" % [h, rows.size()])
	# NEW: авто-выбор первой строки
	if list.item_count > 0:
		list.select(0)


func _refresh_hero_stats(label: Label, hero_name: String) -> void:
	if not GameManager.all_heroes.has(hero_name):
		label.text = ""; _dbg("stats: hero '%s' not found in all_heroes" % hero_name); return
	var d: Dictionary = GameManager.all_heroes[hero_name]
	var hp := int(d.get("max_health", d.get("max_hp", 100)))
	var mp := int(d.get("max_mana", 0))
	var atk:= int(d.get("attack", 10))
	var spd:= int(d.get("speed", 10))
	label.text = "HP: %d   MP: %d   ATK: %d   SPD: %d" % [hp, mp, atk, spd]
	_dbg("stats('%s'): %s" % [hero_name, label.text])

# ================== inventory tab: events ==================
func _on_hero_changed_inventory(_idx: int) -> void:
	var h := _cur_hero_name(heroes_drop)
	_dbg("hero_changed_inventory -> '%s'" % h)
	_refresh_hero_stats(hero_stats, h)
	_refresh_hero_bag(heroes_drop, hero_list)

func _on_move_to_hero() -> void:
	var sel := base_list.get_selected_items()
	if sel.is_empty():
		_dbg("move_to_hero: nothing selected in base_list"); return
	var id := String(base_list.get_item_metadata(sel[0]))
	var want = max(1, int(move_count.value))
	var have := int(GameManager.base_inventory.get(id, 0))
	var moved = min(want, have)
	var hero := _cur_hero_name(heroes_drop)
	_dbg("move_to_hero: id=%s want=%d have=%d hero=%s -> moved=%d" % [id, want, have, hero, moved])
	if moved <= 0: return
	GameManager.base_inventory[id] = have - moved
	if hero != "":
		_pack_add(hero, id, moved)
	_dump_base("BASE (after →hero)")
	_dump_hero(hero, "HERO (after ←base)")
	_refresh_base()
	_refresh_hero_bag(heroes_drop, hero_list)

func _on_move_to_base() -> void:
	var sel := hero_list.get_selected_items()
	if sel.is_empty():
		_dbg("move_to_base: nothing selected in hero_list"); return
	var id := String(hero_list.get_item_metadata(sel[0]))
	var want = max(1, int(move_count.value))
	var hero := _cur_hero_name(heroes_drop)
	var moved := _pack_take(hero, id, want)
	_dbg("move_to_base: id=%s want=%d hero=%s -> moved=%d" % [id, want, hero, moved])
	if moved <= 0: return
	GameManager.base_inventory[id] = int(GameManager.base_inventory.get(id, 0)) + moved
	_dump_hero(hero, "HERO (after →base)")
	_dump_base("BASE (after ←hero)")
	_refresh_base()
	_refresh_hero_bag(heroes_drop, hero_list)

func _on_base_item_selected(i: int) -> void:
	var id := String(base_list.get_item_metadata(i))
	_dbg("select base item #%d -> id=%s" % [i, id])
	_show_item_info(id)

func _on_hero_item_selected(i: int) -> void:
	var id := String(hero_list.get_item_metadata(i))
	_dbg("select hero item #%d -> id=%s" % [i, id])
	_show_item_info(id)

func _show_item_info(id: String) -> void:
	var def := GameManager.get_item_def(id)
	if typeof(def) != TYPE_DICTIONARY or def.is_empty():
		item_info.text = "[b]%s[/b]\nописание отсутствует" % id
		_dbg("item info: id=%s (no def)" % id)
		return
	var nm := String(def.get("name", id))
	var desc := String(def.get("desc", def.get("description", "")))
	item_info.text = "[b]%s[/b]\n%s" % [nm, desc]
	_dbg("item info: id=%s title='%s'" % [id, nm])
	
func _refresh_skill_lists(hero: String) -> void:
	if not skills_all or not skills_eq: return
	skills_all.clear()
	skills_eq.clear()
	if skill_info: skill_info.text = ""

	var all := GameManager.get_hero_skills(hero)
	all.sort_custom(func(a, b):
		return String((a as Dictionary).get("name","")) < String((b as Dictionary).get("name",""))
	)
	for s in all:
		var nm := String(s.get("name",""))
		var i := skills_all.add_item(nm)
		skills_all.set_item_metadata(i, nm)

	var eq_ids := GameManager.get_equipped_skill_ids(hero)
	for sid in eq_ids:
		var i2 := skills_eq.add_item(String(sid))
		skills_eq.set_item_metadata(i2, String(sid))

func _fmt_skill(def: Dictionary) -> String:
	if typeof(def) != TYPE_DICTIONARY or def.is_empty():
		return ""

	var nm  := str(def.get("name", "Skill"))
	var typ := str(def.get("type", ""))
	var tgt := str(def.get("target", ""))
	var cost = def.get("costs", {})
	var parts: Array = []

	if typeof(cost) == TYPE_DICTIONARY and not (cost as Dictionary).is_empty():
		for k in cost.keys():
			parts.append("%s:%s" % [str(k), str(cost[k])])

	var cost_str := "-"
	if not parts.is_empty():
		cost_str = ", ".join(parts)

	var desc := str(def.get("desc", def.get("description", "")))

	var tgt_str := "?"
	if tgt != "":
		tgt_str = tgt

	return "[b]%s[/b]  [i](%s)[/i]  → %s\n[b]Cost:[/b] %s\n%s" % [nm, typ, tgt_str, cost_str, desc]


func _on_skill_selected_all(i: int) -> void:
	var hero := _cur_hero_name(eq_drop)
	var id := String(skills_all.get_item_metadata(i))
	var def := GameManager.get_skill_def(hero, id)
	if skill_info: skill_info.text = _fmt_skill(def)

func _on_skill_selected_eq(i: int) -> void:
	var hero := _cur_hero_name(eq_drop)
	var id := String(skills_eq.get_item_metadata(i))
	var def := GameManager.get_skill_def(hero, id)
	if skill_info: skill_info.text = _fmt_skill(def)

func _equip_selected() -> void:
	var hero := _cur_hero_name(eq_drop)
	if hero == "" or not skills_all: return
	var sel := skills_all.get_selected_items()
	if sel.is_empty(): return
	var id := String(skills_all.get_item_metadata(sel[0]))
	var ok := GameManager.equip_skill(hero, id)
	_refresh_skill_lists(hero)

func _unequip_selected() -> void:
	var hero := _cur_hero_name(eq_drop)
	if hero == "" or not skills_eq: return
	var sel := skills_eq.get_selected_items()
	if sel.is_empty(): return
	var id := String(skills_eq.get_item_metadata(sel[0]))
	GameManager.unequip_skill(hero, id)
	_refresh_skill_lists(hero)


# ================== equipment tab ==================
func _refresh_eq_tab() -> void:
	var h := _cur_hero_name(eq_drop)
	_refresh_hero_stats(eq_stats, h)
	_refresh_hero_bag(eq_drop, eq_list)
	_refresh_skill_lists(h)

func _on_eq_hero_changed(_idx: int) -> void:
	_refresh_eq_tab()

func _refresh_supplies() -> void:
	if sup_cats: sup_cats.clear()
	if sup_list: sup_list.clear()
	if sup_info: sup_info.text = ""
	if sup_image: sup_image.texture = null

	# категории только с наличием (не пустые)
	var cats := GameManager.get_supply_categories(false)
	for c in cats:
		var i := sup_cats.add_item(GameManager.supply_category_title(String(c)))
		sup_cats.set_item_metadata(i, String(c))

	# авто-выбор первой категории
	if sup_cats and sup_cats.item_count > 0:
		sup_cats.select(0)
		_on_sup_cat_selected(0)

func _on_sup_cat_selected(i: int) -> void:
	if not sup_cats: return
	var cat := String(sup_cats.get_item_metadata(i))
	if sup_list: sup_list.clear()
	if sup_info: sup_info.text = ""
	if sup_image: sup_image.texture = null

	var rows := GameManager.get_supply_entries(cat)
	for r in rows:
		var txt := "%s ×%d" % [String(r["title"]), int(r["count"])]
		var idx := sup_list.add_item(txt)
		sup_list.set_item_metadata(idx, r)

	# авто-выбор первого предмета
	if sup_list and sup_list.item_count > 0:
		sup_list.select(0)
		_on_sup_item_selected(0)

func _on_sup_item_selected(i: int) -> void:
	if not sup_list: return
	var r: Dictionary = sup_list.get_item_metadata(i)
	var title := String(r.get("title",""))
	var desc  := String(r.get("desc",""))
	if sup_info:
		sup_info.bbcode_enabled = true
		sup_info.text = "[b]%s[/b]\n\n%s" % [title, desc]
	if sup_image:
		sup_image.texture = null
		var icon_path := String(r.get("icon",""))
		if icon_path != "" and ResourceLoader.exists(icon_path):
			var t := ResourceLoader.load(icon_path)
			if t is Texture2D:
				sup_image.texture = t


func _cur_aug_hero() -> String:
	if not aug_drop or aug_drop.item_count == 0:
		return ""
	var idx := aug_drop.get_selected()
	if idx < 0: idx = 0
	return aug_drop.get_item_text(idx)

func _refresh_aug_points_ui(hero: String) -> void:
	if not aug_points or not aug_etheria: return
	var used := GameManager.hero_ether_used(hero)
	var cap  := GameManager.get_hero_ether_cap(hero)
	aug_points.text = "Очки: %d / %d" % [used, cap]
	aug_etheria.text = "Эфирия: %d" % GameManager.get_etheria()
	if aug_add_cap:
		aug_add_cap.disabled = (GameManager.get_etheria() <= 0)

func _refresh_aug_tree(hero: String) -> void:
	if not aug_tree: return
	aug_tree.clear()

	# создавать root НУЖНО ровно один раз перед добавлением детей
	var root := aug_tree.create_item()
	if root == null:
		return # на всякий случай, но с hide_root=true всё ок

	var active: Array = GameManager.get_hero_active_augments(hero)
	for id in GameManager.get_unlocked_augments():
		var item := aug_tree.create_item(root)
		if item == null: 
			continue

		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		item.set_editable(0, true)
		item.set_checked(0, active.has(id))
		item.set_selectable(0, true)

		item.set_text(1, GameManager.augment_title(id))
		item.set_text(2, str(GameManager.augment_cost(id)))

		# хранить id достаточно в одной колонке (например в 0-й)
		item.set_metadata(0, id)



func _refresh_aug_tab() -> void:
	var hero := _cur_aug_hero()
	if hero == "":
		return
	_refresh_aug_points_ui(hero)
	_refresh_aug_tree(hero)
	if aug_desc:
		aug_desc.bbcode_enabled = true
		aug_desc.text = ""

func _on_aug_hero_changed(_i: int) -> void:
	_refresh_aug_tab()

func _on_aug_item_selected() -> void:
	if aug_tree == null: return
	var item := aug_tree.get_selected()
	if item == null: return
	var id := str(item.get_metadata(0))  # было: String(..., 1)

	var def  := GameManager.get_augment_def(id)
	var nm   := str(def.get("name", id))
	var desc := str(def.get("desc", ""))
	var cost := int(def.get("cost", 0))
	if aug_desc:
		aug_desc.bbcode_enabled = true
		aug_desc.text = "[b]%s[/b]  [i](СТ: %d)[/i]\n\n%s" % [nm, cost, desc]


func _on_aug_item_edited() -> void:
	if aug_tree == null:
		return

	var item := aug_tree.get_edited()
	if item == null:
		return

	var col := aug_tree.get_edited_column()
	if col != 0:
		return  # реагируем только на колонку с чекбоксом

	var hero := _cur_aug_hero()
	if hero == "":
		return

	var id := str(item.get_metadata(0))
	var want_on := item.is_checked(0)

	var ok := GameManager.set_hero_augment(hero, id, want_on)
	if not ok:
		# вернуть визуально старое значение (не хватило очков и т.д.)
		item.set_checked(0, not want_on)

	# Обновляем только счётчики, без полной перерисовки дерева
	_refresh_aug_points_ui(hero)


func _on_aug_add_cap() -> void:
	var hero := _cur_aug_hero()
	if hero == "": return
	if GameManager.spend_etheria_to_increase_cap(hero):
		_refresh_aug_tab()
