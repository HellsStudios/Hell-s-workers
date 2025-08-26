extends Control
class_name DialogPlayer

# ── настройка ──────────────────────────────────────────────────────────
const PORTRAIT_SCALE := 0.33          # портреты в 3 раза меньше
const TYPE_SPEED     := 45.0          # печать: символов в секунду
const DIALOGS_JSON   := "res://Data/dialogs.json"
const PORTRAIT_FMT   := "res://Assets/portraits/{char}/{pose}.png"  # базовый шаблон
const DEFAULT_PORTRAIT_SCALE := 0.4     # дефолтный масштаб (≈ в 4.2 раза меньше исходника)
const DEFAULT_OFF_BOTTOM      := 280.0     # отступ от низа (px)
const DEFAULT_OFF_CENTER      := 80.0    # расстояние от вертикального центра (px)

# ── лог ────────────────────────────────────────────────────────────────
func _log(msg: String, ctx: Dictionary = {}) -> void:
	print("[Dialog] ", msg, " | ", ctx)

# ── сигналы ────────────────────────────────────────────────────────────
signal next_requested
signal choice_selected(index: int)
signal dialog_finished(result: Dictionary)

# ── ноды UI ────────────────────────────────────────────────────────────
@onready var click_catcher: Control = $ClickCatcher

@onready var music: AudioStreamPlayer2D = $Music
@onready var sfx:   AudioStreamPlayer2D = $Sfx

@onready var bg: TextureRect      = $Bg
@onready var shade: ColorRect     = $Shade

@onready var left_slot:  Control      = $Portraits/LeftSlot
@onready var right_slot: Control      = $Portraits/RightSlot
@onready var left_por:   TextureRect  = $Portraits/LeftSlot/Portrait
@onready var right_por:  TextureRect  = $Portraits/RightSlot/Portrait
@onready var left_punch:  AudioStreamPlayer2D = $Portraits/LeftSlot/PunchSfx
@onready var right_punch: AudioStreamPlayer2D = $Portraits/RightSlot/PunchSfx

@onready var panel:  Panel            = $Bottom
@onready var margin: MarginContainer  = $Bottom/Margin
@onready var name_lbl: Label          = $Bottom/Margin/VBoxContainer/Name
@onready var text_lbl: RichTextLabel  = $Bottom/Margin/VBoxContainer/Text
@onready var choices_box: VBoxContainer = $Bottom/Margin/Choices

# ── состояние ──────────────────────────────────────────────────────────
var _has_choices := false
var _typing := false
var _type_tween: Tween = null

var _db: Dictionary = {}      # id -> dialog def
var _nodes: Dictionary = {}   # узлы текущего диалога
var _cur_id := ""             # текущий узел
var _next_id := ""            # куда идти после текущей реплики

# ── lifecycle ──────────────────────────────────────────────────────────
func _ready() -> void:
	# всегда поверх
	set_as_top_level(true)
	anchor_left = 0; anchor_top = 0; anchor_right = 1; anchor_bottom = 1
	offset_left = 0; offset_top = 0; offset_right = 0; offset_bottom = 0
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_as_relative = false
	z_index = 4090
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_unhandled_input(true)

	# критично: коннекты внутренних сигналов
	if not next_requested.is_connected(_on_next):
		next_requested.connect(_on_next)
	if not choice_selected.is_connected(_on_choice):
		choice_selected.connect(_on_choice)

	# клики по всему экрану
	if click_catcher:
		click_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
		click_catcher.gui_input.connect(_on_click_gui_input)
	else:
		_log("WARNING: ClickCatcher node not found; falling back to _unhandled_input()")
	# Явный порядок отрисовки
	$Bg.z_as_relative = false;      $Bg.z_index = 0
	$Shade.z_as_relative = false;   $Shade.z_index = 10
	$Portraits.z_as_relative = false; $Portraits.z_index = 20
	$Bottom.z_as_relative = false;  $Bottom.z_index = 30

	# Портреты позиционируем в координатах экрана (не родителя)
	left_por.set_as_top_level(true)
	right_por.set_as_top_level(true)
	left_por.z_as_relative = false;  left_por.z_index = 21
	right_por.z_as_relative = false; right_por.z_index = 21
	_dump_layout("ready")
	_log("_ready done")

# ── input ─────────────────────────────────────────────────────────────
func _on_click_gui_input(event: InputEvent) -> void:
	# единая точка для ЛКМ/Enter; колёсико игнорируем
	if _has_choices:
		return
	var go_next := false
	if event.is_action_pressed("ui_accept"):
		go_next = true
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not mb.is_echo():
			go_next = true
	if not go_next:
		return

	if _typing:
		_log("click while typing -> finish typewriter")
		_stop_typewriter(true)
		return

	_log("click -> next_requested emit")
	next_requested.emit()

func _unhandled_input(event: InputEvent) -> void:
	# резервный путь, если ClickCatcher вдруг не ловит
	if not visible or _has_choices:
		return
	var go_next := false
	if event.is_action_pressed("ui_accept"):
		go_next = true
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not mb.is_echo():
			go_next = true
	if not go_next:
		return
	if _typing:
		_log("unhandled: finish typewriter")
		_stop_typewriter(true)
		return
	_log("unhandled: emit next_requested")
	next_requested.emit()

# ── helpers: фон/музыка ───────────────────────────────────────────────
func set_background(tex: Texture2D) -> void:
	bg.texture = tex

func set_background_path(path: String) -> void:
	_log("set_background_path", {"path": path})
	if path != "" and ResourceLoader.exists(path):
		set_background(load(path))
	else:
		_log("BG not found", {"path": path})

func play_music_path(path: String, loop := true) -> void:
	_log("play_music_path", {"path": path})
	if path == "" or not ResourceLoader.exists(path):
		_log("MUSIC not found", {"path": path})
		return
	var stream: AudioStream = load(path)
	music.stream = stream
	if "loop" in stream:
		stream.loop = loop
	music.play()

func stop_music() -> void:
	if music.playing:
		music.stop()

# ── portraits ─────────────────────────────────────────────────────────
func _slot_apply(side: String, src_path: String, dim: bool) -> void:
	var tr: TextureRect = (left_por if side == "left" else right_por)

	var tex: Texture2D = null
	if src_path != "" and ResourceLoader.exists(src_path):
		tex = load(src_path)
	tr.texture = tex
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	if tex:
		var sz := tex.get_size() * DEFAULT_PORTRAIT_SCALE
		tr.custom_minimum_size = sz
		tr.size = sz
		tr.pivot_offset = sz * 0.5

	_set_dim(tr, bool(dim))

	# важно: раскладку делаем после того, как нода получила size
	call_deferred("_layout_portraits")


func _layout_portraits() -> void:
	# узлы могут быть ещё не готовы/освобождены
	if left_por == null or right_por == null:
		return
	if !is_instance_valid(left_por) or !is_instance_valid(right_por):
		return

	var vp := get_viewport_rect().size
	var cx := vp.x * 0.5

	var lsz := left_por.size
	var rsz := right_por.size

	# если размеров ещё нет — подождём следующий кадр
	if lsz == Vector2.ZERO and left_por.texture == null: return
	if rsz == Vector2.ZERO and right_por.texture == null: return

	# левый
	left_por.global_position = Vector2(
		cx - DEFAULT_OFF_CENTER - lsz.x,
		vp.y - DEFAULT_OFF_BOTTOM - lsz.y
	)
	# правый
	right_por.global_position = Vector2(
		cx + DEFAULT_OFF_CENTER,
		vp.y - DEFAULT_OFF_BOTTOM - rsz.y
	)


func _notification(what):
	if what == NOTIFICATION_RESIZED:
		call_deferred("_layout_portraits")


func _set_dim(tr: TextureRect, on: bool) -> void:
	var tw = create_tween()
	tw.tween_property(tr, "modulate:a", (0.55 if on else 1.0), 0.15)
	tw.parallel().tween_property(tr, "scale", (Vector2(0.95,0.95) if on else Vector2.ONE), 0.15)

func _emphasize(side: String, sfx_path := "") -> void:
	var tr: TextureRect = (left_por if side == "left" else right_por)
	var punch: AudioStreamPlayer2D = (left_punch if side == "left" else right_punch)

	if sfx_path != "" and ResourceLoader.exists(sfx_path):
		punch.stream = load(sfx_path)
	if punch.stream:
		punch.play()

	var tw = create_tween()
	tw.tween_property(tr, "position:y", -6, 0.06).as_relative()
	tw.tween_property(tr, "position:y", +6, 0.06).as_relative()

	# лёгкое «дыхание»
	var loop = create_tween().set_loops()
	loop.tween_property(tr, "position:y", -2, 0.6).as_relative()
	loop.tween_property(tr, "position:y", +2, 0.6).as_relative()

const DBG_LAYOUT := true

func _dbg(msg: String, ctx: Dictionary = {}) -> void:
	if DBG_LAYOUT:
		print("[DialogDBG] ", msg, " | ", ctx)

func _rect_info(c: Control) -> Dictionary:
	return {
		"name": c.name,
		"global_pos": c.global_position,
		"size": c.size,
		"anchors": [c.anchor_left, c.anchor_top, c.anchor_right, c.anchor_bottom],
		"offsets": [c.offset_left, c.offset_top, c.offset_right, c.offset_bottom],
		"z": c.z_index, "z_abs": not c.z_as_relative
	}

func _dump_layout(tag: String = "") -> void:
	var vp := get_viewport_rect().size
	var l_tex := Vector2.ZERO
	if left_por.texture != null:
		l_tex = left_por.texture.get_size()
	var r_tex := Vector2.ZERO
	if right_por.texture != null:
		r_tex = right_por.texture.get_size()

	_dbg("LAYOUT " + tag, {"viewport": vp})
	_dbg("BG", {"has_tex": bg.texture != null, "size": bg.size})
	_dbg("Panel", _rect_info(panel))
	_dbg("Name", _rect_info(name_lbl))
	_dbg("Text", _rect_info(text_lbl))
	_dbg("LeftSlot", _rect_info(left_slot))
	_dbg("LeftPor", {"size": left_por.size, "pivot": left_por.pivot_offset, "tex_sz": l_tex})
	_dbg("RightSlot", _rect_info(right_slot))
	_dbg("RightPor", {"size": right_por.size, "pivot": right_por.pivot_offset, "tex_sz": r_tex})
	_dbg("ClickCatcher", _rect_info(click_catcher))

func _layout_slots_bottom_corners() -> void:
	var vp := get_viewport_rect().size
	var margin := 32.0

	# левый портрет
	var lsz := left_por.size
	left_por.global_position = Vector2(
		margin,
		vp.y - margin - lsz.y
	)

	# правый портрет
	var rsz := right_por.size
	right_por.global_position = Vector2(
		vp.x - margin - rsz.x,
		vp.y - margin - rsz.y
	)

	_dbg("place_portraits", {
		"vp": vp, "l_pos": left_por.global_position, "l_size": lsz,
		"r_pos": right_por.global_position, "r_size": rsz
	})
# ── печаталка ─────────────────────────────────────────────────────────
func _start_typewriter(txt: String) -> void:
	_stop_typewriter()
	text_lbl.bbcode_enabled = false
	text_lbl.text = txt
	text_lbl.visible_ratio = 0.0
	_typing = true
	var secs = max(0.01, float(txt.length()) / TYPE_SPEED)
	_type_tween = create_tween()
	_type_tween.tween_property(text_lbl, "visible_ratio", 1.0, secs)
	_type_tween.finished.connect(func():
		_typing = false
		_type_tween = null
		_log("typewriter finished")
	)
	_log("typewriter start", {"len": txt.length(), "secs": secs})

func _stop_typewriter(finish_now := false) -> void:
	if _type_tween and _type_tween.is_running():
		_type_tween.kill()
	_type_tween = null
	if finish_now:
		text_lbl.visible_ratio = 1.0
	_typing = false

# ── показ реплики / выборов ───────────────────────────────────────────
func show_line(args: Dictionary) -> void:
	click_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	choices_box.visible = false
	_clear_choices()
	_has_choices = false

	name_lbl.text = String(args.get("speaker", ""))

	var l = args.get("left", {})
	var r = args.get("right", {})
	_slot_apply("left",  String(l.get("src","")),  bool(l.get("dim", false)))
	_slot_apply("right", String(r.get("src","")),  bool(r.get("dim", false)))

	_layout_portraits()            # <-- вот это
	_dump_layout("after_layout")
	_emphasize(String(args.get("active_side","left")), String(args.get("sfx","")))
	_start_typewriter(String(args.get("text","")))

	_emphasize(String(args.get("active_side","left")), String(args.get("sfx","")))
	_start_typewriter(String(args.get("text","")))
	_log("show_line", {"speaker": name_lbl.text})

func show_choices(prompt: String, options: Array) -> void:
	click_catcher.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.text = ""
	text_lbl.text = prompt
	_clear_choices()
	for i in range(options.size()):
		var btn := Button.new()
		btn.text = String(options[i].get("text","Вариант %d" % (i+1)))
		btn.custom_minimum_size = Vector2(240, 40)
		btn.pressed.connect(func():
			_log("choice pressed", {"index": i, "text": btn.text})
			choice_selected.emit(i)
		)
		choices_box.add_child(btn)
		if i == 0:
			btn.grab_focus()
	choices_box.visible = true
	_has_choices = true
	_log("show_choices", {"count": options.size()})

func _clear_choices() -> void:
	for c in choices_box.get_children():
		c.queue_free()

func flash_sfx(path: String) -> void:
	if path == "" or not ResourceLoader.exists(path):
		_log("flash_sfx missing", {"path": path})
		return
	sfx.stream = load(path)
	sfx.play()

# ── диалог-драйвер ────────────────────────────────────────────────────
func _ensure_db() -> void:
	if not _db.is_empty():
		return
	if not FileAccess.file_exists(DIALOGS_JSON):
		_log("dialogs.json not found", {"path": DIALOGS_JSON})
		return
	var txt := FileAccess.get_file_as_string(DIALOGS_JSON)
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		_log("dialogs.json parse error")
		return
	for d in Array(parsed.get("dialogs", [])):
		if typeof(d) != TYPE_DICTIONARY: continue
		var id := String(d.get("id",""))
		if id != "":
			_db[id] = d
	_log("dialogs loaded", {"count": _db.size()})

func play_by_id(id: String) -> void:
	_log("play_by_id enter", {"id": id})
	_ensure_db()
	var d: Dictionary = _db.get(id, {})
	if d.is_empty():
		_log("dialog id not found", {"id": id})
		_finish({})
		return

	# фон/музыка
	set_background_path(String(d.get("bg","")))
	play_music_path(String(d.get("music","")), true)

	_nodes = d.get("nodes", {})
	_cur_id = String(d.get("start",""))
	_log("dialog start node", {"node": _cur_id})
	_step()

func _step() -> void:
	if _cur_id == "":
		_log("no current node -> finish")
		_finish({})
		return
	var n: Dictionary = _nodes.get(_cur_id, {})
	var t := String(n.get("type","line"))
	_log("step", {"node": _cur_id, "type": t})

	match t:
		"line":
			var L = n.get("left", {})
			var R = n.get("right", {})
			show_line({
				"speaker": String(n.get("speaker","")),
				"text":    String(n.get("text","")),
				"left":  {"src": _resolve_portrait(L), "dim": bool(L.get("dim", false))},
				"right": {"src": _resolve_portrait(R), "dim": bool(R.get("dim", false))},
				"active_side": String(n.get("active","left")),
				"sfx": String(n.get("sfx",""))
			})
			_next_id = String(n.get("next",""))
		"choice":
			show_choices(String(n.get("prompt","Выбор")), n.get("options", []))
		"call":
			var target := String(n.get("call",""))
			var args = n.get("args", {})
			_log("call node", {"call": target, "args": args})
			if GameManager and GameManager.has_method(target):
				GameManager.call(target, args, self) # пример: start_battle(args, self)
			else:
				_log("GameManager has no method", {"call": target})
			_cur_id = String(n.get("goto",""))
			_step()
			return
		"end":
			_apply_effects(n.get("effects", {}))
			_finish({"node": _cur_id})
			return
		_:
			_log("unknown node type", {"type": t})
			_finish({})
			return

func _on_next() -> void:
	_log("_on_next", {"cur": _cur_id, "next": _next_id})
	if _has_choices:
		return
	_cur_id = _next_id
	_step()

func _on_choice(idx: int) -> void:
	var n: Dictionary = _nodes.get(_cur_id, {})
	var opts: Array = n.get("options", [])
	if idx < 0 or idx >= opts.size():
		_log("bad choice index", {"idx": idx, "size": opts.size()})
		return
	var opt: Dictionary = opts[idx]
	_apply_effects(opt.get("effects", {}))
	_cur_id = String(opt.get("goto",""))
	_log("_on_choice", {"idx": idx, "goto": _cur_id})
	_step()

# поддержка src И/ИЛИ char/pose, с проверкой разных регистров
func _resolve_portrait(side: Dictionary) -> String:
	var direct := String(side.get("src",""))
	if direct != "" and ResourceLoader.exists(direct):
		_log("portrait resolved by src", {"src": direct})
		return direct

	var char_raw := String(side.get("char",""))
	var pose_raw := String(side.get("pose",""))
	var char_variants := [
		char_raw,
		char_raw.to_lower(),
		char_raw.substr(0,1).to_upper() + char_raw.substr(1).to_lower()
	]
	var pose := (pose_raw if pose_raw != "" else "neutral")
	var pose_variants := [pose, pose.to_lower()]

	for c in char_variants:
		for p in pose_variants:
			var path := PORTRAIT_FMT.format({"char": c, "pose": p})
			if ResourceLoader.exists(path):
				_log("portrait resolved", {"char": c, "pose": p, "path": path})
				return path

	_log("portrait NOT found", {"char": char_raw, "pose": pose_raw})
	return ""

func _apply_effects(e: Dictionary) -> void:
	if e.has("mood"):
		for h in (e["mood"] as Dictionary).keys():
			GameManager.hero_mood[h] = int(GameManager.hero_mood.get(h,50)) + int(e["mood"][h])
			_log("effect mood", {"hero": h, "delta": int(e["mood"][h])})
	if e.has("spawn_tasks"):
		for t in (e["spawn_tasks"] as Array):
			if typeof(t) == TYPE_DICTIONARY:
				GameManager.spawn_task_instance(String(t.get("def","")), {"kind": String(t.get("kind","quest"))})
				_log("effect spawn_task", t)
	if e.has("quest_complete"):
		var q := String(e["quest_complete"])
		GameManager.set_quest_completed(q, true)
		_log("effect quest_complete", {"id": q})

func _finish(result: Dictionary) -> void:
	stop_music()
	_log("finish", result)
	dialog_finished.emit(result)
	queue_free()
