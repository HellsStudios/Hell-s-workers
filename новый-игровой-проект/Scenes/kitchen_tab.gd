extends Control

@onready var list_recipes: ItemList   = %RecipeList
@onready var spin_portions: SpinBox   = %Portions
@onready var need_label: RichTextLabel= %NeedLabel
@onready var btn_cook: Button         = %CookButton

@onready var batch_info: Label        = %BatchInfo
@onready var grid: GridContainer      = %AssignGrid
@onready var spin_store: SpinBox      = %StoreSpin
@onready var btn_serve: Button        = %ServeButton


var _hero_names: Array = []

@export var target_size: Vector2i = Vector2i(720, 320)

@onready var cont_drop: OptionButton = %FridgeDrop
@onready var cont_take_spin: SpinBox = %FridgeTakeSpin
@onready var cont_take_btn: Button = %FridgeTakeButton

func refresh_all() -> void:
	_fill_recipe_list()
	_refresh_recipe_preview()
	_refresh_batch_ui()
	_refresh_fridge_ui()


func focus_default() -> void:
	if list_recipes:
		list_recipes.grab_focus()

var _embedded_mode := false
func set_embedded(mode: bool = true) -> void:
	_embedded_mode = mode

func _refresh_fridge_ui() -> void:
	if cont_drop:
		cont_drop.clear()
	var have_any := false

	var keys := GameManager.container_all().keys()
	keys.sort()

	for k in keys:
		var meal_id := String(k)
		var cnt := GameManager.container_count(meal_id)
		if cnt <= 0:
			continue

		var title := String(GameManager.get_recipe_def(meal_id).get("name", meal_id))
		cont_drop.add_item("%s (%d)" % [title, cnt])
		var idx := cont_drop.item_count - 1  # add_item() ничего не возвращает

		# метаданные — прямым методом или через popup (и то, и другое бывает)
		if cont_drop.has_method("set_item_metadata"):
			cont_drop.set_item_metadata(idx, meal_id)
		else:
			cont_drop.get_popup().set_item_metadata(idx, meal_id)

		have_any = true

	if cont_take_btn:
		cont_take_btn.disabled = not have_any

	if cont_take_spin:
		cont_take_spin.min_value = 0
		cont_take_spin.max_value = 0
		cont_take_spin.value = 0

	if have_any and cont_drop:
		cont_drop.select(0)
		_on_cont_drop_selected(0)

func _on_cont_drop_selected(_i: int) -> void:
	if not cont_drop or not cont_take_spin:
		return
	var idx := cont_drop.get_selected()
	if idx < 0: idx = 0

	var meal_id := ""
	if cont_drop.has_method("get_item_metadata"):
		meal_id = String(cont_drop.get_item_metadata(idx))
	else:
		meal_id = String(cont_drop.get_popup().get_item_metadata(idx))

	var max := GameManager.container_count(meal_id)
	cont_take_spin.min_value = (1 if max > 0 else 0)
	cont_take_spin.max_value = max
	if cont_take_spin.value > max:
		cont_take_spin.value = max

func _cur_fridge_meal_id() -> String:
	if not cont_drop or cont_drop.item_count == 0:
		return ""
	var idx := cont_drop.get_selected()
	if idx < 0: idx = 0
	var meta
	if cont_drop.has_method("get_item_metadata"):
		meta = cont_drop.get_item_metadata(idx)
	else:
		meta = cont_drop.get_popup().get_item_metadata(idx)
	return String(meta)


func _on_cont_take_pressed() -> void:
	var id := _cur_fridge_meal_id()
	if id == "" or not cont_take_spin:
		return
	var n := int(cont_take_spin.value)
	if n <= 0:
		return
	if GameManager.activate_from_container(id, n):
		var title := String(GameManager.get_recipe_def(id).get("name", id))
		Toasts.ok("Активировано: %s ×%d" % [title, n])
		_refresh_batch_ui()
		_refresh_fridge_ui()
	else:
		Toasts.warn("Нельзя достать из контейнера: уже активна партия или не хватает порций.")



func open_from(screen_pos: Vector2i, dur := 0.25) -> void:
	position = screen_pos
	size = Vector2i(0, 0)
	show()
	var tw := create_tween()
	tw.tween_property(self, "size", target_size, dur)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	grab_focus()

func close_animated(dur := 0.20) -> void:
	if get_meta("closing", false):
		return
	set_meta("closing", true)
	var tw := create_tween()
	tw.tween_property(self, "size", Vector2i(0, 0), dur)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(Callable(self, "hide"))
	tw.tween_callback(func(): set_meta("closing", false))

func _on_close_pressed() -> void:
	if _embedded_mode:
		# ищем родительский PopupPanel (ManagementMenu) и прячем его
		var p: Node = self
		while p and not (p is PopupPanel):
			p = p.get_parent()
		if p and p is PopupPanel:
			(p as PopupPanel).hide()
	else:
		hide()

func _ready() -> void:
	need_label.bbcode_enabled = true

	_hero_names = GameManager.party_names.duplicate()
	_fill_recipe_list()
	_fill_assign_grid()

	if not list_recipes.item_selected.is_connected(_on_recipe_selected):
		list_recipes.item_selected.connect(_on_recipe_selected)
	if btn_cook and not btn_cook.pressed.is_connected(_on_cook_pressed):
		btn_cook.pressed.connect(_on_cook_pressed)
	if btn_serve and not btn_serve.pressed.is_connected(_on_serve_pressed):
		btn_serve.pressed.connect(_on_serve_pressed)


	if GameManager.has_signal("cooking_changed"):
		if not GameManager.cooking_changed.is_connected(_refresh_batch_ui):
			GameManager.cooking_changed.connect(_refresh_batch_ui)
			
	if spin_portions:
		spin_portions.min_value = 1
		spin_portions.step = 1
		if spin_portions.value < 1:
			spin_portions.value = 1
		spin_portions.value_changed.connect(func(_v): _refresh_recipe_preview())
	if GameManager.has_signal("container_changed") and not GameManager.container_changed.is_connected(_refresh_fridge_ui):
		GameManager.container_changed.connect(_refresh_fridge_ui)

	# клики по списку контейнера и кнопка «Достать»
	if cont_drop and not cont_drop.item_selected.is_connected(_on_cont_drop_selected):
		cont_drop.item_selected.connect(_on_cont_drop_selected)
	if cont_take_btn and not cont_take_btn.pressed.is_connected(_on_cont_take_pressed):
		cont_take_btn.pressed.connect(_on_cont_take_pressed)

	# стартовая отрисовка
	refresh_all()
	if not visibility_changed.is_connected(_on_vis_changed):
		visibility_changed.connect(_on_vis_changed)
	print("[KITCHEN] recipes:", GameManager.recipe_defs().size(),
	  " container_keys:", GameManager.container_all().keys().size())

func _on_vis_changed() -> void:
	# TabContainer прячет/показывает вкладки → ловим момент и обновляемся
	if is_visible_in_tree():
		refresh_all()

func open_centered() -> void:
	show()
	await get_tree().process_frame
	var root_size := get_tree().root.size
	var s := size
	position = Vector2i((root_size.x - s.x) / 2, (root_size.y - s.y) / 2)
	grab_focus()

func _fill_recipe_list() -> void:
	list_recipes.clear()
	for rid in GameManager.recipe_defs():
		var def := GameManager.get_recipe_def(str(rid))
		var name := str(def.get("name", rid))
		var i := list_recipes.add_item(name)
		list_recipes.set_item_metadata(i, str(rid))
	if list_recipes.item_count > 0:
		list_recipes.select(0)

func _cur_recipe_id() -> String:
	if list_recipes.item_count == 0:
		return ""
	var sel := list_recipes.get_selected_items()
	var idx := 0
	if sel.size() > 0:
		idx = int(sel[0])
	return str(list_recipes.get_item_metadata(idx))

func _fmt_num(v) -> String:
	# показываем целое без .0, иначе до 2 знаков
	if typeof(v) == TYPE_INT:
		return str(v)
	var f := float(v)
	var as_int := int(round(f))
	if abs(f - as_int) < 0.001:
		return str(as_int)
	return "%.2f" % f


func _on_recipe_selected(_i: int) -> void:
	_refresh_recipe_preview()

func _refresh_recipe_preview() -> void:
	var rid := _cur_recipe_id()
	var portions := int(spin_portions.value)
	if portions < 1:
		need_label.text = "Выберите количество порций."
		if btn_cook: btn_cook.disabled = true
		return

	var pr := GameManager.preview_cook(rid, portions)
	var need: Dictionary = pr.get("need", {})
	var lo: Array = pr.get("leftovers", [])

	var can_cook := (rid != "") and (portions > 0)
	var lines: Array = []

	var title := str(GameManager.get_recipe_def(rid).get("name", rid))
	lines.append("[b]%s[/b] — [b]%d[/b] порц.\n" % [title, portions])

	lines.append("[b]Потребуется:[/b]")
	for id in need.keys():
		var q = need[id]
		var have := GameManager.supply_get(id)
		var ok = have >= q
		if not ok: can_cook = false
		lines.append("- %s × %s  (есть: %s)%s"
			% [str(id), _fmt_num(q), _fmt_num(have), ("" if ok else " [color=red]нет[/color]")])

	if lo.size() > 0:
		lines.append("\n[b]Остатки:[/b]")
		for e in lo:
			lines.append("- %s × %s" % [str(e.get("id","")), _fmt_num(e.get("qty",0))])

	need_label.text = "\n".join(lines)
	if btn_cook: btn_cook.disabled = not can_cook

func _clear_assign_grid() -> void:
	for i in range(min(7, _hero_names.size())):
		var sp := grid.get_node_or_null("H%dCnt" % i)
		if sp is SpinBox: sp.value = 0

func _fill_assign_grid() -> void:
	# 7 персонажей — подписи и спинбоксы H0Name..H6Name, H0Cnt..H6Cnt
	for i in range(min(7, _hero_names.size())):
		var n = _hero_names[i]
		var lbl := grid.get_node_or_null("H%dName" % i)
		var sp  := grid.get_node_or_null("H%dCnt" % i)
		if lbl is Label:
			lbl.text = n
		if sp is SpinBox:
			sp.min_value = 0
			sp.max_value = 9
			sp.step = 1
			sp.value = 0

func _on_cook_pressed() -> void:
	if btn_cook and btn_cook.disabled: return
	var rid := _cur_recipe_id()
	var portions := int(spin_portions.value)
	if portions < 1: return
	if GameManager.cook(rid, portions):
		_clear_assign_grid()
		if spin_store: spin_store.value = 0
		_refresh_batch_ui()
		var title := String(GameManager.get_recipe_def(rid).get("name", rid))
		Toasts.ok("Сварили: %s ×%d" % [title, portions])
	else:
		Toasts.warn("Недостаточно припасов для '%s'." % rid)



func _refresh_batch_ui() -> void:
	var pm := GameManager.pending_meal
	if pm.is_empty():
		batch_info.text = "Партии нет"
		if spin_store: spin_store.value = 0
		_clear_assign_grid()
		return

	var meal := str(pm.get("meal",""))
	var left := int(pm.get("portions",0))
	var total := int(pm.get("total", left))
	var mdef := GameManager.get_recipe_def(meal)
	var in_cont := GameManager.container_count(meal)

	batch_info.text = "Партия: %s — всего %d, осталось %d  |  В контейнере: %d"% [str(mdef.get("name", meal)), total, left, in_cont]

	if spin_store:
		spin_store.min_value = 0
		spin_store.max_value = left
		if spin_store.value > left:
			spin_store.value = left
	_refresh_fridge_ui()

func _collect_assign() -> Dictionary:
	var out := {}
	for i in range(min(7, _hero_names.size())):
		var sp := grid.get_node_or_null("H%dCnt" % i)
		if sp is SpinBox:
			var c := int(sp.value)
			if c > 0:
				out[_hero_names[i]] = c
	return out
	

func _on_serve_pressed() -> void:
	var pm := GameManager.pending_meal
	if pm.is_empty():
		Toasts.warn("Нет приготовленной партии.", 2.0, "center")
		return

	var left := int(pm.get("portions", 0))
	var assign := _collect_assign()
	var store := int(spin_store.value)

	var total := 0
	for v in assign.values():
		total += int(v)

	if total + store > left:
		Toasts.warn("Нельзя раздать %d + отложить %d — в партии только %d." % [total, store, left])
		return

	var res := GameManager.distribute_pending(assign, store)
	_refresh_batch_ui()

	# собираем части сообщения
	var parts := []
	for k in (res["served"] as Dictionary).keys():
		parts.append("%s:%d" % [k, int(res["served"][k])])

	var segments := []
	if parts.size() > 0:
		segments.append("Выдано: " + ", ".join(parts))

	var stored := int(res.get("stored", 0))
	if stored > 0:
		segments.append("В контейнер: %d" % stored)

	var left_after := int(res.get("left", 0))
	if left_after > 0:
		segments.append("Осталось: %d" % left_after)

	var msg: String
	if segments.size() == 0:
		msg = "Никто не накормлен."
	else:
		msg = " | ".join(segments)

	Toasts.ok(msg, 2.3)
