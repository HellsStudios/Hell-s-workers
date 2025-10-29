extends Control

# === Константы/баланс ===
const HERO := "Berit"                           # имя героя для проверок
const STAMINA_PER_CARD := 3
const FAIR_CAP_RATIO := 0.60                    # кап влияния добросовестности (60%)
var copy_limits: Dictionary = {}  # id -> max_copies (сколько можно положить в пул)
var again_btn: Button
# Пороговые проверки риска (см. дизайн)
const RISK_CHECKS := [
	{"threshold": 33, "need_fair": 20, "risk_penalty": 10, "income_penalty_ratio": 0.10},
	{"threshold": 66, "need_fair": 40, "risk_penalty": 10, "income_penalty_ratio": 0.10},
]
var chosen_row: HBoxContainer = null   # полоса превью выбранных карт (до старта)
# === Ссылки на узлы ===
@onready var bg: TextureRect            = $BG
@onready var stamina_lbl: Label         = $Root/TopBar/Stamina
@onready var exit_btn: Button           = $Root/TopBar/ExitBtn

@onready var risk_bar: ProgressBar      = $Root/Meters/VBoxContainer2/RiskBar
@onready var cash_bar: ProgressBar      = $Root/Meters/VBoxContainer/CashBar
@onready var fair_bar: ProgressBar      = $Root/Meters/VBoxContainer3/FairBar

@onready var pool_grid: GridContainer   = $Root/Setup/Pool/ScrollContainer/PoolGrid
@onready var cards_spin: SpinBox        = $Root/Setup/Params/HBoxContainer/CardsSpin
@onready var cost_lbl: Label            = $Root/Setup/Params/CostLabel
@onready var start_btn: Button          = $Root/Setup/Params/StartBtn

@onready var play_area: Panel           = $Root/PlayArea
@onready var play_hint: Label           = $Root/PlayArea/MarginContainer/VBoxContainer/PlayHint
@onready var row: HBoxContainer         = $Root/PlayArea/MarginContainer/VBoxContainer/Row
@onready var draw_btn: Button           = $Root/PlayArea/MarginContainer/VBoxContainer/HBoxContainer/DrawBtn
@onready var finish_btn: Button         = $Root/PlayArea/MarginContainer/VBoxContainer/HBoxContainer/FinishBtn

@onready var result_panel: Panel        = $Root/ResultPanel
@onready var result_title: Label        = $Root/ResultPanel/VBoxContainer/ResultTitle
@onready var result_text: Label         = $Root/ResultPanel/VBoxContainer/ResultText
@onready var back_btn: Button           = $Root/ResultPanel/VBoxContainer/BackBtn

@onready var confirm: ConfirmationDialog = $StartConfirm

# === Состояние мини-игры ===
var selected_pool: Array = []      # массив firm_id (с повторами разрешено)
var deck: Array = []               # копия selected_pool на раунд (перемешанная)
var revealed: Array = []           # раскрытые карты: [{id, effect}, ...]
var cards_to_play: int = 0
var cards_played: int = 0

var cash: int = 0
var risk: int = 0
var fair: int = 0

var income_penalty_ratio: float = 0.0  # накапливаемый штраф от порогов
var hit_thresholds: Array = []         # какие пороги словили штрафом

var running: bool = false
var failed: bool = false
var FIRM_DEFS := {}   # перезапишем из JSON

func _init_copy_limits() -> void:
	copy_limits.clear()
	for id in FIRM_DEFS.keys():
		var owned := 0
		if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("get_firm_count"):
			owned = int(GameManager.get_firm_count(HERO, String(id)))
		# если хочешь мягкий дефолт, когда фирма «общедоступна», раскомментируй след. строку:
		# if owned == 0: owned = int(FIRM_DEFS[id].get("max_copies", 0))
		copy_limits[id] = owned  # 0 => недоступна


func _roll_int(x) -> int:
	# x может быть числом или массивом [min, max]
	if typeof(x) == TYPE_ARRAY and (x as Array).size() >= 2:
		var a := int(x[0])
		var b := int(x[1])
		if a > b: var t = a; a = b; b = t
		return randi_range(a, b)
	return int(x)

func _range_text(x) -> String:
	if typeof(x) == TYPE_ARRAY and (x as Array).size() >= 2:
		var a := int(x[0]); var b := int(x[1])
		if a > b: var t = a; a = b; b = t
		return "%+d…%+d" % [a, b]
	return "%+d" % int(x)


func _max_cards() -> int:
	return int(cards_spin.value)
	
func _use_json_or_fallback() -> void:
	var arr := _load_firm_cards_from_json()
	if arr.is_empty():
		print("[FIRMS] JSON пуст/не найден — fallback на встроенный дефолт.")
		FIRM_DEFS = {
			"wash":   {"id":"wash","title":"Прачечная","tag":"услуги","dcash":[5,8],"drisk":[5,8],"dfair":[0,1]},
			"barber": {"id":"barber","title":"Барбершоп","tag":"наличка","dcash":[3,5],"drisk":0,"dfair":[1,3]},
			"tour":   {"id":"tour","title":"Тур-агентство","tag":"услуги","dcash":[4,7],"drisk":[6,9],"dfair":0},
			"cafe":   {"id":"cafe","title":"Кафе-конверт","tag":"наличка","dcash":[2,4],"drisk":0,"dfair":[0,2],"trigger":"react_last_cash"},
			"shell":  {"id":"shell","title":"Прокладка","tag":"пустышка","dcash":0,"drisk":[-5,-3],"dfair":0},
			"contract":{"id":"contract","title":"Подрядчик","tag":"подряд","dcash":[8,11],"drisk":[11,13],"dfair":0},
			"ip":     {"id":"ip","title":"ИП «Смета»","tag":"услуги","dcash":[1,3],"drisk":[-3,-1],"dfair":[2,4]},
			"courier":{"id":"courier","title":"Курьерка","tag":"наличка","dcash":[3,5],"drisk":[1,2],"dfair":0,"trigger":"bonus_if_services"},
			"facade": {"id":"facade","title":"Фасад","tag":"пустышка","dcash":0,"drisk":0,"dfair":[4,6],"trigger":"buff_next"},
		}
	else:
		var map := {}
		for e in arr:
			if typeof(e) != TYPE_DICTIONARY: continue
			var id := String(e.get("id",""))
			if id == "": continue
			map[id] = e.duplicate(true)
		FIRM_DEFS = map

	print("[FIRMS] итоговая БД карт: ", FIRM_DEFS.size(), " шт. | ids=", FIRM_DEFS.keys())

func _ensure_chosen_ui() -> void:
	if chosen_row and is_instance_valid(chosen_row):
		return
	# вставим полосу превью между PlayHint и Row
	var vbox := $Root/PlayArea/MarginContainer/VBoxContainer
	chosen_row = HBoxContainer.new()
	chosen_row.name = "ChosenRow"
	chosen_row.custom_minimum_size.y = 36
	chosen_row.add_theme_constant_override("separation", 6)
	vbox.add_child(chosen_row)
	var idx := vbox.get_children().find(row)
	if idx >= 0:
		vbox.move_child(chosen_row, idx) # перед Row

func _swap_in_pool(i: int, j: int) -> void:
	if i < 0 or j < 0 or i >= selected_pool.size() or j >= selected_pool.size(): return
	var tmp = selected_pool[i]
	selected_pool[i] = selected_pool[j]
	selected_pool[j] = tmp

func _rebuild_selection_view() -> void:
	_ensure_chosen_ui()
	for c in chosen_row.get_children():
		c.queue_free()

	if selected_pool.is_empty():
		var lbl := Label.new()
		lbl.text = "Пока ничего не выбрано."
		chosen_row.add_child(lbl)
		return

	for i in range(selected_pool.size()):
		var id := String(selected_pool[i])
		var def: Dictionary = FIRM_DEFS.get(id, {})

		var chip := Button.new()
		chip.text = "%d) %s" % [i + 1, String(def.get("title", id))]
		chip.tooltip_text = _effects_text(def) + "\nЛКМ: удалить эту копию."
		chip.focus_mode = Control.FOCUS_NONE
		chip.custom_minimum_size.y = 28

		# читаемый текст
		chip.add_theme_color_override("font_color", Color(1,1,1))
		chip.add_theme_color_override("font_color_hover", Color(1,1,1))
		chip.add_theme_color_override("font_color_pressed", Color(1,1,1))
		chip.add_theme_font_size_override("font_size", 14)

		_apply_chip_style(chip) # если используешь стили

		# клик — удалить ОДНУ копию
		chip.pressed.connect(func():
			selected_pool.remove_at(i)
			_rebuild_selection_view()
			_recalc_spin_limits()
			_update_cost_label()
			_toasts_ok("Удалено из пула: %s (всего: %d)" % [def.get("title", id), selected_pool.size()])
		)

		chosen_row.add_child(chip)


func _recalc_spin_limits() -> void:
	# Больше НЕ трогаем cards_spin.max_value и cards_spin.value
	start_btn.disabled = selected_pool.is_empty()


func _load_firm_cards_from_json() -> Array:
	var path := "res://Data/berit_firms.json"
	var real := (GameManager.resolve_res_path(path) if "resolve_res_path" in GameManager else path)
	if not FileAccess.file_exists(real):
		print("[FIRMS] файл не найден: ", real)
		return []
	var txt := FileAccess.get_file_as_string(real)
	if txt == "":
		print("[FIRMS] пустой файл: ", real)
		return []
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) == TYPE_ARRAY:
		print("[FIRMS] JSON массив, записей: ", (parsed as Array).size())
		return parsed
	if typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("firms"):
		var arr: Array = parsed["firms"]
		print("[FIRMS] JSON объект.firms, записей: ", arr.size())
		return arr
	print("[FIRMS] неизвестный формат JSON (ожидался Array или {firms:[]}).")
	return []


# === Helpers ===


func _hero_busy() -> bool:
	return typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("is_hero_busy") \
		and GameManager.is_hero_busy(HERO)

func _hero_stamina() -> int:
	if typeof(GameManager) == TYPE_OBJECT:
		if GameManager.has_method("get_hero_stamina"):
			return int(GameManager.get_hero_stamina(HERO))
		# совместимость, если вдруг выпилишь геттер:
		return int(GameManager.res_cur(HERO, "stamina"))
	return 0

func _hero_stamina_max() -> int:
	if typeof(GameManager) == TYPE_OBJECT:
		if GameManager.has_method("get_hero_stamina_max"):
			return int(GameManager.get_hero_stamina_max(HERO))
		return int(GameManager.res_max(HERO, "stamina"))
	return 0

func _spend_stamina(v: int) -> bool:
	if v <= 0: return true
	if typeof(GameManager) == TYPE_OBJECT:
		if GameManager.has_method("spend_stamina"):
			return bool(GameManager.spend_stamina(HERO, v))
		# прямой безопасный путь через res_cur/set_res_cur
		var cur := int(GameManager.res_cur(HERO, "stamina"))
		if cur < v:
			return false
		GameManager.set_res_cur(HERO, "stamina", cur - v)
		return true
	return false


func _ingest_firm_defs(arr: Array) -> Dictionary:
	var out := {}
	for e in arr:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if not e.has("id") or not e.has("title"):
			continue
		var id := String(e["id"])
		var def := {
			"id": id,
			"title": String(e.get("title", id)),
			"tag": String(e.get("tag", "")),
			"dcash": int(e.get("dcash", 0)),
			"drisk": int(e.get("drisk", 0)),
			"dfair": int(e.get("dfair", 0))
		}
		if e.has("trigger"): def["trigger"] = String(e["trigger"])
		if e.has("icon"):    def["icon"]    = String(e["icon"])
		out[id] = def
	return out

func _toasts_ok(msg: String) -> void:
	if Engine.has_singleton("Toasts"):
		Toasts.ok(msg)
	else:
		print("[MiniGame] ", msg)

func _toasts_warn(msg: String) -> void:
	if Engine.has_singleton("Toasts"):
		Toasts.warn(msg)
	else:
		push_warning("[MiniGame] " + msg)

func _add_rewards(krestli: int, more := {}) -> void:
	if krestli > 0 and typeof(GameManager) == TYPE_OBJECT:
		GameManager.krestli = int(GameManager.krestli) + krestli
		# по желанию: всплывашка
		if Engine.has_singleton("Toasts"):
			Toasts.ok("+%d кр." % krestli)
	# эфирия (если вдруг добавишь в выход)
	if more.has("etheria") and typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("add_etheria"):
		GameManager.add_etheria(int(more["etheria"]))


func _goto_mansion() -> void:
	# Предпочитаем «родной» метод, иначе fallback
	if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("goto_mansion"):
		GameManager.goto_mansion()
	else:
		get_tree().change_scene_to_file("res://Scenes/mansion.tscn")

# === UI wiring ===
func _ready() -> void:
	# Инициализация UI
	$Root/TopBar/Title.text = "Серые схемы: Берит"
	exit_btn.text = "Выйти"
	exit_btn.pressed.connect(func():
		_goto_mansion()
	)

	# бары
	cash_bar.min_value = 0; cash_bar.max_value = 100  # просто визуал (не жёсткий кап)
	risk_bar.min_value = 0; risk_bar.max_value = 100
	fair_bar.min_value = 0; fair_bar.max_value = 100

	# спин и кнопки
	cards_spin.min_value = 1
	cards_spin.max_value = 12
	cards_spin.value = 5
	cards_spin.value_changed.connect(_on_cards_changed)
	start_btn.text = "Начать"
	start_btn.pressed.connect(_on_start_pressed)
	draw_btn.text = "Открыть карту"
	draw_btn.disabled = true
	draw_btn.pressed.connect(_on_draw_pressed)
	finish_btn.text = "Завершить"
	finish_btn.disabled = true
	finish_btn.pressed.connect(_on_finish_pressed)

	# подтверждение списания стамины
	confirm.title = "Начать раунд?"
	confirm.dialog_text = "Списать стамину и запустить схему?"
	confirm.confirmed.connect(_on_confirm_start)

	# результат
	result_panel.visible = false
	back_btn.text = "Вернуться в поместье"
	back_btn.pressed.connect(_goto_mansion)

	# стартовые значения
	_update_stamina_label()
	_update_cost_label()
	_reset_meters()

	# заполним пул (пока жёстко, потом подтягиваем из GM)
	_use_json_or_fallback()
	_init_copy_limits()
	_build_pool_ui()
	_rebuild_selection_view()
	# проверка занятости
	var vb := result_panel.get_node("VBoxContainer")
	again_btn = Button.new()
	again_btn.text = "Сыграть ещё"
	again_btn.visible = false
	again_btn.pressed.connect(_on_again_pressed)
	vb.add_child(again_btn)
	vb.move_child(again_btn, vb.get_children().find(back_btn))  # поставить перед back_btn
	if _hero_busy():
		_toasts_warn("Берит занят — сейчас не до схем.")
		# можно сразу заблокировать старт
		start_btn.disabled = true
	if typeof(GameManager) == TYPE_OBJECT and not GameManager.is_connected("firms_changed", _on_firms_changed):
		GameManager.firms_changed.connect(_on_firms_changed)

func _on_firms_changed(hero: String) -> void:
	if hero != HERO: return
	_init_copy_limits()
	_build_pool_ui()
	_rebuild_selection_view()

func _on_again_pressed() -> void:
	# очистить следы прошлого раунда
	for c in row.get_children():
		c.queue_free()
	revealed.clear()
	deck.clear()
	cards_played = 0
	running = false
	failed = false

	# восстановить UI в режим подготовки
	result_panel.visible = false
	again_btn.visible = false
	start_btn.disabled = selected_pool.is_empty()
	draw_btn.disabled = true
	finish_btn.disabled = true
	if chosen_row:
		chosen_row.visible = true
	_recalc_spin_limits()
	_reset_meters()        # обнуляем бары/хинт (доход с прошлого уже начислен)
	_update_cost_label()


func _reset_meters() -> void:
	cash = 0; risk = 0; fair = 0
	income_penalty_ratio = 0.0
	hit_thresholds.clear()
	_update_bars()
	play_hint.text = "Выбери пул фирм, задай число карт и жми «Начать»."

func _update_bars() -> void:
	cash_bar.value = cash
	risk_bar.value = risk
	fair_bar.value = fair

func _update_stamina_label() -> void:
	var cur := _hero_stamina()
	stamina_lbl.text = "Стамина: %d" % cur

func _mk_sb(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb

func _apply_chip_style(b: Button) -> void:
	b.add_theme_stylebox_override("normal",   _mk_sb(Color(0.16,0.18,0.22,0.95)))
	b.add_theme_stylebox_override("hover",    _mk_sb(Color(0.22,0.25,0.30,0.95)))
	b.add_theme_stylebox_override("pressed",  _mk_sb(Color(0.14,0.16,0.20,0.95)))
	b.add_theme_stylebox_override("disabled", _mk_sb(Color(0.12,0.13,0.16,0.90)))

func _on_cards_changed(v: float) -> void:
	var n := int(v)
	if n < selected_pool.size():
		# откатываем — нельзя опускать N ниже уже выбранного количества
		cards_spin.value = selected_pool.size()
		_toasts_warn("Нельзя уменьшить N ниже уже выбранных карт (%d). Удалите карту в списке." % selected_pool.size())
		return
	_update_cost_label()

func _update_cost_label() -> void:
	var n := int(cards_spin.value)
	cost_lbl.text = "Стоимость стамины: %d × %d = %d" % [STAMINA_PER_CARD, n, STAMINA_PER_CARD * n]

func _build_pool_ui() -> void:
	pool_grid.columns = 3
	for c in pool_grid.get_children():
		c.queue_free()

	if FIRM_DEFS.is_empty():
		_toasts_warn("Пул фирм пуст. Проверь berit_firms.json.")
		print("[FIRMS][UI] Нечего строить — FIRM_DEFS пуст.")
		return

	var built := 0
	for id in FIRM_DEFS.keys():
		var def: Dictionary = FIRM_DEFS[id]
		var title := String(def.get("title", id))
		var limit := int(copy_limits.get(id, 0))
		if limit <= 0:
			# хочешь – можно показывать «серым»:
			# var lock := Button.new(); lock.text = title + " (нет копий)"; lock.disabled = true; pool_grid.add_child(lock)
			continue

		var b := Button.new()
		b.text = title
		b.tooltip_text = _effects_text(def) + "\nДоступных копий: %d" % limit
		b.pressed.connect(func():
			if selected_pool.size() >= _max_cards():
				_toasts_warn("Слотов больше нет (%d/%d)." % [selected_pool.size(), _max_cards()])
				return
			var cur := 0
			for x in selected_pool:
				if String(x) == id: cur += 1
			if cur >= limit:
				_toasts_warn("Лимит копий «%s» исчерпан (%d)." % [title, limit])
				return
			selected_pool.append(id)
			_rebuild_selection_view()
			_update_cost_label()
			_toasts_ok("Добавлено: %s (%d/%d)" % [title, cur+1, limit])
		)
		pool_grid.add_child(b)


	var clear := Button.new()
	clear.text = "Очистить пул"
	clear.pressed.connect(func():
		selected_pool.clear()
		_rebuild_selection_view()
		_update_cost_label()
		_toasts_ok("Пул очищен.")
		print("[FIRMS][UI] pool cleared")
	)
	pool_grid.add_child(clear)

	print("[FIRMS][UI] построено кнопок: ", built)

# === Игровой цикл ===

func _on_start_pressed() -> void:
	if _hero_busy():
		_toasts_warn("Берит занят — сейчас не до схем.")
		return

	if selected_pool.is_empty():
		_toasts_warn("Выбери хотя бы одну фирму в пул.")
		return

	cards_to_play = int(cards_spin.value)
	if cards_to_play > selected_pool.size():
		_toasts_warn("Вы выбрали %d карт(ы) для розыгрыша, но в пуле только %d." % [cards_to_play, selected_pool.size()])
		return
	var cost := cards_to_play * STAMINA_PER_CARD
	var have := _hero_stamina()
	if have < cost:
		_toasts_warn("Недостаточно стамины (%d/%d)." % [have, cost])
		return

	confirm.dialog_text = "Списать %d стамины и начать? Это спишется сразу." % cost
	confirm.popup_centered_ratio(0.25)


func _on_confirm_start() -> void:
	var cost := cards_to_play * STAMINA_PER_CARD
	if not _spend_stamina(cost):
		_toasts_warn("Не удалось списать стамину (возможно, её изменили).")
		return
	_update_stamina_label()
	if chosen_row: 
		chosen_row.visible = false
	# подготавливаем колоду (случайные карты из выбранного пула)
	deck = selected_pool.duplicate()
	deck.shuffle()
	cards_played = 0
	running = true
	failed = false
	draw_btn.disabled = false
	finish_btn.disabled = false
	start_btn.disabled = true
	play_hint.text = "Открывай карты по одной. Если риск достигнет 100 — накроют схему."

	# очистим ряд
	for c in row.get_children():
		c.queue_free()

func _on_draw_pressed() -> void:
	if not running: return
	if cards_played >= cards_to_play:
		return

	# берём карту (если deck короче N — крутим по кругу)
	var idx := cards_played % deck.size()
	var firm_id := String(deck[idx])
	_apply_card(firm_id)

	cards_played += 1
	if failed:
		_finish_round()
		return

	if cards_played >= cards_to_play:
		_finish_round()

func _on_finish_pressed() -> void:
	if running:
		_finish_round()

func _finish_round() -> void:
	running = false
	draw_btn.disabled = true
	finish_btn.disabled = true

	# итоговый доход с учётом штрафов
	var final_cash := int(floor(float(cash) * (1.0 - income_penalty_ratio)))

	# Ярусные бонусы за fair
	var fair_bonus_ratio := 0.0
	if fair >= 90:
		fair_bonus_ratio = 0.15
	elif fair >= 60:
		fair_bonus_ratio = 0.10
	elif fair >= 30:
		fair_bonus_ratio = 0.05

	if fair_bonus_ratio > 0.0 and not failed:
		var bonus := int(round(final_cash * fair_bonus_ratio))
		final_cash += bonus
		_toasts_ok("Бонус за добропорядочность: +%d кр." % bonus)
	if not failed:
		# бонусы за чистоту/комбо можем добавить позже
		_add_rewards(final_cash, {})
		result_title.text = "Успех"
		result_text.text  = "Вы получили: +%d кр.\nРиск: %d\nДобросовестность: %d\nПорогов со штрафом: %d" % [
			final_cash, risk, fair, hit_thresholds.size()
		]
	else:
		result_title.text = "Накрыли"
		result_text.text  = "Доход: 0\nРиск: %d\nДобросовестность: %d\nКондиция: грусть" % [risk, fair]
		# пример: повесить негативную кондицию
		if typeof(GameManager) == TYPE_OBJECT and GameManager.has_method("add_condition"):
			GameManager.add_condition(HERO, "sad")

	result_panel.visible = true
	if chosen_row:
		chosen_row.visible = true
	if again_btn:
		again_btn.visible = true
# === Применение карты ===
func _trigger_human(trig: String) -> String:
	match trig:
		"react_last_cash":
			return "Реактивация последней «налички»: повторно даёт доход."
		"bonus_if_services":
			return "Если в ряду ≥2 «услуг» — +2 доход."
		"buff_next":
			return "Бафф следующей карты: +2 доход, −1 риск."
		_:
			return ""

func _effects_text(def: Dictionary) -> String:
	var parts: Array = []
	parts.append("Доход " + _range_text(def.get("dcash", 0)))
	parts.append("Риск "  + _range_text(def.get("drisk", 0)))
	parts.append("Добросовестность " + _range_text(def.get("dfair", 0)))
	var t := String(def.get("trigger",""))
	var trig_txt := _trigger_human(t)
	var tag_txt := String(def.get("tag",""))
	var body := " | ".join(parts)
	if tag_txt != "":
		body += "  ·  Тег: " + tag_txt
	if trig_txt != "":
		body += "\nСпособность: " + trig_txt
	return body


func _apply_card(id: String) -> void:
	if not FIRM_DEFS.has(id): return
	var def = FIRM_DEFS[id]

	# виджет раскрытой карты (плейсхолдер)
	var card := Button.new()
	_apply_chip_style(card)
	card.disabled = true
	card.text = "%d) %s" % [cards_played + 1, String(def.get("title", id))]
	card.tooltip_text = _effects_text(def)
	card.disabled = true
	row.add_child(card)

	# базовые эффекты
	var dcash := _roll_int(def.get("dcash", 0))
	var drisk := _roll_int(def.get("drisk", 0))
	var dfair := _roll_int(def.get("dfair", 0))

	# учёт fair как щита риска (с капом по доле)
	var fair_ratio = min(FAIR_CAP_RATIO, float(fair) / 100.0)
	var drisk_eff := drisk
	if drisk > 0:
		drisk_eff = int(max(0.0, round(float(drisk) * (1.0 - fair_ratio))))

	# применяем
	cash += dcash
	fair = clamp(fair + dfair, 0, 100)
	# риск до порогов
	var risk_before := risk
	risk = clamp(risk + drisk_eff, 0, 100)

	# триггеры/синергии
	_apply_triggers(def)

	# пороговые проверки (33/66)
	_check_risk_thresholds(risk_before, risk)

	# проверка фейла
	if risk >= 100:
		failed = true

	_update_bars()

func _apply_triggers(def: Dictionary) -> void:
	var trig := String(def.get("trigger",""))
	match trig:
		"react_last_cash":
			# реактивируем последнюю карту с tag = «наличка»: только доход (+dcash)
			var last_cash := _find_last_with_tag("наличка")
			if last_cash:
				var id := String(last_cash["id"])
				var d = FIRM_DEFS.get(id, {})
				cash += _roll_int(d.get("dcash", 0))   # <-- ВАЖНО: используем _roll_int
		"bonus_if_services":
			if _count_with_tag("услуги") >= 2:
				cash += 2
		"buff_next":
			revealed.append({"id":"__buff_next__"})
		_:
			pass

	# если есть маркер "__buff_next__", применим к ТЕКУЩЕЙ карте и уберём маркер
	var idx := _index_of_buff_next()
	if idx != -1:
		# +2 к доходу, -1 к риску
		cash += 2
		risk = max(0, risk - 1)
		revealed.remove_at(idx)

	# записываем текущую карту в revealed (в самом конце)
	revealed.append({"id": String(def.get("id","")), "tag": String(def.get("tag",""))})

func _find_last_with_tag(tag: String) -> Dictionary:
	for i in range(revealed.size() - 1, -1, -1):
		var it = revealed[i]
		if String(it.get("tag","")) == tag:
			return it
	return {}

func _count_with_tag(tag: String) -> int:
	var cnt := 0
	for it in revealed:
		if String(it.get("tag","")) == tag:
			cnt += 1
	return cnt

func _index_of_buff_next() -> int:
	for i in range(revealed.size()):
		if String(revealed[i].get("id","")) == "__buff_next__":
			return i
	return -1

func _check_risk_thresholds(prev: int, cur: int) -> void:
	for t in RISK_CHECKS:
		var thr := int(t["threshold"])
		if prev < thr and cur >= thr:
			var need := int(t["need_fair"])
			if fair >= need:
				# прошли спокойно
				_toasts_ok("Порог %d: честность спасла." % thr)
			else:
				# штраф
				risk = clamp(risk + int(t["risk_penalty"]), 0, 100)
				income_penalty_ratio += float(t["income_penalty_ratio"])
				hit_thresholds.append(thr)
				_toasts_warn("Порог %d: накрутили риск и штраф к доходу." % thr)
