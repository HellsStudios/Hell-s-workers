extends Control
signal resume_requested
signal exit_requested

@onready var blocker: ColorRect = %Dim      # полноэкранная полупрозрачная «шторка»
@onready var panel:   Panel      = %Panel
@onready var resume_btn: Button  = %ResumeBtn
@onready var exit_btn:   Button  = %ExitBtn
@onready var master: HSlider     = %Master
@onready var music:  HSlider     = %Music


func _ready() -> void:
	# Меню должно жить даже при паузе
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	
	# Настоящий оверлей
	set_as_top_level(true)
	z_as_relative = false
	z_index = 4095

	# Растянуть на весь экран и «съедать» ввод
	anchor_left = 0; anchor_top = 0; anchor_right = 1; anchor_bottom = 1
	offset_left = 0; offset_top = 0; offset_right = 0; offset_bottom = 0
	mouse_filter = Control.MOUSE_FILTER_STOP

	if blocker:
		blocker.anchor_left = 0; blocker.anchor_top = 0; blocker.anchor_right = 1; blocker.anchor_bottom = 1
		blocker.offset_left = 0; blocker.offset_top = 0; blocker.offset_right = 0; blocker.offset_bottom = 0
		blocker.mouse_filter = Control.MOUSE_FILTER_STOP  # блокируем клики в фон

	resume_btn.pressed.connect(func(): resume_requested.emit())
	exit_btn.pressed.connect(func(): exit_requested.emit())

func grab_default_focus() -> void:
	if resume_btn: resume_btn.grab_focus()
	else: grab_focus()


func configure(mode: int) -> void:
	match mode:
		Pause.Mode.BATTLE:   exit_btn.text = "Сдаться (поражение)"
		Pause.Mode.TIMELINE: exit_btn.text = "В особняк"
		_:                   exit_btn.text = "Выйти из игры"

func _set_bus_linear(bus: String, lin: float) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(clamp(lin, 0.0, 1.0)))
		ProjectSettings.set_setting("game/audio/%s" % bus, lin)  # сохраняем

func _load_volumes() -> void:
	for b in ["Master","Music"]:
		var lin := float(ProjectSettings.get_setting("game/audio/%s" % b, 1.0))
		var idx := AudioServer.get_bus_index(b)
		if idx >= 0:
			AudioServer.set_bus_volume_db(idx, linear_to_db(lin))
		if b == "Master": master.value = lin
		if b == "Music":  music.value  = lin
