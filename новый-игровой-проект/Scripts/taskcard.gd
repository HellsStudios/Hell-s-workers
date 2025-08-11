extends ColorRect

@export var duration_slots: int = 4      # длительность (число 15-мин-слотов)
@export var task_name: String = ""       # название / тип задачи
var schedule_start_slot: int = -1        # где стоит на таймлайне (-1 = ещё не размещена)
@onready var lbl: Label = $Label

func _ready() -> void:
	lbl.clip_text = true
	lbl.text_overrun_behavior = 3
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.text = task_name if task_name != "" else "[Задача]"
	
func _get_drag_data(position: Vector2) -> Variant:
	# Эта функция вызывается Godot, когда пользователь начинает перетаскивать данный Control:contentReference[oaicite:0]{index=0}.
	# Мы подготовим данные для передачи при drag-and-drop.
	var drag_info = {
		"duration": duration_slots,
		"task_name": task_name,
	}
	# Определим, откуда задачу перетаскивают (из пула или из таймлайна). 
	# Проверим родителя: если родитель - Container (VBox в пуле), значит из пула, иначе из таймлайна.
	if get_parent() is Container:
		drag_info["source"] = "pool"
	else:
		drag_info["source"] = "timeline"
	# Вложим в данные ссылку на сам узел (саму TaskCard), чтобы потом можно было ее перемещать:
	drag_info["node"] = self
	# Создаем превью для перетаскивания (копию этой карточки)
	var preview = self.duplicate()  # дублируем узел TaskCard (создается его копия с теми же свойствами)
	preview.modulate = Color(1,1,1,0.7)  # сделаем превью полупрозрачным для эффекта
	# Добавляем превью через встроенную функцию - это отобразит копию, следующую за курсором:contentReference[oaicite:1]{index=1}.
	set_drag_preview(preview)
	# Скрываем оригинал карточки, чтобы не было видно ее дубликат в месте старого положения во время переноса.
	self.visible = false
	# Подписываемся на событие, когда превью будет удалено (окончание dnd):contentReference[oaicite:2]{index=2}:
	preview.connect("tree_exiting", Callable(self, "_on_preview_exit"))
	return drag_info

func _on_preview_exit():
	# Этот callback вызывается, когда drag-and-drop завершается, и preview (его Control) удаляется из дерева.
	# Проверим, если оригинал задачи все еще скрыт (значит, drop не был принят ни одним узлом):
	if not self.visible:
		# Вернем задачу в исходное состояние (снова показываем на старом месте)
		self.visible = true
		
func _on_card_resized() -> void:
	# пере-инициализируем клип (пересчёт ширины)
	lbl.clip_text = false
	lbl.clip_text = true      # включает назад и вызывает переразметку
