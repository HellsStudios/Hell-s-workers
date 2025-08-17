extends Panel
# Константы шкалы времени:
const TOTAL_SLOTS: int = 48          # количество слотов (с 08:00 до 20:00, 15-минутные интервалы)
const SLOT_WIDTH: float = 25.0       # ширина одного 15-минутного слота в пикселях (1200px / 48 = 25px)

func _can_drop_data(position: Vector2, data: Variant) -> bool:
	
	# Вызывается во время перетаскивания, когда курсор находится над этой строкой.
	# Мы должны проверить, можно ли бросить сюда тот объект (data), который тащат:contentReference[oaicite:8]{index=8}.
	# Если вернем true, Godot даст позитивный сигнал (например, может поменять курсор), 
	# а отпуская, вызовет _drop_data. Если false – этот узел не примет данные.
	# Начнем с проверки типа данных:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if not data.has("duration") or not data.has("source"):
		return false  # Ожидаем, что data – словарь с ключами "duration", "source" и др.
	# Извлечем нужную информацию:
	var task_duration: int = data["duration"]
	var source_type: String = data["source"]
	# Рассчитаем предполагаемый стартовый слот, куда хотят бросить задачу.
	# position.x – это координата в пикселях внутри этой Panel, где находится курсор в момент вызова.
	# Мы привяжем ее к сетке 15 мин. Используем округление до ближайшего слота:
	var slot_index: int = int(floor(position.x / SLOT_WIDTH))
	print("can_drop -> ", slot_index, ": ", true)  # или false
	# Ограничим индекс в диапазоне допустимых (0 .. TOTAL_SLOTS - duration):
	if slot_index < 0:
		slot_index = 0
	if slot_index + task_duration > TOTAL_SLOTS:
		# Если даже начальный слот таков, что задача не помещается в конец дня, откажем.
		return false
	# Проверим наложение на другие задачи в этой строке:
	# Пройдёмся по всем дочерним узлам этой TimelineRow.
	for child in get_children():
		if child == data["node"]:
			continue              # пропускаем саму перетаскиваемую задачу
		if child is ColorRect and child.schedule_start_slot >= 0:
			# Предполагаем, что все дочерние ColorRect – это задачи (TaskCard), 
			# т.к. других детей у TimelineRow нет (мы не добавляли спец. узлы).
			var other_task: ColorRect = child
			# Получим начало и конец занятого диапазона другой задачи:
			# Мы сохраняли start_slot в свойстве schedule_start_slot у TaskCard.
			# Потому что, когда добавляем задачу на таймлайн, мы это поле заполним.
			if other_task.has_method("get") and other_task.get("schedule_start_slot") != null:
				var other_start: int = other_task.schedule_start_slot
				var other_duration: int = other_task.duration_slots
				var other_end: int = other_start + other_duration
				var new_start: int = slot_index
				var new_end: int = slot_index + task_duration
				# Условие пересечения интервалов [new_start, new_end) и [other_start, other_end):
				if new_start < other_end and new_end > other_start:
					return false  # временной конфликт: новая задача пересекается с существующей
			# (Если по какой-то причине у child нет этих свойств, можно иначе вычислить:
			# например, по позиции и ширине child рассчитать его слоты.
			# Но благодаря тому, что мы проставим schedule_start_slot, мы пользуемся им.)
	# Если источник данных – та же самая строка и та же задача, можно предусмотреть.
	# Но в нашем случае, _can_drop_data не вызывается для источника, а только для целей.
	# Итого, если прошли все проверки – можно принять drop.
	return true

func _drop_data(position: Vector2, data: Variant) -> void:
	# Вызывается, когда пользователь отпустил drag и _can_drop_data вернул true, т.е. drop принят:contentReference[oaicite:12]{index=12}.
	# Здесь нужно "приземлить" задачу на эту линию.
	if typeof(data) != TYPE_DICTIONARY or not data.has("node") or not data.has("duration"):
		return  # безопасность: если что-то не так с данными, ничего не делаем
	var task_node = data["node"]       # ссылка на перетаскиваемый узел TaskCard (оригинал)
	var task_duration: int = data["duration"]
	var source_type: String = data.get("source", "")  # если ключа может не быть, default ""
	# Рассчитаем стартовый слот аналогично can_drop:
	var slot_index: int = int(floor(position.x / SLOT_WIDTH))
	if slot_index < 0:
		slot_index = 0
	if slot_index + task_duration > TOTAL_SLOTS:
		slot_index = TOTAL_SLOTS - task_duration  # на всякий случай подвинем, хотя can_drop уже бы отсек
	# Вычислим точную координату X для этого слота (привязка к сетке):
	var snapped_x: float = slot_index * SLOT_WIDTH
	var row_h   := size.y                      # высота строки-Panel (обычно 40 px)
	var card_h  = task_node.size.y            # высота карточки (30 px)
	var centred_y = (row_h - card_h) / 2.0   # по центру
	# Теперь в зависимости от источника:

	if source_type == "pool":
		# 1. отцепляем от списка задач (TaskList)
		var old_parent = task_node.get_parent()
		if old_parent:
			old_parent.remove_child(task_node)

		# 2. добавляем в текущую TimelineRow
		add_child(task_node)

		# далее позиция, ширина и т.д.
		task_node.position = Vector2(snapped_x, centred_y)
		var new_width := task_duration * SLOT_WIDTH
		task_node.set_size(Vector2(new_width, task_node.size.y))
		task_node.size_flags_horizontal = Control.SIZE_FILL
		task_node.schedule_start_slot = slot_index
		task_node.visible = true

	elif source_type == "timeline":
		var old_parent = task_node.get_parent()
		if old_parent != self:
			old_parent.remove_child(task_node)
			add_child(task_node)

		# позиция и размер — как раньше
		task_node.position = Vector2(snapped_x, centred_y)
		task_node.set_size(Vector2(task_duration * SLOT_WIDTH, task_node.size.y))
		task_node.schedule_start_slot = slot_index
		task_node.visible = true
	# Готово: задача добавлена на линию.
